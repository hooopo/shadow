CREATE SCHEMA IF NOT EXISTS shadow;

CREATE OR REPLACE FUNCTION shadow.quote_ident_with_schema(string text) RETURNS text AS $$
  DECLARE
    str text;
  BEGIN
    CASE split_part(string, '.', 2)
    WHEN '' THEN
       str := quote_ident(string);
    ELSE 
       str := quote_ident(split_part(string, '.', 1)) || '.' || quote_ident(split_part(string, '.', 2));
    END CASE;
    RETURN str;
  END
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION shadow.versioning()
RETURNS TRIGGER AS $$
DECLARE
  sys_period text;
  history_table text;
  manipulate jsonb;
  commonColumns text[];
  time_stamp_to_use timestamptz := current_timestamp;
  range_lower timestamptz;
  transaction_info txid_snapshot;
  existing_range tstzrange;
BEGIN
  sys_period := TG_ARGV[0];
  history_table := TG_ARGV[1];

  IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
    -- Ignore rows already modified in this transaction
    transaction_info := txid_current_snapshot();
    IF OLD.xmin::text >= (txid_snapshot_xmin(transaction_info) % (2^32)::bigint)::text
    AND OLD.xmin::text <= (txid_snapshot_xmax(transaction_info) % (2^32)::bigint)::text THEN
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END IF;

    EXECUTE format('SELECT $1.%I', sys_period) USING OLD INTO existing_range;

    IF TG_ARGV[2] = 'true' THEN
      -- mitigate update conflicts
      range_lower := lower(existing_range);
      IF range_lower >= time_stamp_to_use THEN
        time_stamp_to_use := range_lower + interval '1 microseconds';
      END IF;
    END IF;

    WITH history AS
      (SELECT attname
      FROM   pg_attribute
      WHERE  attrelid = history_table::regclass
      AND    attnum > 0
      AND    NOT attisdropped),
      main AS
      (SELECT attname
      FROM   pg_attribute
      WHERE  attrelid = TG_RELID
      AND    attnum > 0
      AND    NOT attisdropped)
    SELECT array_agg(quote_ident(history.attname)) INTO commonColumns
      FROM history
      INNER JOIN main
      ON history.attname = main.attname
      AND history.attname != sys_period;

    EXECUTE ('INSERT INTO ' ||
      shadow.quote_ident_with_schema(history_table) ||
      '(' ||
      array_to_string(commonColumns , ',') ||
      ',' ||
      quote_ident(sys_period) ||
      ', op' ||
      ', op_query' ||
      ', db_session_user' ||
      ', app_session_user_id' ||
      ') VALUES ($1.' ||
      array_to_string(commonColumns, ',$1.') ||
      ',tstzrange($2, $3, ''[)''), $4, $5, $6, $7)')
       USING OLD, range_lower, time_stamp_to_use, LEFT(TG_OP, 1), current_query(), session_user::text, current_setting('app.session_user_id', true)::text;
  END IF;

  IF TG_OP = 'UPDATE' OR TG_OP = 'INSERT' THEN
    manipulate := jsonb_set('{}'::jsonb, ('{' || sys_period || '}')::text[], to_jsonb(tstzrange(time_stamp_to_use, null, '[)')));

    RETURN jsonb_populate_record(NEW, manipulate);
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION shadow.setup(
  target_table text, 
  history_table text
) RETURNS void AS $T1$
  DECLARE
    alter_target text;
    create_history text;
    create_trigger text;
  BEGIN
    alter_target := 'ALTER TABLE %s 
    ADD COLUMN sys_period tstzrange NOT NULL DEFAULT tstzrange(current_timestamp, null);';
    alter_target := FORMAT(alter_target, history_table);
    RAISE INFO 'EXECUTE SQL: %', alter_target;
    EXECUTE(alter_target);

    create_history := 'CREATE TABLE shadow.%s (
      LIKE %s INCLUDING DEFAULTS EXCLUDING CONSTRAINTS EXCLUDING INDEXES INCLUDING COMMENTS
    )';

    create_history := FORMAT(create_history, history_table, target_table);
    RAISE INFO 'EXECUTE SQL: %', create_history;
    EXECUTE(create_history);

    EXECUTE(FORMAT('CREATE INDEX ON shadow.%s (id)', history_table));
    EXECUTE(FORMAT('ALTER TABLE shadow.%s ADD COLUMN op CHAR(1) DEFAULT ''U''', history_table));
    EXECUTE(FORMAT('ALTER TABLE shadow.%s ADD COLUMN op_query varchar', history_table));
    EXECUTE(FORMAT('ALTER TABLE shadow.%s ADD COLUMN db_session_user varchar', history_table));
    -- run this in app db connection: select set_config('app.session_user_id', '1', false);
    -- https://www.postgresql.org/docs/9.5/config-setting.html
    EXECUTE(FORMAT('ALTER TABLE shadow.%s ADD COLUMN app_session_user_id varchar', history_table));
    create_trigger := 'CREATE TRIGGER zzz_%s_shadow_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON %s
      FOR EACH ROW EXECUTE PROCEDURE shadow.versioning(
        %L, ''shadow.%I'', true
      )';

    create_trigger := FORMAT(
      create_trigger, 
      shadow.quote_ident_with_schema(target_table), 
      replace(target_table, '.', '_'), 
      'sys_period', history_table
    );
    RAISE INFO 'EXECUTE SQL: %', create_trigger;
    EXECUTE(create_trigger);
  END
$T1$ LANGUAGE plpgsql SECURITY DEFINER;


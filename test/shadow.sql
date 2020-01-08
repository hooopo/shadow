\i shadow/sql/shadow.sql

create table users (id integer  primary key, name varchar, age integer default 0);

select shadow.setup('users', 'users');
-- INFO:  EXECUTE SQL: ALTER TABLE users
--     ADD COLUMN sys_period tstzrange NOT NULL DEFAULT tstzrange(current_timestamp, null);
-- INFO:  EXECUTE SQL: CREATE TABLE shadow.users (
--       LIKE users INCLUDING DEFAULTS EXCLUDING CONSTRAINTS EXCLUDING INDEXES INCLUDING COMMENTS
--     )
-- INFO:  EXECUTE SQL: CREATE TRIGGER zzz_users_shadow_trigger
--       BEFORE INSERT OR UPDATE OR DELETE ON users
--       FOR EACH ROW EXECUTE PROCEDURE shadow.versioning(
--         'sys_period', 'shadow.users', true
--       )
--  setup

insert into users values (1, 'hooopo', 20);
insert into users values (2, 'A', 20);
delete from users where id = 2;
update users set age = 30 where id = 1;
update users set age = 50 where id = 1;

select * from users;
--  id |  name  | age |             sys_period
-- ----+--------+-----+------------------------------------
--   1 | hooopo |  50 | ["2020-01-09 01:53:57.242612+08",)
-- (1 row)

select * from shadow.users;
--  id |  name  | age |                            sys_period
-- ----+--------+-----+-------------------------------------------------------------------
--   2 | A      |  20 | ["2020-01-09 01:53:07.462855+08","2020-01-09 01:53:22.166458+08")
--   1 | hooopo |  20 | ["2020-01-09 01:52:14.190439+08","2020-01-09 01:53:45.905776+08")
--   1 | hooopo |  30 | ["2020-01-09 01:53:45.905776+08","2020-01-09 01:53:57.242612+08")
-- (3 rows)
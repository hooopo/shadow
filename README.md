# Shadow Table for Postgres

<a name="mW3mg"></a>
## Why
有时候，我们需要查看一条记录在过去某个时间点的状态，也就是一个 [Slowly Changing Dimension](https://en.wikipedia.org/wiki/Slowly_changing_dimension) 问题。然而，大部分OLTP系统数据模型设计天然忽略了历史记录的保存，直接删掉或者更新掉。 但一些场景我们需要查看任意时间点记录的状态：

- 审计或者安全需求
- 实际业务需求，比如一个员工的薪资或者职位变更历史
- 分析统计需求，数据仓库需要根据历史状态一些分析挖掘
- 灾难恢复，开发人员上线了有bug的代码，错误的修改或删除了重要数据，需要恢复到正确状态

<a name="Cabg1"></a>
## 现有实现

Rails 里有 [paranoia](https://github.com/radar/paranoia) 和 Audited 等插件可以解决上面提出的部分需求。但有几个问题：

- paranoia这种软删插件，把 destroy 变成了 update，和其他需要hook after_destroy 的插件会冲突。
- paranoia 和 audited 只 hook了应用层，只有针对单条model记录的操作才有效。如果开发人员写SQL来做一些操作就没有效果。
- 除了应用层会有绕过model的SQL，现实场景开发人员或DBA也会直接在DB上执行一些语句更新数据，这种场景paranoia和audited也是无能为力。

所以这个问题最佳的解决方案应该是从DB层解决。PG现有的解决方案有 [https://github.com/arkhipov/temporal_tables](https://github.com/arkhipov/temporal_tables) 等，但也存在一些问题。

<a name="wmc3x"></a>
## 理想中的方案

理想中的方案应该满足下面这些条件：

1. 基于DB层，而非应用层，在任何场景下都不会漏掉数据
1. 容易安装和使用，temporal_tables 不满足这一点，因为这东西依赖C扩展，在各种云服务环境下不能用
1. 能够集成应用层信息，比如操作人，一些DB插件功能很全面，但不满足这一条，记录的只是DB层的操作账号，而非应用层的，对于Rails项目来说，其实都是同一个用户。
1. 对UI和分析友好，一些方案把变更记录直接存在json里，使用起来其实需要很多额外的工作。比如 Rails 项目里，显示记录逻辑和显示历史变更逻辑难以复用。

<a name="mz4tD"></a>
## Shadow Table with static copy

[https://github.com/hooopo/shadow/blob/master/sql/shadow.sql](https://github.com/hooopo/shadow/blob/master/sql/shadow.sql)

对于目标表 users，生成一个结构一致的shadow表 shadow.users，修改和更新直接回写到 users表上，把被修改前的值写入到 shadow.users 表里。并且记录 session_user, current_query, operation time, operation type等信息。下面演示一下：

创建 users 表:
```sql
create database test_shadow;
\c test_shadow;
create table users (id integer primary key, name varchar,  age integer default 20);
insert into users values (1, 'name1', 30);
insert into users values (2, 'name2', 35);
insert into users values (3, 'name3', 35);

select * from users;
 id | name  | age |             sys_period
----+-------+-----+------------------------------------
  1 | name1 |  30 | ["2020-01-10 14:57:20.756974+08",)
  2 | name2 |  35 | ["2020-01-10 14:57:20.756974+08",)
  3 | name3 |  35 | ["2020-01-10 14:57:20.756974+08",)
                     
```

导入shadow.sql:

```sql
\i ~/w/shadow/sql/shadow.sql

select shadow.setup('users', 'users');

-- 实际执行过程，给 users 表添加 sys_period 字段
INFO:  EXECUTE SQL: ALTER TABLE users
    ADD COLUMN sys_period tstzrange NOT NULL DEFAULT tstzrange(current_timestamp, null);
-- 静态copy users 的表结构，去掉约束，保留默认值
INFO:  EXECUTE SQL: CREATE TABLE shadow.users (
      LIKE users INCLUDING DEFAULTS EXCLUDING CONSTRAINTS EXCLUDING INDEXES INCLUDING COMMENTS
    )
-- 创建一个trigger，在insert or update or delete 过程前
INFO:  EXECUTE SQL: CREATE TRIGGER zzz_users_shadow_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON users
      FOR EACH ROW EXECUTE PROCEDURE shadow.versioning(
        'sys_period', 'shadow.users', true
      )
```

看下效果：

```sql
update users set name = 'hello' where id = 1;
delete from users where id = 2;

-- users 表还是按照原来的逻辑，完全无影响，只是会记录sys_period
select * from users;
 id | name  | age |             sys_period
----+-------+-----+------------------------------------
  3 | name3 |  35 | ["2020-01-10 14:57:20.756974+08",)
  1 | hello |  30 | ["2020-01-10 14:59:11.48809+08",)

 -- 上面一条删除一条更新语句之后，产生了两个历史记录，是被修改前的记录快照，并且有当时执行的sql语句。               
 select * from shadow.users;
-[ RECORD 1 ]-------+------------------------------------------------------------------
id                  | 1
name                | name1
age                 | 30
sys_period          | ["2020-01-10 14:57:20.756974+08","2020-01-10 14:59:11.48809+08")
op                  | U
op_query            | update users set name = 'hello' where id = 1;
db_session_user     | hooopo
app_session_user_id | (null)
-[ RECORD 2 ]-------+------------------------------------------------------------------
id                  | 2
name                | name2
age                 | 35
sys_period          | ["2020-01-10 14:57:20.756974+08","2020-01-10 14:59:28.137144+08")
op                  | D
op_query            | delete from users where id = 2;
db_session_user     | hooopo
app_session_user_id | (null)
```

这个简单的demo已经满足了上面提到的4个要求，唯一不足的地方是，创建历史表的时候使用的是静态复制了目标表的结构，目标表之后添加修改或者删除字段，需要开发者自己去维护 shadow 表的结构和目标表一致。一个解决办法是使用event trigger，PG在DDL语句也可以使用trigger，可以在修改目标表之后去刷新shadow表，但实际执行的DDL语句 pg_ddl_command 在非 C 扩展环境无法取得，所以这个方案在不使用 C 扩展的前提下就只能到这里了。


<a name="OA4xS"></a>
## Shadow Table with json

[https://github.com/hooopo/shadow/blob/master/sql/shadow_jsonb.sql](https://github.com/hooopo/shadow/blob/master/sql/shadow_jsonb.sql)

如果不想处理shadow表和目标表的结构同步，可以使用json这种schemaless的结构来存储历史变更，甚至还可以避免去处理一些不兼容的类型修改等问题，比如把一个字段从char(10)改成了char(5)，第一种方案需要把已经存进去的长度大于5的从shadow表里移除，才能保证结构同步成功。

下面演示json的效果：

```sql
create database test_shadow_jsonb;
\c test_shadow_jsonb;
create table users (id integer primary key, name varchar,  age integer default 20);
insert into users values (1, 'name1', 30);
insert into users values (2, 'name2', 35);
insert into users values (3, 'name3', 35);

select * from users;
 id | name  | age |             sys_period
----+-------+-----+------------------------------------
  1 | name1 |  30 | ["2020-01-10 14:57:20.756974+08",)
  2 | name2 |  35 | ["2020-01-10 14:57:20.756974+08",)
  3 | name3 |  35 | ["2020-01-10 14:57:20.756974+08",)
```

导入shadow_jsonb.sql

```sql
\i ~/w/shadow/sql/shadow_jsonb.sql

select shadow.setup_jsonb('users', 'users');
INFO:  EXECUTE SQL: ALTER TABLE users
    ADD COLUMN sys_period tstzrange NOT NULL DEFAULT tstzrange(current_timestamp, null);
INFO:  EXECUTE SQL: CREATE TABLE shadow.users ()

-- 需要目标表有一个主键，如果不是id可指定
INFO:  EXECUTE SQL: CREATE TRIGGER zzz_users_shadow_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON users
      FOR EACH ROW EXECUTE PROCEDURE shadow.versioning(
        'sys_period', 'shadow.users', 'id', true
      )
 setup_jsonb
 
 -- shadow.users 的结构
 \d shadow.users
                                                     Table "shadow.users"
       Column        |       Type        | Collation | Nullable |                           Default
---------------------+-------------------+-----------+----------+--------------------------------------------------------------
 id                  | character varying |           |          |
 shadow_data         | jsonb             |           |          | '{}'::jsonb
 op                  | character(1)      |           |          | 'U'::bpchar
 op_query            | character varying |           |          |
 db_session_user     | character varying |           |          |
 sys_period          | tstzrange         |           | not null | tstzrange(CURRENT_TIMESTAMP, NULL::timestamp with time zone)
 app_session_user_id | character varying |           |          |
Indexes:
    "users_id_idx" btree (id)
```

看一下效果：

```sql
update users set name = 'hello' where id = 1;
delete from users where id = 2;

select * from shadow.users;
-[ RECORD 1 ]-------+------------------------------------------------------------------
id                  | 1
shadow_data         | {"id": 1, "age": 30, "name": "name1"}
op                  | U
op_query            | update users set name = 'hello' where id = 1;
db_session_user     | hooopo
sys_period          | ["2020-01-10 15:35:37.185797+08","2020-01-10 15:40:29.22283+08")
app_session_user_id | (null)
-[ RECORD 2 ]-------+------------------------------------------------------------------
id                  | 2
shadow_data         | {"id": 2, "age": 35, "name": "name2"}
op                  | D
op_query            | delete from users where id = 2;
db_session_user     | hooopo
sys_period          | ["2020-01-10 15:35:37.185797+08","2020-01-10 15:40:30.265188+08")
app_session_user_id | (null)
```

app_session_user_id 字段是用来保存应用层的用户信息，比如 Rails 里的 current_user.id

可以在 Rails before_action 里：

```ruby
ActiveRecord::Base.connection.execute("select set_config('app.session_user_id', '#{current_user&.id}', false);")
```

相关文档：https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADMIN-SET-TABLE

当然，这个方案不满足上面提到的第四条，因为users表和shadow.users表是不同结构的，对于显示来说，需要写两遍处理逻辑。一个可能的解决方案是，通过AR的attributes可以把shadow_data塞进去，模拟出和users model统一的接口，待尝试。

<a name="XfQuS"></a>
## Shadow Table with updatable view

这个方案操作起来挺复杂的，主要解决了第一种方案里复制结构带来的手工维护问题。还是基于方案1，既然静态复制结构需要维护，那么其实可以使用PG的表继承来产生一个和目标表完全一致的表结构。

```sql
create table shadow.users_v2(op char(1)) inherits (users);
```

但是带来一个新的问题：select * from users 的时候，shadow.users 里的数据也被查出来了，这个是继承的特性。

如果只查父表，可以使用 only 关键词： select * from only users，这样查出来的就是只有 users表的数据。

所以我们可以产生一个view：

```sql
create view only_users as (select * from only users)
```

```ruby
class User < AR
  self.table_name = 'only_users'
end
```

更新呢？从PG 9.3开始，view是updatable的：[https://paquier.xyz/postgresql-2/postgres-9-3-feature-highlight-auto-updatable-views/](https://paquier.xyz/postgresql-2/postgres-9-3-feature-highlight-auto-updatable-views/)<br />但有限制：

> - The view must have exactly one entry in its FROM list, which must be a table or another updatable view.
> - The view definition must not contain WITH, DISTINCT, GROUP BY, HAVING, LIMIT, or OFFSET clauses at the top level.
> - The view definition must not contain set operations (UNION, INTERSECT or EXCEPT) at the top level.
> - The view’s select list must not contain any aggregates, window functions, or set-returning functions.


上面的shadow.users_v2满足这些条件，所以更新问题也解决了。唯一的不足是，开发者还是可以绕过AR的定义去直接拼SQL写成 select * from users。

所以，各个方案都不是那么完美，如果你的表结构很稳定，你可以选择方案1，如果你不关心view层展示，你可以选择方案2，如果你乐于踩坑，可以试试方案3。

虽然还不是很完美，但替代 [paranoia](https://github.com/radar/paranoia) + Audited 还是挺不错的。

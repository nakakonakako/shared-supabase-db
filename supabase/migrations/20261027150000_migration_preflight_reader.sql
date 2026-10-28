-- A dedicated, non-login group role for production migration preflight reads.
-- A separate LOGIN role and password are provisioned only during the later
-- production cutover; credentials are never stored in a migration.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '15s';

do $preflight$
begin
  if exists (
    select 1
    from pg_catalog.pg_roles
    where rolname = 'migration_preflight_reader'
  ) then
    raise exception 'migration_preflight_reader already exists; review its privileges before applying this migration';
  end if;

  if pg_catalog.to_regclass('supabase_migrations.schema_migrations') is null then
    raise exception 'Supabase migration history table is unavailable';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class as c
    join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
    where n.nspname = 'ai_quota'
      and c.relname = 'settings'
      and c.relkind in ('r', 'p')
  ) then
    raise exception 'ai_quota.settings table is unavailable';
  end if;

  if (
       select count(*)
       from pg_catalog.pg_auth_members as m
       join pg_catalog.pg_roles as granted on granted.oid = m.roleid
       join pg_catalog.pg_roles as member on member.oid = m.member
       where granted.rolname = 'ai_quota_owner'
         and member.rolname = current_user
     ) <> 1
     or not exists (
       select 1
       from pg_catalog.pg_auth_members as m
       join pg_catalog.pg_roles as granted on granted.oid = m.roleid
       join pg_catalog.pg_roles as member on member.oid = m.member
       where granted.rolname = 'ai_quota_owner'
         and member.rolname = current_user
         and m.admin_option
         and not m.set_option
         and not m.inherit_option
     ) then
    raise exception 'migration executor requires an existing ADMIN-only ai_quota_owner membership';
  end if;
end
$preflight$;

create role migration_preflight_reader
  nologin
  nosuperuser
  nocreatedb
  nocreaterole
  noreplication
  nobypassrls
  noinherit;

grant connect on database postgres to migration_preflight_reader;
grant usage on schema supabase_migrations to migration_preflight_reader;
grant select (version)
  on table supabase_migrations.schema_migrations
  to migration_preflight_reader;

-- Change only SET while preserving the existing ADMIN-only membership.
grant ai_quota_owner to current_user with set true, inherit false;
set local role ai_quota_owner;
grant usage on schema ai_quota to migration_preflight_reader;
grant select (id) on table ai_quota.settings to migration_preflight_reader;
reset role;

-- If the bootstrap ADMIN grant was made by this executor, restore its SET
-- option on that same grant. Otherwise remove only the temporary grant made
-- by this executor, leaving the bootstrap grant untouched.
do $restore_membership$
begin
  if exists (
    select 1
    from pg_catalog.pg_auth_members as m
    join pg_catalog.pg_roles as granted on granted.oid = m.roleid
    join pg_catalog.pg_roles as member on member.oid = m.member
    where granted.rolname = 'ai_quota_owner'
      and member.rolname = current_user
      and m.grantor = (select oid from pg_catalog.pg_roles where rolname = current_user)
      and m.admin_option
  ) then
    execute pg_catalog.format(
      'GRANT ai_quota_owner TO %I WITH SET FALSE, INHERIT FALSE',
      current_user
    );
  else
    execute pg_catalog.format(
      'REVOKE ai_quota_owner FROM %I GRANTED BY %I',
      current_user,
      current_user
    );
  end if;
end
$restore_membership$;

do $verify_membership$
begin
  if (
       select count(*)
       from pg_catalog.pg_auth_members as m
       join pg_catalog.pg_roles as granted on granted.oid = m.roleid
       join pg_catalog.pg_roles as member on member.oid = m.member
       where granted.rolname = 'ai_quota_owner'
         and member.rolname = current_user
     ) <> 1
     or not exists (
       select 1
       from pg_catalog.pg_auth_members as m
       join pg_catalog.pg_roles as granted on granted.oid = m.roleid
       join pg_catalog.pg_roles as member on member.oid = m.member
       where granted.rolname = 'ai_quota_owner'
         and member.rolname = current_user
         and m.admin_option
         and not m.set_option
         and not m.inherit_option
     ) then
    raise exception 'migration executor ADMIN-only ai_quota_owner membership was not preserved';
  end if;
end
$verify_membership$;

commit;

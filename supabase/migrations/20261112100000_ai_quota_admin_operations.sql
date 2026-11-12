-- Dedicated, bounded admin operation; no credentials or exception are enabled.
begin;

do $preflight$
declare
  c text;
begin
  if session_user is distinct from current_user or current_user <> 'postgres' then
    raise exception 'admin migration requires the postgres session user';
  end if;
  if not exists (select 1 from pg_catalog.pg_roles where rolname = current_user and (rolsuper or rolbypassrls)) then
    raise exception 'auth validation requires an RLS-bypassing migration role';
  end if;
  if exists (select 1 from pg_catalog.pg_roles where rolname in ('ai_quota_admin_owner', 'ai_quota_admin_login'))
     or pg_catalog.to_regnamespace('ai_quota_admin') is not null
     or pg_catalog.to_regnamespace('ai_quota_auth_probe') is not null then
    raise exception 'admin roles or schemas already exist';
  end if;
  foreach c in array array['id','confirmed_at','last_sign_in_at','is_anonymous','deleted_at','banned_until'] loop
    if not pg_catalog.has_column_privilege(current_user, 'auth.users', c, 'SELECT') then
      raise exception 'auth validation prerequisites are unavailable';
    end if;
  end loop;
  if not pg_catalog.has_column_privilege(current_user, 'auth.users', 'id', 'UPDATE') then
    raise exception 'auth validation row locking is unavailable';
  end if;
  if not (select rolsuper from pg_catalog.pg_roles where rolname=current_user) and not exists (
    select 1 from pg_catalog.pg_auth_members m
    join pg_catalog.pg_roles granted on granted.oid=m.roleid
    join pg_catalog.pg_roles member on member.oid=m.member
    where granted.rolname='ai_quota_owner' and member.rolname=current_user and m.admin_option
  ) then
    raise exception 'temporary owner access is unavailable';
  end if;
  if exists (
    select 1 from pg_catalog.pg_auth_members m
    join pg_catalog.pg_roles granted on granted.oid=m.roleid
    join pg_catalog.pg_roles member on member.oid=m.member
    join pg_catalog.pg_roles grantor on grantor.oid=m.grantor
    where granted.rolname='ai_quota_owner' and member.rolname=current_user
      and (m.set_option or m.inherit_option or grantor.rolname=current_user)
  ) then
    raise exception 'pre-existing owner access must not be modified';
  end if;
end
$preflight$;

create role ai_quota_admin_owner nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
create role ai_quota_admin_login login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
-- Password remains unset. A separate approved provisioning process is required.
grant ai_quota_admin_owner to current_user with set true, inherit false;
create schema ai_quota_admin authorization ai_quota_admin_owner;
create schema ai_quota_auth_probe authorization current_user;
revoke all on schema ai_quota_admin from public, anon, authenticated, service_role, ai_quota_backend;
revoke all on schema ai_quota_auth_probe from public, anon, authenticated, service_role, ai_quota_backend, ai_quota_admin_login;

-- This fixed predicate is owned by postgres because auth.users has RLS and no
-- policies for our dedicated owner. FOR SHARE protects validation until commit.
create function ai_quota_auth_probe.is_valid_user(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare valid boolean;
begin
  select true into valid from auth.users u
  where u.id = p_user_id and u.confirmed_at is not null
    and u.last_sign_in_at is not null and u.is_anonymous is false
    and u.deleted_at is null and (u.banned_until is null or u.banned_until <= pg_catalog.clock_timestamp())
  for share;
  return coalesce(valid, false);
end
$function$;
revoke all on function ai_quota_auth_probe.is_valid_user(uuid) from public, anon, authenticated, service_role, ai_quota_backend, ai_quota_admin_login;
grant usage on schema ai_quota_auth_probe to ai_quota_admin_owner;
grant execute on function ai_quota_auth_probe.is_valid_user(uuid) to ai_quota_admin_owner;

-- Existing owner grants only the columns required by the admin operation.
grant ai_quota_owner to current_user with set true, inherit false;
set local role ai_quota_owner;
grant usage on schema ai_quota to ai_quota_admin_owner;
grant select (id, developer_user_id), update (developer_user_id) on ai_quota.settings to ai_quota_admin_owner;
reset role;
revoke ai_quota_owner from current_user;

set local role ai_quota_admin_owner;
create table ai_quota_admin.operation_log (
  github_run_id bigint primary key check (github_run_id > 0),
  occurred_at timestamptz not null default pg_catalog.clock_timestamp(),
  target text not null check (target in ('dev','production')),
  operation text not null check (operation in ('set','clear')),
  old_user_id uuid,
  new_user_id uuid,
  github_actor text not null check (github_actor ~ '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$'),
  check ((operation='set' and new_user_id is not null) or (operation='clear' and new_user_id is null))
);
revoke all on table ai_quota_admin.operation_log from public, anon, authenticated, service_role, ai_quota_backend, ai_quota_admin_login;

create function ai_quota_admin.fingerprint(p_id uuid)
returns text language sql immutable set search_path = ''
as $function$
  select case when p_id is null then 'none'
    else pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p_id::text, 'UTF8')), 'hex') end;
$function$;
revoke all on function ai_quota_admin.fingerprint(uuid) from public, anon, authenticated, service_role, ai_quota_backend, ai_quota_admin_login;

-- Preview exposes only a fingerprint to the protected operator and never
-- reveals the stored account ID to logs.
create function ai_quota_admin.preview_developer(p_target text)
returns text language plpgsql security definer set search_path = ''
as $function$
declare expected text; actual text; result text;
begin
  if session_user <> 'ai_quota_admin_login' then raise exception 'invalid admin login'; end if;
  expected := case p_target
    when 'dev' then 'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku'
    when 'production' then 'shared-supabase-db:target=production;project_ref=fsrbddgyysssqzyullrc'
    else null end;
  select pg_catalog.shobj_description(d.oid, 'pg_database') into actual
    from pg_catalog.pg_database d where d.datname=pg_catalog.current_database();
  if expected is null or actual is distinct from expected then raise exception 'database identity mismatch'; end if;
  select ai_quota_admin.fingerprint(s.developer_user_id) into result from ai_quota.settings s where s.id=1;
  if not found then raise exception 'settings unavailable'; end if;
  return result;
end
$function$;
revoke all on function ai_quota_admin.preview_developer(text) from public, anon, authenticated, service_role, ai_quota_backend;
grant execute on function ai_quota_admin.preview_developer(text) to ai_quota_admin_login;

create function ai_quota_admin.audit_developer(p_target text, p_run_id bigint)
returns table (operation text, actor text, before_fingerprint text, after_fingerprint text, occurred_at timestamptz)
language plpgsql security definer set search_path = ''
as $function$
declare expected text; actual text;
begin
  if session_user <> 'ai_quota_admin_login' then raise exception 'invalid admin login'; end if;
  expected := case p_target
    when 'dev' then 'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku'
    when 'production' then 'shared-supabase-db:target=production;project_ref=fsrbddgyysssqzyullrc'
    else null end;
  select pg_catalog.shobj_description(d.oid, 'pg_database') into actual
    from pg_catalog.pg_database d where d.datname=pg_catalog.current_database();
  if expected is null or actual is distinct from expected then raise exception 'database identity mismatch'; end if;
  return query select a.operation, a.github_actor, ai_quota_admin.fingerprint(a.old_user_id),
    ai_quota_admin.fingerprint(a.new_user_id), a.occurred_at
    from ai_quota_admin.operation_log a where a.github_run_id=p_run_id and a.target=p_target;
end
$function$;
revoke all on function ai_quota_admin.audit_developer(text,bigint) from public, anon, authenticated, service_role, ai_quota_backend;
grant execute on function ai_quota_admin.audit_developer(text,bigint) to ai_quota_admin_login;

create function ai_quota_admin.change_developer(
  p_target text, p_operation text, p_expected text, p_new uuid, p_actor text, p_run_id bigint
)
returns table (changed boolean, old_fingerprint text, new_fingerprint text)
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $function$
declare
  v_expected_marker text;
  v_actual_marker text;
  v_old uuid;
  v_after uuid;
begin
  if session_user <> 'ai_quota_admin_login' then
    raise exception 'invalid admin login';
  end if;
  v_expected_marker := case p_target
    when 'dev' then 'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku'
    when 'production' then 'shared-supabase-db:target=production;project_ref=fsrbddgyysssqzyullrc'
    else null end;
  if v_expected_marker is null then raise exception 'invalid target'; end if;
  select pg_catalog.shobj_description(d.oid, 'pg_database') into v_actual_marker
    from pg_catalog.pg_database d where d.datname = pg_catalog.current_database();
  if v_actual_marker is distinct from v_expected_marker then raise exception 'database identity mismatch'; end if;
  if p_run_id is null or p_run_id <= 0 or p_actor is null or p_actor !~ '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$' then
    raise exception 'invalid audit metadata';
  end if;
  if p_operation is null or p_operation not in ('set','clear')
     or (p_operation='set' and p_new is null) or (p_operation='clear' and p_new is not null) then
    raise exception 'invalid operation';
  end if;
  select s.developer_user_id into v_old from ai_quota.settings s where s.id=1 for update;
  if not found then raise exception 'settings unavailable'; end if;
  if ai_quota_admin.fingerprint(v_old) is distinct from p_expected then raise exception 'settings changed since review'; end if;
  if v_old is not distinct from p_new then raise exception 'no change requested'; end if;
  if p_operation='set' and not ai_quota_auth_probe.is_valid_user(p_new) then
    raise exception 'account is unavailable or not eligible';
  end if;
  update ai_quota.settings set developer_user_id=p_new where id=1 returning developer_user_id into v_after;
  if v_after is distinct from p_new then raise exception 'post-update mismatch'; end if;
  insert into ai_quota_admin.operation_log (github_run_id,target,operation,old_user_id,new_user_id,github_actor)
    values (p_run_id,p_target,p_operation,v_old,v_after,p_actor);
  return query select true, ai_quota_admin.fingerprint(v_old), ai_quota_admin.fingerprint(v_after);
end
$function$;
revoke all on function ai_quota_admin.change_developer(text,text,text,uuid,text,bigint)
  from public, anon, authenticated, service_role, ai_quota_backend;
grant usage on schema ai_quota_admin to ai_quota_admin_login;
grant execute on function ai_quota_admin.change_developer(text,text,text,uuid,text,bigint) to ai_quota_admin_login;
reset role;
revoke ai_quota_admin_owner from current_user;
commit;

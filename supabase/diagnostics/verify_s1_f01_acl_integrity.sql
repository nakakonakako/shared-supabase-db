-- Read-only verification for the S1 F-01 table ACL migration.
-- Inspects catalog metadata and effective privileges only; never reads rows.
\set ON_ERROR_STOP on

begin transaction read only;
set local lock_timeout = '3s';
set local statement_timeout = '15s';

do $verify$
declare
  v_migration_count bigint;
  v_table_count integer;
  v_table_name text;
  v_role_name text;
  v_privilege_name text;
begin
  select count(*)
    into v_migration_count
  from supabase_migrations.schema_migrations
  where version = '20261015120000';

  if v_migration_count is distinct from 1 then
    raise exception 'S1 F-01 migration history check failed (expected exactly one row)';
  end if;

  select count(*)
    into v_table_count
  from pg_catalog.pg_class as c
  join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = any (array[
      'chat_messages', 'csv_presets', 'csv_transactions', 'receipt_items',
      'receipts', 'price_folders', 'price_records', 'price_memo_items',
      'price_stores'
    ])
    and c.relkind in ('r', 'p');

  if v_table_count <> 9 then
    raise exception 'S1 F-01 expected 9 public tables; found %', v_table_count;
  end if;

  if exists (
    select 1
    from pg_catalog.pg_class as c
    join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
    join pg_catalog.pg_roles as owner_role on owner_role.oid = c.relowner
    where n.nspname = 'public'
      and c.relname = any (array[
        'chat_messages', 'csv_presets', 'csv_transactions', 'receipt_items',
        'receipts', 'price_folders', 'price_records', 'price_memo_items',
        'price_stores'
      ])
      and c.relkind in ('r', 'p')
      and (owner_role.rolname <> 'postgres' or not c.relrowsecurity)
  ) then
    raise exception 'S1 F-01 owner or RLS state differs from the audited baseline';
  end if;

  foreach v_table_name in array array[
    'chat_messages', 'csv_presets', 'csv_transactions', 'receipt_items',
    'receipts', 'price_folders', 'price_records', 'price_memo_items',
    'price_stores'
  ] loop
    foreach v_role_name in array array['anon', 'authenticated'] loop
      foreach v_privilege_name in array array[
        'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'
      ] loop
        if pg_catalog.has_table_privilege(
          v_role_name,
          format('public.%I', v_table_name),
          v_privilege_name
        ) then
          raise exception 'S1 F-01 effective privilege remains: role %, table public.%, privilege %',
            v_role_name, v_table_name, v_privilege_name;
        end if;
      end loop;

      foreach v_privilege_name in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE'] loop
        if not pg_catalog.has_table_privilege(
          v_role_name,
          format('public.%I', v_table_name),
          v_privilege_name
        ) then
          raise exception 'S1 F-01 CRUD privilege missing: role %, table public.%, privilege %',
            v_role_name, v_table_name, v_privilege_name;
        end if;
      end loop;
    end loop;

    foreach v_privilege_name in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE'] loop
      if not pg_catalog.has_table_privilege(
        'service_role',
        format('public.%I', v_table_name),
        v_privilege_name
      ) then
        raise exception 'S1 F-01 service_role CRUD privilege missing: table public.%, privilege %',
          v_table_name, v_privilege_name;
      end if;
    end loop;
  end loop;

  -- Effective privileges include direct, PUBLIC, and inherited-role grants.
  if exists (
    select 1
    from pg_catalog.pg_default_acl as d
    cross join lateral pg_catalog.aclexplode(d.defaclacl) as acl
    where d.defaclrole = 'postgres'::regrole
      and d.defaclobjtype = 'r'
      and (
        d.defaclnamespace = 0
        or d.defaclnamespace = 'public'::regnamespace
      )
      and acl.privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN')
      and case
        when acl.grantee = 0 then true
        else exists (
          select 1
          from pg_catalog.pg_roles as target_role
          where target_role.rolname in ('anon', 'authenticated')
            and pg_catalog.pg_has_role(target_role.oid, acl.grantee, 'USAGE')
        )
      end
  ) then
    raise exception 'S1 F-01 postgres global/public default privileges remain effective';
  end if;

  raise notice 'PASS: F-01 migration history, 9 table ACLs, CRUD, RLS, service_role, and postgres defaults';
end
$verify$;

-- Visible residual-risk indicator: this migration intentionally leaves
-- supabase_admin defaults unchanged. These grants may affect future public
-- tables created by that internal role.
select
  'supabase_admin_public_default_grants_intentionally_unchanged' as check_name,
  count(*) as direct_target_grants_remaining
from pg_catalog.pg_default_acl as d
join pg_catalog.pg_namespace as n on n.oid = d.defaclnamespace
cross join lateral pg_catalog.aclexplode(d.defaclacl) as acl
join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
where d.defaclrole = 'supabase_admin'::regrole
  and d.defaclobjtype = 'r'
  and n.nspname = 'public'
  and grantee_role.rolname in ('anon', 'authenticated')
  and acl.privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN');

commit;

-- S1 F-01: remove table-wide and DDL privileges from Data API roles.
-- CRUD grants, RLS policies, RPCs, service_role, functions, and sequences
-- are intentionally unchanged. supabase_admin default privileges are not
-- changed because the migration role cannot SET ROLE to supabase_admin.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $preflight$
declare
  v_table_count integer;
  v_missing text;
begin
  if current_user <> 'postgres' then
    raise exception 'S1 F-01 migration requires current_user=postgres; got %', current_user;
  end if;

  if current_setting('server_version_num')::integer < 170000 then
    raise exception 'S1 F-01 migration requires PostgreSQL 17 or later for MAINTAIN';
  end if;

  if (select count(*) from pg_catalog.pg_roles
      where rolname in ('anon', 'authenticated', 'service_role')) <> 3 then
    raise exception 'S1 F-01 expected Supabase API roles are missing';
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
      and owner_role.rolname <> 'postgres'
  ) then
    raise exception 'S1 F-01 table ownership differs from the audited postgres owner';
  end if;

  -- Fail closed if the audited direct grants or grantor have changed since
  -- the read-only production preflight.
  select string_agg(format('%s/%s/%s', expected.table_name,
                          expected.grantee_name, expected.privilege_name), ', ')
    into v_missing
  from (
    select t.table_name, r.grantee_name, p.privilege_name
    from unnest(array[
      'chat_messages', 'csv_presets', 'csv_transactions', 'receipt_items',
      'receipts', 'price_folders', 'price_records', 'price_memo_items',
      'price_stores'
    ]) as t(table_name)
    cross join unnest(array['anon', 'authenticated']) as r(grantee_name)
    cross join unnest(array['TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'])
      as p(privilege_name)
  ) as expected
  where not exists (
    select 1
    from pg_catalog.pg_class as c
    join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
    cross join lateral pg_catalog.aclexplode(c.relacl) as acl
    join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
    join pg_catalog.pg_roles as grantor_role on grantor_role.oid = acl.grantor
    where n.nspname = 'public'
      and c.relname = expected.table_name
      and grantee_role.rolname = expected.grantee_name
      and grantor_role.rolname = 'postgres'
      and acl.privilege_type = expected.privilege_name
  );

  if v_missing is not null then
    raise exception 'S1 F-01 audited direct grants/grantor changed: %', v_missing;
  end if;

  -- Schema-specific REVOKE cannot cancel global default grants. Stop if one
  -- exists for either target role, PUBLIC, or a role inherited by a target.
  if exists (
    select 1
    from pg_catalog.pg_default_acl as d
    cross join lateral pg_catalog.aclexplode(d.defaclacl) as acl
    where d.defaclrole = 'postgres'::regrole
      and d.defaclobjtype = 'r'
      and d.defaclnamespace = 0
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
    raise exception 'S1 F-01 unexpected global default grant; schema-only REVOKE is insufficient';
  end if;

  -- Confirm the schema-scoped grants reported by the production audit.
  select string_agg(format('%s/%s/%s', expected.grantee_name,
                          expected.privilege_name), ', ')
    into v_missing
  from (
    select r.grantee_name, p.privilege_name
    from unnest(array['anon', 'authenticated']) as r(grantee_name)
    cross join unnest(array['TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'])
      as p(privilege_name)
  ) as expected
  where not exists (
    select 1
    from pg_catalog.pg_default_acl as d
    join pg_catalog.pg_namespace as n on n.oid = d.defaclnamespace
    cross join lateral pg_catalog.aclexplode(d.defaclacl) as acl
    join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
    join pg_catalog.pg_roles as grantor_role on grantor_role.oid = acl.grantor
    where d.defaclrole = 'postgres'::regrole
      and d.defaclobjtype = 'r'
      and n.nspname = 'public'
      and grantee_role.rolname = expected.grantee_name
      and grantor_role.rolname = 'postgres'
      and acl.privilege_type = expected.privilege_name
  );

  if v_missing is not null then
    raise exception 'S1 F-01 audited postgres public default grants changed: %', v_missing;
  end if;
end
$preflight$;

revoke truncate, references, trigger, maintain
  on table
    public.chat_messages,
    public.csv_presets,
    public.csv_transactions,
    public.receipt_items,
    public.receipts,
    public.price_folders,
    public.price_records,
    public.price_memo_items,
    public.price_stores
  from anon, authenticated
  restrict;

alter default privileges for role postgres in schema public
  revoke truncate, references, trigger, maintain
  on tables from anon, authenticated;

do $postflight$
declare
  v_table_name text;
  v_role_name text;
  v_privilege_name text;
begin
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
          raise exception 'S1 F-01 CRUD privilege unexpectedly missing: role %, table public.%, privilege %',
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
        raise exception 'S1 F-01 service_role CRUD privilege unexpectedly missing: table public.%, privilege %',
          v_table_name, v_privilege_name;
      end if;
    end loop;
  end loop;

  -- Check effective defaults across both global and public scopes. This also
  -- catches PUBLIC and inherited-role grants, not just direct ACL entries.
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
end
$postflight$;

commit;

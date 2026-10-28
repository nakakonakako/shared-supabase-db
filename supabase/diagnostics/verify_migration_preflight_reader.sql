-- Run as the dedicated login role granted migration_preflight_reader.
-- Read-only checks; the role must never be granted application data access.
\set ON_ERROR_STOP on

BEGIN TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';

DO $verify$
DECLARE
  v_role text := current_user;
BEGIN
  IF NOT pg_catalog.pg_has_role(v_role, 'migration_preflight_reader', 'USAGE') THEN
    RAISE EXCEPTION 'connected role is not a member of migration_preflight_reader';
  END IF;

  IF EXISTS (
      SELECT 1
      FROM pg_catalog.pg_roles AS r
      WHERE r.rolname = v_role
        AND (r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolreplication OR r.rolbypassrls)
    ) THEN
    RAISE EXCEPTION 'connected login has privileged role attributes';
  END IF;

  IF pg_catalog.pg_has_role(v_role, 'anon', 'USAGE')
     OR pg_catalog.pg_has_role(v_role, 'authenticated', 'USAGE')
     OR pg_catalog.pg_has_role(v_role, 'service_role', 'USAGE')
     OR pg_catalog.pg_has_role(v_role, 'postgres', 'USAGE') THEN
    RAISE EXCEPTION 'connected login inherits an application or administrator role';
  END IF;

  IF pg_catalog.has_database_privilege(v_role, pg_catalog.current_database(), 'CREATE')
     OR pg_catalog.has_schema_privilege(v_role, 'public', 'CREATE')
     OR pg_catalog.has_schema_privilege(v_role, 'supabase_migrations', 'CREATE') THEN
    RAISE EXCEPTION 'connected login can create persistent database objects';
  END IF;

  IF NOT pg_catalog.has_schema_privilege(v_role, 'supabase_migrations', 'USAGE')
     OR NOT pg_catalog.has_column_privilege(
       v_role,
       'supabase_migrations.schema_migrations',
       'version',
       'SELECT'
     ) THEN
    RAISE EXCEPTION 'connected login cannot read the migration version history';
  END IF;

  IF EXISTS (
      SELECT 1
      FROM pg_catalog.pg_class AS c
      JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
        AND pg_catalog.has_table_privilege(v_role, c.oid, 'SELECT')
    ) THEN
    RAISE EXCEPTION 'connected login can read public application data';
  END IF;

  IF EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc AS p
      JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname IN ('public', 'ai_quota')
        AND p.prosecdef
        AND p.prorettype <> 'trigger'::pg_catalog.regtype
        AND pg_catalog.has_function_privilege(v_role, p.oid, 'EXECUTE')
    ) THEN
    RAISE EXCEPTION 'connected login can execute an application SECURITY DEFINER function';
  END IF;

  IF NOT pg_catalog.has_column_privilege(
       v_role, 'ai_quota.settings', 'id', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'connected login cannot check the AI quota singleton row';
  END IF;

  IF EXISTS (
      SELECT 1
      FROM pg_catalog.pg_attribute AS a
      WHERE a.attrelid = 'ai_quota.settings'::pg_catalog.regclass
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND a.attname <> 'id'
        AND pg_catalog.has_column_privilege(v_role, a.attrelid, a.attname, 'SELECT')
    ) OR EXISTS (
      SELECT 1
      FROM pg_catalog.pg_attribute AS a
      WHERE a.attrelid = 'ai_quota.requests'::pg_catalog.regclass
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND pg_catalog.has_column_privilege(v_role, a.attrelid, a.attname, 'SELECT')
    ) THEN
    RAISE EXCEPTION 'connected login can read AI quota configuration or request data';
  END IF;
END
$verify$;

COMMIT;

-- Verify the dedicated production DB check login's effective read privileges.
-- Run as migration_preflight_login; no application rows or setting values read.
\set ON_ERROR_STOP on

BEGIN TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';

DO $verify$
DECLARE
  v_role text := current_user;
BEGIN
  IF v_role IS DISTINCT FROM 'migration_preflight_login' THEN
    RAISE EXCEPTION 'connected role is not the dedicated production DB reader login';
  END IF;
  IF NOT pg_catalog.pg_has_role(v_role, 'migration_preflight_reader', 'USAGE') THEN
    RAISE EXCEPTION 'connected role is not a member of migration_preflight_reader';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_auth_members AS m
    JOIN pg_catalog.pg_roles AS member_role ON member_role.oid = m.member
    JOIN pg_catalog.pg_roles AS granted_role ON granted_role.oid = m.roleid
    WHERE member_role.rolname = v_role
      AND granted_role.rolname = 'migration_preflight_reader'
      AND m.inherit_option
      AND NOT m.set_option
      AND NOT m.admin_option
  ) THEN
    RAISE EXCEPTION 'reader login must inherit reader privileges without SET or ADMIN options';
  END IF;
  IF pg_catalog.current_setting('default_transaction_read_only') IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'reader login must default to read-only transactions';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = v_role
      AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
  ) THEN
    RAISE EXCEPTION 'reader login has privileged role attributes';
  END IF;
  IF pg_catalog.pg_has_role(v_role, 'anon', 'USAGE')
     OR pg_catalog.pg_has_role(v_role, 'authenticated', 'USAGE')
     OR pg_catalog.pg_has_role(v_role, 'service_role', 'USAGE')
     OR pg_catalog.pg_has_role(v_role, 'postgres', 'USAGE') THEN
    RAISE EXCEPTION 'reader login inherits an application or administrator role';
  END IF;
  IF pg_catalog.pg_has_role(v_role, 'ai_quota_owner', 'MEMBER') THEN
    RAISE EXCEPTION 'reader login is a member of ai_quota_owner';
  END IF;
  IF pg_catalog.has_database_privilege(v_role, pg_catalog.current_database(), 'CREATE')
     OR pg_catalog.has_schema_privilege(v_role, 'public', 'CREATE')
     OR pg_catalog.has_schema_privilege(v_role, 'supabase_migrations', 'CREATE') THEN
    RAISE EXCEPTION 'reader login can create persistent objects';
  END IF;
  IF NOT pg_catalog.has_schema_privilege(v_role, 'supabase_migrations', 'USAGE')
     OR NOT pg_catalog.has_column_privilege(
       v_role, 'supabase_migrations.schema_migrations', 'version', 'SELECT'
     )
     OR NOT pg_catalog.has_schema_privilege(v_role, 'ai_quota', 'USAGE')
     OR NOT pg_catalog.has_column_privilege(
       v_role, 'ai_quota.settings', 'id', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'reader login lacks the narrow metadata grants';
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
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND pg_catalog.has_table_privilege(v_role, c.oid, 'SELECT')
  ) THEN
    RAISE EXCEPTION 'reader login can read application or AI quota data';
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
    RAISE EXCEPTION 'reader login can execute an application SECURITY DEFINER function';
  END IF;
END
$verify$;

COMMIT;

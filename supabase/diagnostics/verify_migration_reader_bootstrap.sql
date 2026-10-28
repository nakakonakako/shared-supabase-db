-- Read-only ongoing check for reader-role and ai_quota_owner membership.
-- It does not inspect application rows or AI quota setting values.
\set ON_ERROR_STOP on

BEGIN TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';

DO $verify$
DECLARE
  v_migration_count bigint;
  v_executor oid;
  v_owner oid;
  v_admin boolean;
  v_set boolean;
  v_inherit boolean;
BEGIN
  SELECT count(*) INTO v_migration_count
  FROM supabase_migrations.schema_migrations
  WHERE version = '20261027150000';
  IF v_migration_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'reader bootstrap migration must have exactly one history row';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = 'migration_preflight_reader'
      AND rolcanlogin = false
      AND rolsuper = false
      AND rolcreatedb = false
      AND rolcreaterole = false
      AND rolreplication = false
      AND rolbypassrls = false
      AND rolinherit = false
  ) THEN
    RAISE EXCEPTION 'migration_preflight_reader attributes are not least-privilege';
  END IF;

  IF NOT pg_catalog.has_column_privilege(
    'migration_preflight_reader',
    'supabase_migrations.schema_migrations',
    'version',
    'SELECT'
  ) OR NOT pg_catalog.has_column_privilege(
    'migration_preflight_reader', 'ai_quota.settings', 'id', 'SELECT'
  ) THEN
    RAISE EXCEPTION 'reader role is missing its required version or singleton-id access';
  END IF;

  IF NOT pg_catalog.has_database_privilege(
       'migration_preflight_reader', pg_catalog.current_database(), 'CONNECT'
     )
     OR NOT pg_catalog.has_schema_privilege(
       'migration_preflight_reader', 'supabase_migrations', 'USAGE'
     )
     OR NOT pg_catalog.has_schema_privilege(
       'migration_preflight_reader', 'ai_quota', 'USAGE'
     ) THEN
    RAISE EXCEPTION 'reader role is missing required database or schema access';
  END IF;

  IF pg_catalog.has_database_privilege(
       'migration_preflight_reader', pg_catalog.current_database(), 'CREATE'
     )
     OR pg_catalog.has_schema_privilege(
       'migration_preflight_reader', 'public', 'CREATE'
     )
     OR pg_catalog.has_schema_privilege(
       'migration_preflight_reader', 'supabase_migrations', 'CREATE'
     )
     OR pg_catalog.has_schema_privilege(
       'migration_preflight_reader', 'ai_quota', 'CREATE'
     ) THEN
    RAISE EXCEPTION 'reader role can create persistent database objects';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_attribute AS a
    WHERE a.attrelid = 'ai_quota.settings'::pg_catalog.regclass
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND a.attname <> 'id'
      AND pg_catalog.has_column_privilege(
        'migration_preflight_reader', a.attrelid, a.attname, 'SELECT'
      )
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_attribute AS a
    WHERE a.attrelid = 'ai_quota.requests'::pg_catalog.regclass
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND pg_catalog.has_column_privilege(
        'migration_preflight_reader', a.attrelid, a.attname, 'SELECT'
      )
  ) THEN
    RAISE EXCEPTION 'reader role can access AI quota values or request rows';
  END IF;

  SELECT oid INTO v_executor
  FROM pg_catalog.pg_roles
  WHERE rolname = 'postgres';
  SELECT oid INTO v_owner
  FROM pg_catalog.pg_roles
  WHERE rolname = 'ai_quota_owner';
  SELECT m.admin_option, m.set_option, m.inherit_option
    INTO v_admin, v_set, v_inherit
  FROM pg_catalog.pg_auth_members AS m
  WHERE m.roleid = v_owner AND m.member = v_executor;
  IF v_admin IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'postgres must retain ADMIN OPTION on ai_quota_owner';
  END IF;
  IF v_set IS DISTINCT FROM false OR v_inherit IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'postgres retained effective ai_quota_owner SET/INHERIT access';
  END IF;
END
$verify$;

COMMIT;

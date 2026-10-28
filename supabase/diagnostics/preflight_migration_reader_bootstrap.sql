-- Read-only preflight before the one-time reader-role migration.
-- Run as the same session role used by Supabase CLI migration apply.
\set ON_ERROR_STOP on

BEGIN TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';

DO $preflight$
DECLARE
  v_executor oid;
  v_owner oid;
  v_admin boolean;
  v_set boolean;
  v_inherit boolean;
BEGIN
  SELECT oid INTO v_executor
  FROM pg_catalog.pg_roles
  WHERE rolname = current_user;
  SELECT oid INTO v_owner
  FROM pg_catalog.pg_roles
  WHERE rolname = 'ai_quota_owner';

  IF v_executor IS NULL OR v_owner IS NULL
     OR pg_catalog.to_regclass('ai_quota.settings') IS NULL
     OR pg_catalog.to_regclass('supabase_migrations.schema_migrations') IS NULL THEN
    RAISE EXCEPTION 'reader bootstrap prerequisites are missing';
  END IF;

  SELECT m.admin_option, m.set_option, m.inherit_option
    INTO v_admin, v_set, v_inherit
  FROM pg_catalog.pg_auth_members AS m
  WHERE m.roleid = v_owner AND m.member = v_executor;

  IF v_admin IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'migration executor lacks ADMIN OPTION on ai_quota_owner';
  END IF;
  IF v_set IS DISTINCT FROM false OR v_inherit IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'ai_quota_owner membership must be ADMIN-only before reader bootstrap';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = 'migration_preflight_reader'
  ) THEN
    RAISE EXCEPTION 'reader role already exists; use bootstrap verification, not first-apply';
  END IF;

END
$preflight$;

COMMIT;

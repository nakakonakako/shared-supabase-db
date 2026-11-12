-- Catalog-only Reader check; no account or audit rows are disclosed.
\set ON_ERROR_STOP on
BEGIN TRANSACTION READ ONLY;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='15s';
DO $verify$
DECLARE r text; f oid; audit_table oid;
BEGIN
  SELECT c.oid INTO audit_table FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='ai_quota_admin' AND c.relname='operation_log' AND c.relkind='r';
  IF audit_table IS NULL THEN RAISE EXCEPTION 'admin audit table missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='ai_quota_admin_owner'
    AND NOT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolinherit)
    OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='ai_quota_admin_login'
    AND rolcanlogin AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolinherit) THEN
    RAISE EXCEPTION 'admin role attributes invalid';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles r ON r.oid=m.member
    WHERE r.rolname='ai_quota_admin_login') THEN RAISE EXCEPTION 'admin login must not inherit roles'; END IF;
  FOREACH r IN ARRAY ARRAY['public','anon','authenticated','service_role','ai_quota_backend','migration_preflight_reader'] LOOP
    IF pg_catalog.has_schema_privilege(r,'ai_quota_admin','USAGE')
      OR pg_catalog.has_schema_privilege(r,'ai_quota_auth_probe','USAGE') THEN RAISE EXCEPTION 'admin schema exposed'; END IF;
    FOR f IN SELECT p.oid FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname IN ('ai_quota_admin','ai_quota_auth_probe') LOOP
      IF pg_catalog.has_function_privilege(r,f,'EXECUTE') THEN RAISE EXCEPTION 'admin function exposed'; END IF;
    END LOOP;
  END LOOP;
  IF pg_catalog.has_schema_privilege('ai_quota_admin_login','ai_quota_auth_probe','USAGE')
    OR EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='ai_quota_auth_probe' AND pg_catalog.has_function_privilege('ai_quota_admin_login',p.oid,'EXECUTE'))
    OR pg_catalog.has_table_privilege('ai_quota_admin_login',audit_table,'SELECT')
    OR pg_catalog.has_column_privilege('ai_quota_admin_login','ai_quota.settings','developer_user_id','UPDATE') THEN
    RAISE EXCEPTION 'admin login has direct privileges';
  END IF;
  IF (SELECT count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='ai_quota_admin' AND p.proname IN ('change_developer','preview_developer','audit_developer')
        AND pg_catalog.has_function_privilege('ai_quota_admin_login',p.oid,'EXECUTE')) <> 3 THEN
    RAISE EXCEPTION 'admin functions unavailable';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
    JOIN pg_catalog.pg_roles owner ON owner.oid=p.proowner
    WHERE (n.nspname='ai_quota_admin' AND p.proname IN ('preview_developer','audit_developer','change_developer')
      AND (owner.rolname <> 'ai_quota_admin_owner' OR NOT p.prosecdef OR p.proconfig IS NULL OR NOT ('search_path=""'=ANY(p.proconfig))))
      OR (n.nspname='ai_quota_auth_probe' AND p.proname='is_valid_user'
      AND (owner.rolname <> 'postgres' OR NOT p.prosecdef OR p.proconfig IS NULL OR NOT ('search_path=""'=ANY(p.proconfig))))
  ) THEN RAISE EXCEPTION 'admin function owner or configuration invalid'; END IF;
  RAISE NOTICE 'PASS: AI quota admin role and function boundaries';
END
$verify$;
COMMIT;

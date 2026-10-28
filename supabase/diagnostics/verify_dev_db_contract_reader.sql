-- Reuse the production Reader audit, then reject CREATE on any schema in Dev.
-- This file is only used by the Dev contract workflow and disposable tests.
\set ON_ERROR_STOP on
\ir verify_production_db_reader.sql

BEGIN TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';

DO $verify_dev_reader$
DECLARE
  v_role text := current_user;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_namespace AS n
    WHERE pg_catalog.has_schema_privilege(v_role, n.oid, 'CREATE')
  ) THEN
    RAISE EXCEPTION 'Dev Reader can create objects in a schema';
  END IF;
END
$verify_dev_reader$;

COMMIT;

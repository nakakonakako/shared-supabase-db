-- Read-only verification for the S1-08 production RPC migration.
-- This file inspects migration metadata and PostgreSQL catalogs only.
\set ON_ERROR_STOP on

BEGIN TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';

DO $verify$
DECLARE
  v_migration_count bigint;
  v_rename_oid oid;
  v_reorder_oid oid;
  v_proc pg_catalog.pg_proc%ROWTYPE;
BEGIN
  SELECT pg_catalog.count(*)
    INTO v_migration_count
  FROM supabase_migrations.schema_migrations
  WHERE version = '20261010010000';

  IF v_migration_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'S1-08 migration history check failed (expected exactly one row)';
  END IF;

  IF (SELECT pg_catalog.count(*)
      FROM pg_catalog.pg_proc AS p
      JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'rename_price_store') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'rename_price_store is missing or has unexpected overloads';
  END IF;
  v_rename_oid := pg_catalog.to_regprocedure('public.rename_price_store(uuid,text)');
  IF v_rename_oid IS NULL THEN
    RAISE EXCEPTION 'rename_price_store(uuid,text) is missing';
  END IF;
  SELECT * INTO STRICT v_proc FROM pg_catalog.pg_proc WHERE oid = v_rename_oid;
  IF v_proc.prokind IS DISTINCT FROM 'f'
     OR v_proc.proargmodes IS NOT NULL
     OR v_proc.proretset IS DISTINCT FROM false
     OR v_proc.proargnames IS DISTINCT FROM ARRAY['p_store_id', 'p_name']::text[]
     OR pg_catalog.pg_get_function_identity_arguments(v_rename_oid)
        IS DISTINCT FROM 'p_store_id uuid, p_name text'
     OR v_proc.prorettype IS DISTINCT FROM 'public.price_stores'::pg_catalog.regtype
     OR (SELECT l.lanname
         FROM pg_catalog.pg_language AS l
         WHERE l.oid = v_proc.prolang) IS DISTINCT FROM 'plpgsql' THEN
    RAISE EXCEPTION 'rename_price_store signature or return type does not match';
  END IF;
  IF v_proc.prosecdef IS DISTINCT FROM false
     OR v_proc.proconfig IS DISTINCT FROM ARRAY['search_path=""']::text[] THEN
    RAISE EXCEPTION 'rename_price_store must be SECURITY INVOKER with an empty search_path';
  END IF;
  IF pg_catalog.has_function_privilege('public', v_rename_oid, 'EXECUTE') IS DISTINCT FROM false
     OR pg_catalog.has_function_privilege('anon', v_rename_oid, 'EXECUTE') IS DISTINCT FROM false
     OR pg_catalog.has_function_privilege('authenticated', v_rename_oid, 'EXECUTE') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'rename_price_store EXECUTE permissions do not match';
  END IF;

  IF (SELECT pg_catalog.count(*)
      FROM pg_catalog.pg_proc AS p
      JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'reorder_price_memo_items') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'reorder_price_memo_items is missing or has unexpected overloads';
  END IF;
  v_reorder_oid := pg_catalog.to_regprocedure(
    'public.reorder_price_memo_items(uuid[],uuid[])'
  );
  IF v_reorder_oid IS NULL THEN
    RAISE EXCEPTION 'reorder_price_memo_items(uuid[],uuid[]) is missing';
  END IF;
  SELECT * INTO STRICT v_proc FROM pg_catalog.pg_proc WHERE oid = v_reorder_oid;
  IF v_proc.prokind IS DISTINCT FROM 'f'
     OR v_proc.proargmodes IS NOT NULL
     OR v_proc.proretset IS DISTINCT FROM false
     OR v_proc.proargnames IS DISTINCT FROM ARRAY[
       'p_expected_folder_ids', 'p_folder_ids'
     ]::text[]
     OR pg_catalog.pg_get_function_identity_arguments(v_reorder_oid)
        IS DISTINCT FROM 'p_expected_folder_ids uuid[], p_folder_ids uuid[]'
     OR v_proc.prorettype IS DISTINCT FROM 'void'::pg_catalog.regtype
     OR (SELECT l.lanname
         FROM pg_catalog.pg_language AS l
         WHERE l.oid = v_proc.prolang) IS DISTINCT FROM 'plpgsql' THEN
    RAISE EXCEPTION 'reorder_price_memo_items signature or return type does not match';
  END IF;
  IF v_proc.prosecdef IS DISTINCT FROM false
     OR v_proc.proconfig IS DISTINCT FROM ARRAY['search_path=""']::text[] THEN
    RAISE EXCEPTION 'reorder_price_memo_items must be SECURITY INVOKER with an empty search_path';
  END IF;
  IF pg_catalog.has_function_privilege('public', v_reorder_oid, 'EXECUTE') IS DISTINCT FROM false
     OR pg_catalog.has_function_privilege('anon', v_reorder_oid, 'EXECUTE') IS DISTINCT FROM false
     OR pg_catalog.has_function_privilege('authenticated', v_reorder_oid, 'EXECUTE') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'reorder_price_memo_items EXECUTE permissions do not match';
  END IF;

  RAISE NOTICE 'PASS: S1-08 migration history and both RPC definitions, signatures, security, and permissions';
END
$verify$;

COMMIT;

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${PRICE_MEMO_TEST_DATABASE_URL:?Set PRICE_MEMO_TEST_DATABASE_URL to a fresh disposable local PostgreSQL database named price_memo_data_deletion_test}"

python3 - <<'PY'
import os
from urllib.parse import urlparse

url = urlparse(os.environ["PRICE_MEMO_TEST_DATABASE_URL"])
if url.hostname not in {"localhost", "127.0.0.1", "::1"}:
    raise SystemExit("Refusing SQL test: database host must be localhost or loopback.")
PY

database_name="$(psql "$PRICE_MEMO_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc 'select current_database()')"
if [[ "$database_name" != "price_memo_data_deletion_test" ]]; then
  echo "Refusing SQL test: database must be named price_memo_data_deletion_test." >&2
  exit 1
fi

is_fresh="$(psql "$PRICE_MEMO_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc "
  select pg_catalog.to_regnamespace('auth') is null
    and pg_catalog.to_regclass('public.price_folders') is null
    and pg_catalog.to_regclass('public.price_records') is null
    and pg_catalog.to_regclass('public.price_memo_items') is null
    and pg_catalog.to_regclass('public.price_stores') is null
    and not exists (
      select 1 from pg_catalog.pg_roles
      where rolname in ('anon', 'authenticated', 'service_role')
    )
")"
if [[ "$is_fresh" != "t" ]]; then
  echo "Refusing SQL test: database or cluster is not fresh and disposable." >&2
  exit 1
fi

echo "Creating isolated Auth, receipt, and price-memo test tables..."
psql "$PRICE_MEMO_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/tests/price_memo_data_deletion/setup.sql

echo "Applying the migration to the disposable database..."
psql "$PRICE_MEMO_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261016100000_delete_my_price_memo_data.sql

echo "Checking RPC security attributes and execute grants..."
psql "$PRICE_MEMO_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
DO $verify$
DECLARE
  v_function oid := 'public.delete_my_price_memo_data()'::regprocedure;
  v_config text[];
BEGIN
  SELECT proconfig INTO v_config FROM pg_catalog.pg_proc WHERE oid = v_function;
  IF (SELECT prosecdef FROM pg_catalog.pg_proc WHERE oid = v_function)
    OR NOT ('search_path=""' = ANY (v_config))
    OR pg_catalog.has_function_privilege('authenticated', v_function, 'EXECUTE') IS NOT TRUE
    OR pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE') IS TRUE
    OR pg_catalog.has_function_privilege('service_role', v_function, 'EXECUTE') IS TRUE
    OR EXISTS (
      SELECT 1 FROM pg_catalog.aclexplode(
        coalesce((SELECT proacl FROM pg_catalog.pg_proc WHERE oid = v_function),
                 pg_catalog.acldefault('f', (SELECT proowner FROM pg_catalog.pg_proc WHERE oid = v_function)))
      ) AS acl
      WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE'
    ) THEN
    RAISE EXCEPTION 'RPC security attributes or execute grants are incorrect';
  END IF;
END
$verify$;
SQL

echo "Running ownership, rollback, Auth, receipt, and empty-data checks..."
psql "$PRICE_MEMO_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/tests/price_memo_data_deletion/test.sql

echo "All price-memo data deletion SQL tests passed."

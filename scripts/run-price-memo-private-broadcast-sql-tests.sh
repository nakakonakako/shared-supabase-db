#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${PRICE_MEMO_BROADCAST_TEST_DATABASE_URL:?Set PRICE_MEMO_BROADCAST_TEST_DATABASE_URL to a fresh disposable local PostgreSQL database named price_memo_private_broadcast_test}"

python3 - <<'PY'
import os
from urllib.parse import urlparse

url = urlparse(os.environ["PRICE_MEMO_BROADCAST_TEST_DATABASE_URL"])
if url.hostname not in {"localhost", "127.0.0.1", "::1"}:
    raise SystemExit("Refusing SQL test: database host must be localhost or loopback.")
PY

database_name="$(psql "$PRICE_MEMO_BROADCAST_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc 'select current_database()')"
if [[ "$database_name" != "price_memo_private_broadcast_test" ]]; then
  echo "Refusing SQL test: database must be named price_memo_private_broadcast_test." >&2
  exit 1
fi

is_fresh="$(psql "$PRICE_MEMO_BROADCAST_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc "
  select pg_catalog.to_regnamespace('auth') is null
    and pg_catalog.to_regnamespace('realtime') is null
    and pg_catalog.to_regclass('public.price_folders') is null
    and not exists (
      select 1 from pg_catalog.pg_roles
      where rolname in ('anon', 'authenticated', 'service_role')
    )
")"
if [[ "$is_fresh" != "t" ]]; then
  echo "Refusing SQL test: database or cluster is not fresh and disposable." >&2
  exit 1
fi

echo "Creating isolated Auth, Realtime, and price-memo test objects..."
psql "$PRICE_MEMO_BROADCAST_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/tests/price_memo_private_broadcast/setup.sql

echo "Applying the private Broadcast migration to the disposable database..."
psql "$PRICE_MEMO_BROADCAST_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261018120000_price_memo_private_broadcast.sql
psql "$PRICE_MEMO_BROADCAST_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261016100000_delete_my_price_memo_data.sql

echo "Checking event routing, payload minimization, authorization, cascades, and failures..."
psql "$PRICE_MEMO_BROADCAST_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/tests/price_memo_private_broadcast/test.sql

echo "All price-memo private Broadcast SQL tests passed."

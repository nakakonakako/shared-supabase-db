#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
: "${DB_CONTRACT_TEST_DATABASE_URL:?Set DB_CONTRACT_TEST_DATABASE_URL to the fresh disposable db_contract_test database}"

python3 - <<'PY'
import os
from urllib.parse import urlparse

target = urlparse(os.environ["DB_CONTRACT_TEST_DATABASE_URL"])
if target.hostname not in {"localhost", "127.0.0.1", "::1"}:
    raise SystemExit("Refusing DB contract SQL test: host must be localhost or loopback")
if not target.path.lstrip("/") or not target.username:
    raise SystemExit("Refusing DB contract SQL test: URL is missing connection fields")
PY
while IFS='=' read -r name value; do export "$name=$value"; done < <(python3 - <<'PY'
import os
from urllib.parse import urlparse

target = urlparse(os.environ["DB_CONTRACT_TEST_DATABASE_URL"])
for key, value in {
    "PGHOST": target.hostname,
    "PGPORT": str(target.port or 5432),
    "PGDATABASE": target.path.lstrip("/"),
    "PGUSER": target.username or "",
    "PGSSLMODE": "disable",
}.items():
    print(f"{key}={value}")
PY
)

database_name="$(psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -Atqc 'select current_database()')"
if [[ "$database_name" != "db_contract_test" ]]; then
  echo "Refusing DB contract SQL test: database must be named db_contract_test." >&2
  exit 1
fi

fresh="$(psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -Atqc "
  SELECT pg_catalog.to_regnamespace('auth') IS NULL
    AND pg_catalog.to_regnamespace('realtime') IS NULL
    AND pg_catalog.to_regclass('public.fixture_items') IS NULL
    AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname IN ('anon','authenticated'))
")"
if [[ "$fresh" != "t" ]]; then
  echo "Refusing DB contract SQL test: database/cluster is not fresh and disposable." >&2
  exit 1
fi

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT NULL::uuid $$;
CREATE SCHEMA realtime;
CREATE TABLE realtime.messages (id bigint);
ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;
CREATE FUNCTION realtime.topic() RETURNS text LANGUAGE sql STABLE AS $$ SELECT NULL::text $$;
CREATE TABLE public.fixture_items (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  label text NOT NULL,
  optional_note text,
  UNIQUE (user_id, label)
);
ALTER TABLE public.fixture_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY fixture_items_owner_all ON public.fixture_items
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.fixture_items TO authenticated;
CREATE FUNCTION public.fixture_lookup(uuid)
RETURNS text LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT $1::text $$;
REVOKE ALL ON FUNCTION public.fixture_lookup(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_lookup(uuid) TO authenticated;
CREATE FUNCTION public.fixture_items_broadcast_trigger()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
CREATE TRIGGER fixture_items_broadcast BEFORE INSERT ON public.fixture_items
  FOR EACH ROW EXECUTE FUNCTION public.fixture_items_broadcast_trigger();
SQL

python3 scripts/check-db-contract.py scripts/fixtures/db-contract-v1.example.json
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
ALTER TABLE public.fixture_items ADD COLUMN future_optional text;
CREATE TABLE public.unrelated_additive_table (id uuid PRIMARY KEY);
SQL
python3 scripts/check-db-contract.py scripts/fixtures/db-contract-v1.example.json
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'ALTER TABLE public.fixture_items ALTER COLUMN optional_note SET NOT NULL' >/dev/null
output="$(mktemp "${TMPDIR:-/tmp}/db-contract-mismatch.XXXXXX")"
trap 'rm -f -- "$output"' EXIT INT TERM
if python3 scripts/check-db-contract.py scripts/fixtures/db-contract-v1.example.json >"$output" 2>&1; then
  echo "Incompatible NULL constraint was accepted." >&2
  exit 1
fi
grep -q 'optional_note type/nullability' "$output"
rm -f -- "$output"
echo "PASS: PostgreSQL catalog contract checks detect NULLability drift"

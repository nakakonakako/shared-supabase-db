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
CREATE TABLE public.relation_probe (id uuid);
ALTER TABLE public.fixture_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY fixture_items_owner_all ON public.fixture_items
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.fixture_items TO authenticated;
CREATE FUNCTION public.fixture_lookup(p_user_id uuid)
RETURNS text LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT $1::text $$;
REVOKE ALL ON FUNCTION public.fixture_lookup(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_lookup(uuid) TO authenticated;
CREATE FUNCTION public.fixture_mode(IN p_user_id uuid)
RETURNS uuid LANGUAGE sql SECURITY INVOKER AS $$ SELECT $1 $$;
REVOKE ALL ON FUNCTION public.fixture_mode(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_mode(uuid) TO authenticated;
CREATE FUNCTION public.fixture_unnamed(uuid)
RETURNS uuid LANGUAGE sql SECURITY INVOKER AS $$ SELECT $1 $$;
REVOKE ALL ON FUNCTION public.fixture_unnamed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_unnamed(uuid) TO authenticated;
CREATE FUNCTION public.fixture_rows()
RETURNS TABLE(row_id uuid) LANGUAGE sql SECURITY INVOKER AS $$ SELECT NULL::uuid $$;
REVOKE ALL ON FUNCTION public.fixture_rows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_rows() TO authenticated;
CREATE FUNCTION public.fixture_procedure_probe()
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$ BEGIN RETURN; END $$;
REVOKE ALL ON FUNCTION public.fixture_procedure_probe() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_procedure_probe() TO authenticated;
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
output="$(mktemp "${TMPDIR:-/tmp}/db-contract-mismatch.XXXXXX")"
not_valid_contract="$(mktemp "${TMPDIR:-/tmp}/db-contract-not-valid.XXXXXX")"
trap 'rm -f -- "$output" "$not_valid_contract"' EXIT INT TERM

expect_failure() {
  local assertion="$1" contract_file="${2:-scripts/fixtures/db-contract-v1.example.json}"
  if python3 scripts/check-db-contract.py "$contract_file" >"$output" 2>&1; then
    echo "Expected DB contract failure was accepted: $assertion" >&2
    exit 1
  fi
  if ! grep -Fq "$assertion" "$output"; then
    echo "DB contract failed without the expected assertion: $assertion" >&2
    exit 1
  fi
  echo "PASS: rejected $assertion"
}

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
DROP FUNCTION public.fixture_lookup(uuid);
CREATE FUNCTION public.fixture_lookup(user_identifier uuid)
RETURNS text LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT $1::text $$;
REVOKE ALL ON FUNCTION public.fixture_lookup(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_lookup(uuid) TO authenticated;
SQL
expect_failure 'function public.fixture_lookup(uuid) argument names'

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
DROP FUNCTION public.fixture_lookup(uuid);
CREATE FUNCTION public.fixture_lookup(p_user_id uuid)
RETURNS SETOF text LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT $1::text $$;
REVOKE ALL ON FUNCTION public.fixture_lookup(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_lookup(uuid) TO authenticated;
SQL
expect_failure 'function public.fixture_lookup(uuid) set-returning mode'

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
DROP FUNCTION public.fixture_lookup(uuid);
CREATE FUNCTION public.fixture_lookup(p_user_id uuid)
RETURNS text LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT $1::text $$;
REVOKE ALL ON FUNCTION public.fixture_lookup(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_lookup(uuid) TO authenticated;
DROP FUNCTION public.fixture_mode(uuid);
CREATE FUNCTION public.fixture_mode(INOUT p_user_id uuid)
LANGUAGE sql SECURITY INVOKER AS $$ SELECT $1 $$;
REVOKE ALL ON FUNCTION public.fixture_mode(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_mode(uuid) TO authenticated;
SQL
expect_failure 'function public.fixture_mode(uuid) argument modes'

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
DROP FUNCTION public.fixture_mode(uuid);
CREATE FUNCTION public.fixture_mode(IN p_user_id uuid)
RETURNS uuid LANGUAGE sql SECURITY INVOKER AS $$ SELECT $1 $$;
REVOKE ALL ON FUNCTION public.fixture_mode(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_mode(uuid) TO authenticated;
DROP FUNCTION public.fixture_rows();
CREATE FUNCTION public.fixture_rows()
RETURNS TABLE(row_key uuid) LANGUAGE sql SECURITY INVOKER AS $$ SELECT NULL::uuid $$;
REVOKE ALL ON FUNCTION public.fixture_rows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_rows() TO authenticated;
SQL
expect_failure 'function public.fixture_rows() argument names'

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
DROP FUNCTION public.fixture_rows();
CREATE FUNCTION public.fixture_rows()
RETURNS TABLE(row_id uuid) LANGUAGE sql SECURITY INVOKER AS $$ SELECT NULL::uuid $$;
REVOKE ALL ON FUNCTION public.fixture_rows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_rows() TO authenticated;
DROP FUNCTION public.fixture_procedure_probe();
CREATE PROCEDURE public.fixture_procedure_probe()
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$ BEGIN NULL; END $$;
REVOKE ALL ON PROCEDURE public.fixture_procedure_probe() FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE public.fixture_procedure_probe() TO authenticated;
SQL
expect_failure 'function public.fixture_procedure_probe() ordinary function'

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
DROP PROCEDURE public.fixture_procedure_probe();
CREATE FUNCTION public.fixture_procedure_probe()
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$ BEGIN RETURN; END $$;
REVOKE ALL ON FUNCTION public.fixture_procedure_probe() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_procedure_probe() TO authenticated;
ALTER TABLE public.fixture_items DROP CONSTRAINT fixture_items_user_id_fkey;
ALTER TABLE public.fixture_items ADD CONSTRAINT fixture_items_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE NOT VALID;
SQL
expect_failure 'constraint public.fixture_items foreign_key(user_id)'

python3 - "$not_valid_contract" <<'PY'
import json
import sys
from pathlib import Path

source = Path("scripts/fixtures/db-contract-v1.example.json")
contract = json.loads(source.read_text(encoding="utf-8"))
for item in contract["capabilities"]["tables"][0]["constraints"]:
    if item["kind"] == "foreign_key":
        item["validated"] = False
for item in contract["capabilities"]["auth"]["foreign_keys"]:
    item["validated"] = False
Path(sys.argv[1]).write_text(json.dumps(contract), encoding="utf-8")
PY
python3 scripts/check-db-contract.py "$not_valid_contract"
echo "PASS: explicitly declared NOT VALID foreign key"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'ALTER TABLE public.fixture_items VALIDATE CONSTRAINT fixture_items_user_id_fkey' >/dev/null
expect_failure 'constraint public.fixture_items foreign_key(user_id)' "$not_valid_contract"
python3 scripts/check-db-contract.py scripts/fixtures/db-contract-v1.example.json

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
DROP TABLE public.relation_probe;
CREATE VIEW public.relation_probe AS SELECT NULL::uuid AS id;
SQL
expect_failure 'relation public.relation_probe kind=table'

rm -f -- "$output" "$not_valid_contract"
echo "PASS: PostgreSQL catalog compatibility regression tests"

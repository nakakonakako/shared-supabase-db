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
output="$(mktemp "${TMPDIR:-/tmp}/db-contract-mismatch.XXXXXX")"
not_valid_contract="$(mktemp "${TMPDIR:-/tmp}/db-contract-not-valid.XXXXXX")"
advanced_contract="$(mktemp "${TMPDIR:-/tmp}/db-contract-advanced.XXXXXX")"
public_acl_contract="$(mktemp "${TMPDIR:-/tmp}/db-contract-public-acl.XXXXXX")"
function_acl_contract="$(mktemp "${TMPDIR:-/tmp}/db-contract-function-acl.XXXXXX")"
contracts_dir="$(mktemp -d "${TMPDIR:-/tmp}/db-contract-pinned-fixtures.XXXXXX")"
trap 'rm -rf -- "$contracts_dir"; rm -f -- "$output" "$not_valid_contract" "$advanced_contract" "$public_acl_contract" "$function_acl_contract"' EXIT INT TERM

fresh="$(psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -Atqc "
  SELECT pg_catalog.to_regnamespace('auth') IS NULL
    AND pg_catalog.to_regnamespace('realtime') IS NULL
    AND pg_catalog.to_regnamespace('ai_quota') IS NULL
    AND pg_catalog.to_regclass('public.fixture_items') IS NULL
    AND pg_catalog.to_regclass('public.acl_probe_table') IS NULL
    AND pg_catalog.to_regprocedure('public.acl_probe_function()') IS NULL
    AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname IN ('anon','authenticated','migration_preflight_reader','contract_reader_login'))
")"
if [[ "$fresh" != "t" ]]; then
  echo "Refusing DB contract SQL test: database/cluster is not fresh and disposable." >&2
  exit 1
fi

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE migration_preflight_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE contract_reader_login LOGIN PASSWORD 'disposable-contract-reader-password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT;
GRANT migration_preflight_reader TO contract_reader_login WITH INHERIT TRUE, SET FALSE;
ALTER ROLE contract_reader_login SET default_transaction_read_only = on;
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT NULL::uuid $$;
CREATE SCHEMA realtime;
CREATE TABLE realtime.messages (id bigint);
ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;
CREATE FUNCTION realtime.topic() RETURNS text LANGUAGE sql STABLE AS $$ SELECT NULL::text $$;
CREATE SCHEMA ai_quota;
CREATE TABLE ai_quota.settings (id smallint PRIMARY KEY, configuration_value text NOT NULL);
GRANT USAGE ON SCHEMA ai_quota TO migration_preflight_reader;
GRANT SELECT (id) ON TABLE ai_quota.settings TO migration_preflight_reader;
CREATE TABLE public.fixture_items (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  label text NOT NULL,
  optional_note text,
  UNIQUE (user_id, label)
);
CREATE TABLE public.relation_probe (id uuid);
CREATE TABLE public.acl_probe_table (id integer NOT NULL);
ALTER TABLE public.fixture_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY fixture_items_owner_all ON public.fixture_items
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Mixed Case Owner's Policy" ON public.fixture_items
  FOR SELECT TO authenticated USING (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.fixture_items TO authenticated;
CREATE TABLE public.fixture_fk_target (
  user_id uuid NOT NULL,
  id uuid NOT NULL,
  PRIMARY KEY (user_id, id)
);
CREATE TABLE public.fixture_fk_source (
  user_id uuid NOT NULL,
  receipt_item_id uuid,
  CONSTRAINT fixture_fk_source_owner_fk FOREIGN KEY (user_id, receipt_item_id)
    REFERENCES public.fixture_fk_target(user_id, id) ON DELETE SET NULL (receipt_item_id)
);
CREATE FUNCTION public.fixture_lookup(p_user_id uuid)
RETURNS text LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$ SELECT $1::text $$;
REVOKE ALL ON FUNCTION public.fixture_lookup(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_lookup(uuid) TO authenticated;
CREATE FUNCTION public.acl_probe_function()
RETURNS integer LANGUAGE sql SECURITY INVOKER AS $$ SELECT 1 $$;
GRANT EXECUTE ON FUNCTION public.acl_probe_function() TO authenticated;
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

export PGUSER=contract_reader_login PGPASSWORD=disposable-contract-reader-password
[[ "$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c 'SHOW default_transaction_read_only')" == 'on' ]] || {
  echo "Disposable contract Reader is not default read-only." >&2
  exit 1
}
if psql -X -w -v ON_ERROR_STOP=1 -c 'SELECT * FROM public.fixture_items' >"$output" 2>&1; then
  echo "Contract Reader unexpectedly read application rows." >&2
  exit 1
fi
grep -Fq 'permission denied' "$output" || {
  echo "Contract Reader application SELECT failed for an unexpected reason." >&2
  exit 1
}
if psql -X -w -v ON_ERROR_STOP=1 -c "INSERT INTO public.fixture_items (id,user_id,label) VALUES (gen_random_uuid(),gen_random_uuid(),'blocked')" >"$output" 2>&1; then
  echo "Contract Reader unexpectedly wrote application rows." >&2
  exit 1
fi
grep -Eiq 'permission denied|read-only transaction' "$output" || {
  echo "Contract Reader application INSERT was not rejected by privileges or read-only mode." >&2
  exit 1
}
[[ "$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c "SELECT pg_catalog.has_table_privilege(current_user, 'public.fixture_items', 'SELECT') OR pg_catalog.has_table_privilege(current_user, 'public.fixture_items', 'INSERT')")" == 'f' ]] || {
  echo "Contract Reader has application-table SELECT or INSERT privilege." >&2
  exit 1
}
python3 scripts/check-db-contract.py scripts/fixtures/db-contract-v1.example.json
python3 - <<'PY'
import copy
from pathlib import Path

from scripts.db_contract import _literal, build_checks, load_contract, verify_catalog

contract = load_contract(Path("scripts/fixtures/db-contract-v1.example.json"))
template = contract["capabilities"]["tables"][0]
contract["capabilities"]["tables"] = [
    {**copy.deepcopy(template), "name": f"large_contract_table_{index:04d}"}
    for index in range(12)
]
checks = build_checks(contract)
rows = ",\n".join(
    f"({index}, {_literal(label)}, ({predicate}))"
    for index, (label, predicate) in enumerate(checks)
)
sql = (
    "BEGIN TRANSACTION READ ONLY; SET LOCAL statement_timeout='30s'; "
    "SELECT CASE WHEN passed THEN 't' ELSE 'f' END FROM (VALUES\n"
    f"{rows}\n) AS contract_checks(ord, label, passed) ORDER BY ord; COMMIT;"
)
sql_bytes = len(sql.encode("utf-8"))
if sql_bytes <= 131_072:
    raise SystemExit(f"Large contract query fixture is too small: {sql_bytes} bytes")
results = verify_catalog(contract)
if len(results) != len(checks) or not any(not result.passed for result in results):
    raise SystemExit("Large contract query did not return the expected catalog results")
print(f"PASS: {len(checks)} catalog assertions ({sql_bytes} SQL bytes) execute as a minimum Reader")
PY
python3 - "$contracts_dir" <<'PY'
import json
import sys
from pathlib import Path

source = json.loads(Path("scripts/fixtures/db-contract-v1.example.json").read_text(encoding="utf-8"))
for app_id in ("price-memo", "receipt-manager"):
    contract = {**source, "app_id": app_id}
    Path(sys.argv[1], f"{app_id}.json").write_text(json.dumps(contract), encoding="utf-8")
PY
python3 scripts/verify-consumer-db-contracts.py --contracts-dir "$contracts_dir" >"$output" 2>&1 || {
  cat "$output" >&2
  echo "Two-contract aggregation failed for matching disposable fixtures." >&2
  exit 1
}
grep -Fq 'price-memo: STATIC PASS' "$output"
grep -Fq 'receipt-manager: STATIC PASS' "$output"
grep -Fq 'aggregate: STATIC PASS (2 contracts)' "$output"
echo "PASS: two pinned contract results aggregate to STATIC PASS"
python3 - "$contracts_dir/receipt-manager.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["tables"][0]["columns"][0]["type"] = "text"
path.write_text(json.dumps(contract), encoding="utf-8")
PY
if python3 scripts/verify-consumer-db-contracts.py --contracts-dir "$contracts_dir" >"$output" 2>&1; then
  echo "Two-contract aggregation incorrectly accepted a mismatching contract." >&2
  exit 1
fi
grep -Fq 'receipt-manager: CONTRACT MISMATCH' "$output"
grep -Fq 'price-memo: STATIC PASS' "$output"
grep -Fq 'aggregate: FAIL' "$output"
echo "PASS: one contract mismatch fails the aggregate while preserving per-contract results"
python3 - "$contracts_dir/receipt-manager.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["tables"][0]["name"] = "missing_fixture_items"
path.write_text(json.dumps(contract), encoding="utf-8")
PY
if python3 scripts/verify-consumer-db-contracts.py --contracts-dir "$contracts_dir" >"$output" 2>&1; then
  echo "Two-contract aggregation incorrectly accepted a missing relation." >&2
  exit 1
fi
grep -Fq 'receipt-manager: CONTRACT MISMATCH' "$output"
if grep -Fq 'EXECUTION ERROR' "$output"; then
  echo "Missing relation was misclassified as an execution error." >&2
  exit 1
fi
echo "PASS: missing relations are classified as contract mismatches"
if PGPORT=1 PGCONNECT_TIMEOUT=1 python3 scripts/verify-consumer-db-contracts.py --contracts-dir "$contracts_dir" >"$output" 2>&1; then
  echo "Two-contract aggregation incorrectly accepted a connection failure." >&2
  exit 1
fi
grep -Fq 'EXECUTION ERROR' "$output"
grep -Fq 'aggregate: FAIL' "$output"
if grep -Eqi 'password|postgresql://|postgres://' "$output"; then
  echo "Contract verification output leaked connection data." >&2
  exit 1
fi
echo "PASS: connection failure is fail-closed and sanitized"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
ALTER TABLE public.fixture_items ADD COLUMN future_optional text;
CREATE TABLE public.unrelated_additive_table (id uuid PRIMARY KEY);
SQL
python3 scripts/check-db-contract.py scripts/fixtures/db-contract-v1.example.json
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

python3 - "$public_acl_contract" <<'PY'
import json
import sys
from pathlib import Path

contract = {
    "format_version": 1,
    "app_id": "public-acl-probe",
    "contract_version": "1.0.0",
    "capabilities": {
        "tables": [{
            "schema": "public", "name": "acl_probe_table",
            "columns": [{"name": "id", "type": "integer", "nullable": False}],
            "privileges": [{"role": "public", "allow": [], "deny": ["SELECT"]}],
        }],
        "functions": [],
    },
}
Path(sys.argv[1]).write_text(json.dumps(contract), encoding="utf-8")
PY
python3 scripts/check-db-contract.py "$public_acl_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'GRANT SELECT ON public.acl_probe_table TO PUBLIC' >/dev/null
expect_failure 'table public.acl_probe_table public SELECT denied' "$public_acl_contract"
python3 - "$public_acl_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
privilege = contract["capabilities"]["tables"][0]["privileges"][0]
privilege["allow"], privilege["deny"] = ["SELECT"], []
path.write_text(json.dumps(contract), encoding="utf-8")
PY
python3 scripts/check-db-contract.py "$public_acl_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'REVOKE SELECT ON public.acl_probe_table FROM PUBLIC' >/dev/null
expect_failure 'table public.acl_probe_table public SELECT allowed' "$public_acl_contract"
python3 - "$public_acl_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
privilege = contract["capabilities"]["tables"][0]["privileges"][0]
privilege["allow"], privilege["deny"] = [], ["SELECT"]
path.write_text(json.dumps(contract), encoding="utf-8")
PY
python3 scripts/check-db-contract.py "$public_acl_contract"
python3 - "$public_acl_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["tables"][0]["privileges"][0] = {
    "role": "contract_missing_role", "allow": [], "deny": ["SELECT"]
}
path.write_text(json.dumps(contract), encoding="utf-8")
PY
expect_failure 'table public.acl_probe_table contract_missing_role SELECT denied' "$public_acl_contract"
echo "PASS: table ACL checks handle PUBLIC and missing roles"

python3 - "$function_acl_contract" <<'PY'
import json
import sys
from pathlib import Path

contract = {
    "format_version": 1,
    "app_id": "function-acl-probe",
    "contract_version": "1.0.0",
    "capabilities": {
        "tables": [],
        "functions": [{
            "signature": "public.acl_probe_function()", "returns": "integer",
            "security": "invoker",
            "execute": {"allow": ["authenticated"], "deny": ["public"]},
        }],
    },
}
Path(sys.argv[1]).write_text(json.dumps(contract), encoding="utf-8")
PY
expect_failure 'function public.acl_probe_function() EXECUTE denied for public' "$function_acl_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'REVOKE EXECUTE ON FUNCTION public.acl_probe_function() FROM PUBLIC' >/dev/null
python3 scripts/check-db-contract.py "$function_acl_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'GRANT EXECUTE ON FUNCTION public.acl_probe_function() TO PUBLIC' >/dev/null
expect_failure 'function public.acl_probe_function() EXECUTE denied for public' "$function_acl_contract"
python3 - "$function_acl_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["functions"][0]["execute"] = {"allow": ["authenticated", "public"], "deny": []}
path.write_text(json.dumps(contract), encoding="utf-8")
PY
python3 scripts/check-db-contract.py "$function_acl_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'REVOKE EXECUTE ON FUNCTION public.acl_probe_function() FROM PUBLIC' >/dev/null
expect_failure 'function public.acl_probe_function() EXECUTE for public' "$function_acl_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'GRANT EXECUTE ON FUNCTION public.acl_probe_function() TO PUBLIC' >/dev/null
python3 - "$function_acl_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["functions"][0]["execute"]["deny"] = ["contract_missing_role"]
path.write_text(json.dumps(contract), encoding="utf-8")
PY
expect_failure 'function public.acl_probe_function() EXECUTE denied for contract_missing_role' "$function_acl_contract"
python3 - "$function_acl_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["functions"][0]["execute"] = {"allow": ["authenticated"], "deny": []}
path.write_text(json.dumps(contract), encoding="utf-8")
PY
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'REVOKE EXECUTE ON FUNCTION public.acl_probe_function() FROM PUBLIC' >/dev/null
python3 scripts/check-db-contract.py "$function_acl_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'REVOKE EXECUTE ON FUNCTION public.acl_probe_function() FROM authenticated' >/dev/null
if python3 scripts/check-db-contract.py "$function_acl_contract" >"$output" 2>&1; then
  echo "Missing authenticated EXECUTE privilege was accepted." >&2
  exit 1
fi
grep -Fq 'function public.acl_probe_function() EXECUTE for authenticated' "$output"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'GRANT EXECUTE ON FUNCTION public.acl_probe_function() TO authenticated' >/dev/null
python3 scripts/check-db-contract.py "$function_acl_contract"
echo "PASS: function EXECUTE ACL checks handle PUBLIC, real roles, and missing roles"

python3 - "$advanced_contract" <<'PY'
import json
import sys
from pathlib import Path

contract = json.loads(Path("scripts/fixtures/db-contract-v1.example.json").read_text(encoding="utf-8"))
items = contract["capabilities"]["tables"][0]
items["rls"]["policies"].append({"name": "Mixed Case Owner's Policy", "command": "SELECT", "roles": ["authenticated"]})
items["privileges"][0]["deny"].append("MAINTAIN")
contract["capabilities"]["tables"].extend([
    {
        "schema": "public", "name": "fixture_fk_target",
        "columns": [
            {"name": "user_id", "type": "uuid", "nullable": False},
            {"name": "id", "type": "uuid", "nullable": False},
        ],
        "constraints": [{"kind": "primary_key", "columns": ["user_id", "id"]}],
    },
    {
        "schema": "public", "name": "fixture_fk_source",
        "columns": [
            {"name": "user_id", "type": "uuid", "nullable": False},
            {"name": "receipt_item_id", "type": "uuid", "nullable": True},
        ],
        "constraints": [{
            "kind": "foreign_key", "columns": ["user_id", "receipt_item_id"],
            "references": {"table": "public.fixture_fk_target", "columns": ["user_id", "id"]},
            "on_delete": "set_null", "set_null_columns": ["receipt_item_id"],
        }],
    },
])
Path(sys.argv[1]).write_text(json.dumps(contract), encoding="utf-8")
PY
python3 scripts/check-db-contract.py "$advanced_contract"

python3 - "$advanced_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["tables"][0]["rls"]["policies"][-1]["roles"] = ["anon"]
path.write_text(json.dumps(contract), encoding="utf-8")
PY
expect_failure 'policy public.fixture_items metadata #2' "$advanced_contract"
python3 - "$advanced_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["tables"][0]["rls"]["policies"][-1].update(roles=["authenticated"], command="UPDATE")
path.write_text(json.dumps(contract), encoding="utf-8")
PY
expect_failure 'policy public.fixture_items metadata #2' "$advanced_contract"
python3 - "$advanced_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["tables"][0]["rls"]["policies"][-1].update(name="mixed case owner's policy", command="SELECT")
path.write_text(json.dumps(contract), encoding="utf-8")
PY
expect_failure 'policy public.fixture_items metadata #2' "$advanced_contract"
python3 - "$advanced_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["tables"][0]["rls"]["policies"][-1].update(name="Mixed Case Owner's Policy", command="SELECT")
path.write_text(json.dumps(contract), encoding="utf-8")
PY

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -c 'GRANT MAINTAIN ON TABLE public.fixture_items TO authenticated'
expect_failure 'table public.fixture_items authenticated MAINTAIN denied' "$advanced_contract"
python3 - "$advanced_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
entry = contract["capabilities"]["tables"][0]["privileges"][0]
entry["deny"].remove("MAINTAIN")
entry["allow"].append("MAINTAIN")
path.write_text(json.dumps(contract), encoding="utf-8")
PY
python3 scripts/check-db-contract.py "$advanced_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -c 'REVOKE MAINTAIN ON TABLE public.fixture_items FROM authenticated'
expect_failure 'table public.fixture_items authenticated MAINTAIN allowed' "$advanced_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -c 'GRANT MAINTAIN ON TABLE public.fixture_items TO authenticated'
python3 scripts/check-db-contract.py "$advanced_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -c 'REVOKE MAINTAIN ON TABLE public.fixture_items FROM authenticated'
python3 - "$advanced_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
entry = contract["capabilities"]["tables"][0]["privileges"][0]
entry["allow"].remove("MAINTAIN")
entry["deny"].append("MAINTAIN")
path.write_text(json.dumps(contract), encoding="utf-8")
PY
python3 scripts/check-db-contract.py "$advanced_contract"

python3 - "$advanced_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
constraint = contract["capabilities"]["tables"][-1]["constraints"][0]
constraint["set_null_columns"] = ["user_id", "receipt_item_id"]
path.write_text(json.dumps(contract), encoding="utf-8")
PY
expect_failure 'constraint public.fixture_fk_source foreign_key(user_id,receipt_item_id)' "$advanced_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
ALTER TABLE public.fixture_fk_source DROP CONSTRAINT fixture_fk_source_owner_fk;
ALTER TABLE public.fixture_fk_source ADD CONSTRAINT fixture_fk_source_owner_fk
  FOREIGN KEY (user_id, receipt_item_id) REFERENCES public.fixture_fk_target(user_id, id)
  ON DELETE SET NULL (user_id);
SQL
python3 - "$advanced_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
constraint = contract["capabilities"]["tables"][-1]["constraints"][0]
constraint["set_null_columns"] = ["receipt_item_id"]
path.write_text(json.dumps(contract), encoding="utf-8")
PY
expect_failure 'constraint public.fixture_fk_source foreign_key(user_id,receipt_item_id)' "$advanced_contract"
psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
ALTER TABLE public.fixture_fk_source DROP CONSTRAINT fixture_fk_source_owner_fk;
ALTER TABLE public.fixture_fk_source ADD CONSTRAINT fixture_fk_source_owner_fk
  FOREIGN KEY (user_id, receipt_item_id) REFERENCES public.fixture_fk_target(user_id, id)
  ON DELETE SET NULL;
SQL
python3 - "$advanced_contract" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
contract = json.loads(path.read_text(encoding="utf-8"))
contract["capabilities"]["tables"][-1]["constraints"][0]["set_null_columns"] = ["user_id", "receipt_item_id"]
path.write_text(json.dumps(contract), encoding="utf-8")
PY
python3 scripts/check-db-contract.py "$advanced_contract"

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

psql "$DB_CONTRACT_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c 'REVOKE SELECT ON pg_catalog.pg_class FROM PUBLIC' >/dev/null
set +e
python3 scripts/verify-consumer-db-contracts.py --contracts-dir "$contracts_dir" >"$output" 2>&1
catalog_permission_status=$?
set -e
if [[ "$catalog_permission_status" -ne 2 ]] || ! grep -Fq 'EXECUTION ERROR' "$output"; then
  echo "Insufficient catalog access was not reported as an execution error." >&2
  cat "$output" >&2
  exit 1
fi
if grep -Eqi 'password|postgresql://|postgres://' "$output"; then
  echo "Catalog permission failure leaked connection data." >&2
  exit 1
fi
echo "PASS: insufficient catalog access is an execution error and remains sanitized"

rm -f -- "$output" "$not_valid_contract"
echo "PASS: PostgreSQL catalog compatibility regression tests"

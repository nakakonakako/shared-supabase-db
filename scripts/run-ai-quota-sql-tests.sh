#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# This runner never starts/resets a developer Supabase project. Use a fresh,
# dedicated disposable PostgreSQL cluster: CREATE ROLE is cluster-wide, so a
# fresh database in a cluster where ai_quota roles exist is not sufficient.
# shellcheck source=scripts/lib/ai-quota-test-db-url.sh
source "${ROOT}/scripts/lib/ai-quota-test-db-url.sh"

if ! psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc \
  "SELECT pg_catalog.to_regnamespace('ai_quota') IS NULL" | grep -qx t; then
  echo "Refusing to run: ai_quota_test must be fresh and have no ai_quota schema." >&2
  exit 1
fi

if ! psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc \
  "SELECT pg_catalog.count(*) = 0 FROM pg_catalog.pg_roles WHERE rolname IN ('ai_quota_owner', 'ai_quota_backend')" \
  | grep -qx t; then
  echo "Refusing to run: ai_quota roles already exist cluster-wide or role check failed. Use a fresh disposable PostgreSQL cluster." >&2
  exit 1
fi

echo "Preparing Supabase API roles in the disposable database..."
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/ai_quota/setup.sql

echo "Running read-only migration privilege preflight as the migration role..."
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/diagnostics/preflight_ai_quota_migration_privileges.sql

echo "Running read-only migration privilege preflight as a role without CREATEROLE..."
# Disposable cluster only. Membership lets the test session SET ROLE.
# The unprivileged role stays NOCREATEROLE and receives no extra privileges.
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
DO $role$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ai_quota_preflight_nobody'
  ) THEN
    CREATE ROLE ai_quota_preflight_nobody NOLOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOINHERIT;
  END IF;
END
$role$;
ALTER ROLE ai_quota_preflight_nobody NOLOGIN NOCREATEROLE NOCREATEDB NOINHERIT;
GRANT ai_quota_preflight_nobody TO CURRENT_USER;
DO $check$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = 'ai_quota_preflight_nobody'
      AND (rolsuper OR rolcreaterole OR rolcreatedb)
  ) THEN
    RAISE EXCEPTION 'ai_quota_preflight_nobody must remain nosuperuser, nocreaterole, and nocreatedb';
  END IF;
END
$check$;
SQL
nobody_output=""
test_owner_granted=0
cleanup_nobody_output() {
  if [[ -n "${nobody_output}" ]]; then
    rm -f -- "${nobody_output}"
  fi
}
cleanup_test_owner() {
  if [[ "${test_owner_granted}" == "1" ]]; then
    psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
      -f supabase/tests/ai_quota/revoke_disposable_owner_access.sql \
      || true
    test_owner_granted=0
  fi
}
revoke_test_owner() {
  if [[ "${test_owner_granted}" == "1" ]]; then
    psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
      -f supabase/tests/ai_quota/revoke_disposable_owner_access.sql
    test_owner_granted=0
  fi
}
trap 'cleanup_test_owner; cleanup_nobody_output' EXIT
nobody_output="$(umask 077 && mktemp "${TMPDIR:-/tmp}/ai-quota-preflight.XXXXXX")"
set +e
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -c "SET ROLE ai_quota_preflight_nobody" \
  -f supabase/diagnostics/preflight_ai_quota_migration_privileges.sql \
  >"$nobody_output" 2>&1
nobody_status=$?
set -e
if [[ "$nobody_status" -eq 0 ]] || ! grep -q "preflight insufficient" "$nobody_output"; then
  echo "Expected the unprivileged preflight to stop deploy/migration (psql status ${nobody_status})." >&2
  if [[ -f "$nobody_output" ]]; then
    grep -E 'preflight insufficient|ERROR:|WARNING:|NOTICE:|permission denied' "$nobody_output" \
      | sed -E \
          -e 's#(postgres(ql)?://)[^[:space:]]+#\1[redacted]#g' \
          -e 's#([Pp]assword|[Pp]asswd)[=:][^[:space:]]+#\1=[redacted]#g' \
      >&2 || true
  fi
  exit 1
fi
cleanup_nobody_output
nobody_output=""

echo "Applying the AI quota migration to the disposable database..."
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261014120000_s1_06_ai_quota_foundation.sql
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -c \
  "INSERT INTO supabase_migrations.schema_migrations (version) VALUES ('20261014120000') ON CONFLICT (version) DO NOTHING"

echo "Running read-only integrity diagnostic..."
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/diagnostics/verify_s1_06_ai_quota_integrity.sql

# The migration revokes executor membership. Fixture DML and RPC calls in
# this disposable database need owner rights again. Production does not run
# this grant. The integrity check above must stay before it.
can_update="$(psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc \
  "SELECT pg_catalog.has_table_privilege(current_user, 'ai_quota.requests', 'UPDATE')")"
can_execute="$(psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc \
  "SELECT pg_catalog.has_function_privilege(current_user, 'ai_quota.claim_ai_request(uuid,uuid,text)', 'EXECUTE')")"
if [[ "$can_update" != "t" || "$can_execute" != "t" ]]; then
  echo "Restoring ai_quota_owner membership for disposable tests only..."
  psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
    -f supabase/tests/ai_quota/enable_disposable_owner_access.sql
  test_owner_granted=1
fi

echo "Running ai_quota SQL tests..."
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/tests/ai_quota/test_ai_quota.sql

echo "Running concurrent claim probe..."
bash supabase/tests/ai_quota/test_concurrent_claim.sh

revoke_test_owner

echo "All ai_quota SQL tests passed."

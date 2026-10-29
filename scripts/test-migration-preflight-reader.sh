#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
image="postgres:17-alpine"
container="receipt-migration-reader-test-$$-${RANDOM}"
test_password='disposable-only-test-password'
test_root="$(mktemp -d "${TMPDIR:-/tmp}/migration-reader-test.XXXXXX")"
container_started=0

cleanup() {
  if [[ "$container_started" -eq 1 ]]; then
    docker stop "$container" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT INT TERM

docker info >/dev/null 2>&1 || {
  echo "Docker daemon is required for the isolated migration reader test." >&2
  exit 1
}
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null

docker run --detach --rm --name "$container" \
  --publish 127.0.0.1::5432 \
  --env POSTGRES_PASSWORD=disposable-postgres-password \
  --env POSTGRES_DB=postgres \
  "$image" >/dev/null
container_started=1
bound_port="$(docker port "$container" 5432/tcp | sed 's/.*://')"
export PGHOST=127.0.0.1 PGPORT="$bound_port" PGDATABASE=postgres
export PGUSER=postgres PGPASSWORD=disposable-postgres-password PGSSLMODE=disable

ready=0
for _ in $(seq 1 40); do
  if pg_isready -q; then
    ready=1
    break
  fi
  sleep 0.25
done
[[ "$ready" -eq 1 ]] || {
  echo "Disposable PostgreSQL did not become ready." >&2
  exit 1
}

psql -X -w -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE ROLE supabase_admin NOLOGIN SUPERUSER;
CREATE ROLE ai_quota_owner NOLOGIN NOINHERIT;
CREATE ROLE migration_executor LOGIN CREATEROLE NOINHERIT PASSWORD 'disposable-migration-executor-password';
GRANT ai_quota_owner TO supabase_admin WITH ADMIN TRUE, SET FALSE, INHERIT FALSE;
GRANT ai_quota_owner TO migration_executor WITH ADMIN TRUE, SET FALSE, INHERIT FALSE GRANTED BY supabase_admin;
GRANT CREATE ON DATABASE postgres TO ai_quota_owner;
ALTER DATABASE postgres OWNER TO migration_executor;
CREATE SCHEMA supabase_migrations AUTHORIZATION migration_executor;
CREATE TABLE supabase_migrations.schema_migrations (
  version text PRIMARY KEY,
  statements text[]
);
INSERT INTO supabase_migrations.schema_migrations (version, statements)
VALUES ('20261027150000', ARRAY['fixture migration']);
ALTER TABLE supabase_migrations.schema_migrations OWNER TO migration_executor;
CREATE TABLE public.business_rows (id integer PRIMARY KEY, secret text NOT NULL);
INSERT INTO public.business_rows VALUES (1, 'fixture-only-business-data');
SET ROLE ai_quota_owner;
CREATE SCHEMA ai_quota;
CREATE TABLE ai_quota.settings (
  id smallint PRIMARY KEY,
  emergency_stop boolean NOT NULL,
  configuration_value text NOT NULL
);
INSERT INTO ai_quota.settings VALUES (1, false, 'fixture-only-secret-setting');
CREATE TABLE ai_quota.requests (request_id integer PRIMARY KEY, payload text);
RESET ROLE;
REVOKE CREATE ON DATABASE postgres FROM ai_quota_owner;
CREATE FUNCTION public.migration_reader_secdef_probe()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
  INSERT INTO public.business_rows VALUES (2, 'must-not-be-written');
END
$function$;
REVOKE ALL ON FUNCTION public.migration_reader_secdef_probe() FROM PUBLIC;
SQL

export PGUSER=migration_executor PGPASSWORD=disposable-migration-executor-password
[[ "$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  "SELECT concat_ws(':', rolsuper::text, rolcreaterole::text) FROM pg_catalog.pg_roles WHERE rolname = current_user")" == 'false:true' ]] || {
  echo "Migration executor is not a non-superuser CREATEROLE role." >&2
  exit 1
}
membership_before="$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  "SELECT count(*)::text || ':' || coalesce(bool_and(m.admin_option AND NOT m.set_option AND NOT m.inherit_option)::text, 'false') FROM pg_catalog.pg_auth_members AS m JOIN pg_catalog.pg_roles AS granted ON granted.oid = m.roleid JOIN pg_catalog.pg_roles AS member ON member.oid = m.member WHERE granted.rolname = 'ai_quota_owner' AND member.rolname = current_user")"
[[ "$membership_before" == '1:true' ]] || {
  echo "Non-superuser fixture did not start with the expected ADMIN-only membership: $membership_before" >&2
  exit 1
}
bootstrap_grantor="$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  "SELECT pg_catalog.pg_get_userbyid(m.grantor) FROM pg_catalog.pg_auth_members AS m JOIN pg_catalog.pg_roles AS granted ON granted.oid = m.roleid JOIN pg_catalog.pg_roles AS member ON member.oid = m.member WHERE granted.rolname = 'ai_quota_owner' AND member.rolname = current_user")"
[[ "$bootstrap_grantor" == 'supabase_admin' ]] || {
  echo "ADMIN-only membership was not granted by the simulated Supabase bootstrap role: $bootstrap_grantor" >&2
  exit 1
}
export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  "ALTER TABLE ai_quota.settings OWNER TO postgres" >/dev/null
export PGUSER=migration_executor PGPASSWORD=disposable-migration-executor-password
if psql -X -w -v ON_ERROR_STOP=1 -f \
  "$repo_root/supabase/migrations/20261027150000_migration_preflight_reader.sql" >/dev/null 2>&1; then
  echo "Migration unexpectedly succeeded after its required column grant was denied." >&2
  exit 1
fi
membership_after_failure="$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  "SELECT count(*)::text || ':' || coalesce(bool_and(m.admin_option AND NOT m.set_option AND NOT m.inherit_option)::text, 'false') FROM pg_catalog.pg_auth_members AS m JOIN pg_catalog.pg_roles AS granted ON granted.oid = m.roleid JOIN pg_catalog.pg_roles AS member ON member.oid = m.member WHERE granted.rolname = 'ai_quota_owner' AND member.rolname = current_user")"
[[ "$membership_after_failure" == '1:true' ]] || {
  echo "Failed migration changed the executor's existing membership." >&2
  exit 1
}
[[ "$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  "SELECT pg_catalog.pg_get_userbyid(m.grantor) FROM pg_catalog.pg_auth_members AS m JOIN pg_catalog.pg_roles AS granted ON granted.oid = m.roleid JOIN pg_catalog.pg_roles AS member ON member.oid = m.member WHERE granted.rolname = 'ai_quota_owner' AND member.rolname = current_user")" == 'supabase_admin' ]] || {
  echo "Failed migration changed the bootstrap ADMIN grantor." >&2
  exit 1
}
[[ "$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  "SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname = 'migration_preflight_reader'")" == 0 ]] || {
  echo "Failed migration left behind the reader role." >&2
  exit 1
}
export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  "ALTER TABLE ai_quota.settings OWNER TO ai_quota_owner" >/dev/null
export PGUSER=migration_executor PGPASSWORD=disposable-migration-executor-password
psql -X -w -v ON_ERROR_STOP=1 \
  -f "$repo_root/supabase/migrations/20261027150000_migration_preflight_reader.sql"
membership_after="$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  "SELECT count(*)::text || ':' || coalesce(bool_and(m.admin_option AND NOT m.set_option AND NOT m.inherit_option)::text, 'false') FROM pg_catalog.pg_auth_members AS m JOIN pg_catalog.pg_roles AS granted ON granted.oid = m.roleid JOIN pg_catalog.pg_roles AS member ON member.oid = m.member WHERE granted.rolname = 'ai_quota_owner' AND member.rolname = current_user")"
if [[ "$membership_after" != '1:true' ]]; then
  echo "Migration did not preserve the executor's ADMIN-only membership: $membership_after" >&2
  exit 1
fi
[[ "$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  "SELECT pg_catalog.pg_get_userbyid(m.grantor) FROM pg_catalog.pg_auth_members AS m JOIN pg_catalog.pg_roles AS granted ON granted.oid = m.roleid JOIN pg_catalog.pg_roles AS member ON member.oid = m.member WHERE granted.rolname = 'ai_quota_owner' AND member.rolname = current_user")" == 'supabase_admin' ]] || {
  echo "Migration changed the bootstrap ADMIN grantor." >&2
  exit 1
}

export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE migration_preflight_login
  LOGIN PASSWORD '$test_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT;
GRANT migration_preflight_reader TO migration_preflight_login WITH INHERIT TRUE, SET FALSE;
ALTER ROLE migration_preflight_login SET default_transaction_read_only = on;
SQL

export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
psql -X -w -v ON_ERROR_STOP=1 -f \
  "$repo_root/supabase/diagnostics/verify_migration_preflight_reader.sql"
psql -X -w -v ON_ERROR_STOP=1 -f \
  "$repo_root/supabase/diagnostics/verify_dev_db_contract_reader.sql"
[[ "$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  'SELECT version FROM supabase_migrations.schema_migrations')" == '20261027150000' ]]
[[ "$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  'SELECT count(*) FROM ai_quota.settings WHERE id = 1')" == '1' ]]
[[ "$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c 'SHOW default_transaction_read_only')" == 'on' ]]

expect_reader_diagnostic_denied() {
  local label="$1"
  if psql -X -w -v ON_ERROR_STOP=1 \
    -f "$repo_root/supabase/diagnostics/verify_dev_db_contract_reader.sql" \
    >"$test_root/reader-diagnostic.out" 2>&1; then
    echo "Dev Reader diagnostic unexpectedly passed: $label" >&2
    exit 1
  fi
  grep -q 'ERROR:' "$test_root/reader-diagnostic.out" || {
    echo "Dev Reader diagnostic failed unexpectedly: $label" >&2
    cat "$test_root/reader-diagnostic.out" >&2
    exit 1
  }
}

export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  'GRANT migration_preflight_reader TO migration_preflight_login WITH INHERIT TRUE, SET TRUE' >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
expect_reader_diagnostic_denied 'reader membership permits SET ROLE'
export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  'GRANT migration_preflight_reader TO migration_preflight_login WITH INHERIT TRUE, SET FALSE' >/dev/null
psql -X -w -v ON_ERROR_STOP=1 -c \
  'GRANT EXECUTE ON FUNCTION public.migration_reader_secdef_probe() TO migration_preflight_login' >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
expect_reader_diagnostic_denied 'SECURITY DEFINER EXECUTE grant'
export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  'REVOKE EXECUTE ON FUNCTION public.migration_reader_secdef_probe() FROM migration_preflight_login' >/dev/null
psql -X -w -v ON_ERROR_STOP=1 -c \
  'GRANT CREATE ON DATABASE postgres TO migration_preflight_login' >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
expect_reader_diagnostic_denied 'database CREATE grant'
export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  'REVOKE CREATE ON DATABASE postgres FROM migration_preflight_login' >/dev/null
psql -X -w -v ON_ERROR_STOP=1 -c \
  'GRANT SELECT ON public.business_rows TO migration_preflight_login' >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
expect_reader_diagnostic_denied 'business table SELECT grant'
export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  'REVOKE SELECT ON public.business_rows FROM migration_preflight_login' >/dev/null
psql -X -w -v ON_ERROR_STOP=1 -c \
  'GRANT CREATE ON SCHEMA ai_quota TO migration_preflight_login' >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
expect_reader_diagnostic_denied 'unexpected schema CREATE grant'
export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  'REVOKE CREATE ON SCHEMA ai_quota FROM migration_preflight_login' >/dev/null
psql -X -w -v ON_ERROR_STOP=1 -c \
  'GRANT anon TO migration_preflight_login WITH INHERIT TRUE, SET FALSE' >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
expect_reader_diagnostic_denied 'application role membership'
export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c 'REVOKE anon FROM migration_preflight_login' >/dev/null
psql -X -w -v ON_ERROR_STOP=1 -c \
  'ALTER ROLE migration_preflight_login RESET default_transaction_read_only' >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
expect_reader_diagnostic_denied 'default_transaction_read_only is off'
export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  'ALTER ROLE migration_preflight_login SET default_transaction_read_only = on' >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
psql -X -w -v ON_ERROR_STOP=1 -f \
  "$repo_root/supabase/diagnostics/verify_dev_db_contract_reader.sql" >/dev/null
echo "PASS: Dev Reader audit accepts the minimum Reader and rejects excess grants, memberships, and read-write defaults"

export PGUSER=postgres PGPASSWORD=disposable-postgres-password

mkdir -p "$test_root/migrations"
touch "$test_root/migrations/20261027150000_reader.sql"
plan_runner="$repo_root/scripts/run_dev_migration_plan.py"
plan_summary="$test_root/dev-migration-plan-summary.md"
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
python3 "$plan_runner" --migrations-dir "$test_root/migrations" \
  --summary-file "$plan_summary"
grep -Fq 'Migration history: **IN_SYNC**' "$plan_summary"

touch "$test_root/migrations/20261028150000_pending.sql"
if python3 "$repo_root/scripts/check-migration-history.py" \
  --migrations-dir "$test_root/migrations" >"$test_root/pending.out" 2>&1; then
  echo "Pending migration was not rejected." >&2
  exit 1
fi
grep -q 'PENDING: 20261028150000' "$test_root/pending.out"
rm "$plan_summary"
python3 "$plan_runner" --migrations-dir "$test_root/migrations" \
  --summary-file "$plan_summary"
grep -Fq 'Migration history: **PENDING**' "$plan_summary"
grep -Fq -- '- `20261028150000`' "$plan_summary"
grep -Fq 'DB contract compatibility: not checked' "$plan_summary"

export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  "INSERT INTO supabase_migrations.schema_migrations (version) VALUES ('20261028150000')" >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
rm "$plan_summary"
python3 "$plan_runner" --migrations-dir "$test_root/migrations" \
  --summary-file "$plan_summary"
grep -Fq 'Migration history: **IN_SYNC**' "$plan_summary"

export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  "INSERT INTO supabase_migrations.schema_migrations (version) VALUES ('20261029150000')" >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
if python3 "$repo_root/scripts/check-migration-history.py" \
  --migrations-dir "$test_root/migrations" >"$test_root/remote-only.out" 2>&1; then
  echo "Remote-only migration was not rejected." >&2
  exit 1
fi
grep -q 'REMOTE_ONLY: 20261029150000' "$test_root/remote-only.out"
rm "$plan_summary"
if python3 "$plan_runner" --migrations-dir "$test_root/migrations" \
  --summary-file "$plan_summary" >"$test_root/plan-remote-only.out" 2>&1; then
  echo "The Reader-only plan treated REMOTE_ONLY as success." >&2
  exit 1
fi
grep -Fq 'Migration history: **REMOTE_ONLY**' "$plan_summary"

export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  "INSERT INTO supabase_migrations.schema_migrations (version) VALUES ('malformed')" >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
if python3 "$repo_root/scripts/check-migration-history.py" \
  --migrations-dir "$test_root/migrations" >"$test_root/malformed.out" 2>&1; then
  echo "Malformed migration history was not rejected." >&2
  exit 1
fi
grep -q 'malformed version' "$test_root/malformed.out"
rm "$plan_summary"
if python3 "$plan_runner" --migrations-dir "$test_root/migrations" \
  --summary-file "$plan_summary" >"$test_root/plan-error.out" 2>&1; then
  echo "The Reader-only plan treated ERROR as success." >&2
  exit 1
fi
grep -Fq 'Migration history: **ERROR**' "$plan_summary"
echo "PASS: PostgreSQL 17 Reader-only migration plan classifies IN_SYNC, PENDING, REMOTE_ONLY, and ERROR"

expect_denied() {
  local label="$1"
  shift
  if psql -X -w -v ON_ERROR_STOP=1 -c "$*" >/dev/null 2>&1; then
    echo "Reader unexpectedly succeeded: $label" >&2
    exit 1
  fi
}

expect_denied "business data SELECT" 'SELECT * FROM public.business_rows'
expect_denied "business data DML" "INSERT INTO public.business_rows VALUES (3, 'blocked')"
expect_denied "persistent DDL" 'CREATE TABLE public.reader_must_not_create (id integer)'
expect_denied "AI quota setting value SELECT" 'SELECT configuration_value FROM ai_quota.settings'
expect_denied "AI quota request data SELECT" 'SELECT * FROM ai_quota.requests'
expect_denied "SECURITY DEFINER execution" 'SELECT public.migration_reader_secdef_probe()'

export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c 'DELETE FROM ai_quota.settings WHERE id = 1' >/dev/null
export PGUSER=migration_preflight_login PGPASSWORD="$test_password"
missing_singleton="$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  'SELECT count(*) FROM ai_quota.settings WHERE id = 1')"
if [[ "$missing_singleton" != 0 ]]; then
  echo "Reader did not detect the missing AI quota singleton row." >&2
  exit 1
fi
export PGUSER=postgres PGPASSWORD=disposable-postgres-password
psql -X -w -v ON_ERROR_STOP=1 -c \
  "INSERT INTO ai_quota.settings VALUES (1, false, 'fixture-only-secret-setting')" >/dev/null

remaining_rows="$(psql -X -w -A -t -v ON_ERROR_STOP=1 -c \
  'SELECT count(*) FROM public.business_rows')"
if [[ "$remaining_rows" != 1 ]]; then
  echo "A denied reader operation changed the disposable application table." >&2
  exit 1
fi

echo "PASS: disposable migration reader privilege checks"

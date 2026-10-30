#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
: "${MIGRATION_WRITER_TEST_DATABASE_URL:?Set a disposable PostgreSQL 17 MIGRATION_WRITER_TEST_DATABASE_URL}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/migration-writer-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT INT TERM

python3 - <<'PY'
import os
from urllib.parse import urlparse

target = urlparse(os.environ["MIGRATION_WRITER_TEST_DATABASE_URL"])
if target.hostname not in {"localhost", "127.0.0.1", "::1"}:
    raise SystemExit("Refusing migration Writer test: host must be localhost or loopback")
if target.path.lstrip("/") != "migration_writer_test" or target.username != "postgres":
    raise SystemExit("Refusing migration Writer test: use the disposable migration_writer_test database")
PY

mapfile -t pg_config < <(python3 - <<'PY'
import os
from urllib.parse import urlparse

target = urlparse(os.environ["MIGRATION_WRITER_TEST_DATABASE_URL"])
for value in (
    target.hostname or "",
    str(target.port or 5432),
    target.path.lstrip("/"),
    target.username or "",
    target.password or "",
):
    print(value)
PY
)
export PGHOST="${pg_config[0]}" PGPORT="${pg_config[1]}" PGDATABASE="${pg_config[2]}"
export PGUSER="${pg_config[3]}" PGPASSWORD="${pg_config[4]}" PGSSLMODE=disable

database_name="$(psql "$MIGRATION_WRITER_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -Atqc 'SELECT current_database()')"
server_version="$(psql "$MIGRATION_WRITER_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -Atqc 'SHOW server_version_num')"
if [[ "$database_name" != migration_writer_test || "$server_version" -lt 170000 || "$server_version" -ge 180000 ]]; then
  echo "Refusing migration Writer test: expected a fresh PostgreSQL 17 migration_writer_test database." >&2
  exit 1
fi
fresh="$(psql "$MIGRATION_WRITER_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -Atqc \
  "SELECT to_regnamespace('supabase_migrations') IS NULL AND to_regclass('public.writer_probe') IS NULL")"
if [[ "$fresh" != t ]]; then
  echo "Refusing migration Writer test: the database is not fresh." >&2
  exit 1
fi
psql "$MIGRATION_WRITER_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA supabase_migrations;
CREATE TABLE supabase_migrations.schema_migrations (
  version text PRIMARY KEY,
  statements text[] NOT NULL
);
CREATE ROLE db_identity_reader LOGIN PASSWORD 'disposable-identity-reader-password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE db_identity_reader SET default_transaction_read_only = on;
COMMENT ON DATABASE migration_writer_test IS
  'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku';
SQL

identity_checker="$repo_root/scripts/verify-db-project-identity.py"
if DB_TARGET=dev PGUSER=db_identity_reader PGPASSWORD=disposable-identity-reader-password \
  python3 "$identity_checker" >/dev/null; then
  :
else
  echo "The minimum Reader could not verify its database-side identity marker." >&2
  exit 1
fi
if DB_TARGET=production PGUSER=db_identity_reader PGPASSWORD=disposable-identity-reader-password \
  python3 "$identity_checker" >"$test_root/identity-mismatch.out" 2>&1; then
  echo "A Dev marker unexpectedly passed the production identity check." >&2
  exit 1
fi
if ! grep -Fq 'database marker is missing or mismatched' "$test_root/identity-mismatch.out"; then
  echo "An identity mismatch did not fail with a sanitized result." >&2
  exit 1
fi
psql "$MIGRATION_WRITER_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c "COMMENT ON DATABASE migration_writer_test IS NULL" >/dev/null
if DB_TARGET=dev PGUSER=db_identity_reader PGPASSWORD=disposable-identity-reader-password \
  python3 "$identity_checker" >"$test_root/identity-missing.out" 2>&1; then
  echo "A missing identity marker unexpectedly passed verification." >&2
  exit 1
fi
if ! grep -Fq 'database marker is missing or mismatched' "$test_root/identity-missing.out"; then
  echo "A missing identity marker did not fail with a sanitized result." >&2
  exit 1
fi
psql "$MIGRATION_WRITER_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 \
  -c "COMMENT ON DATABASE migration_writer_test IS 'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku'" >/dev/null
if PGUSER=db_identity_reader PGPASSWORD=disposable-identity-reader-password \
  psql -X -w -v ON_ERROR_STOP=1 -Atqc \
    "SELECT has_database_privilege(current_user, current_database(), 'CREATE')" | grep -qx t; then
  echo "Identity probe Reader unexpectedly has database CREATE privilege." >&2
  exit 1
fi
echo 'PASS: minimum Reader verifies a database comment identity marker read-only and rejects a wrong target'
if DB_TARGET=dev python3 "$identity_checker" >/dev/null; then
  echo 'PASS: disposable Writer credential verifies the same identity marker with a read-only transaction'
else
  echo "The disposable Writer credential could not verify the database-side identity marker." >&2
  exit 1
fi

fixture="$test_root/project"
mkdir -p "$fixture/supabase/migrations" "$test_root/bin"
cat > "$fixture/supabase/config.toml" <<'TOML'
[project]
id = "migration-writer-test"

[db.migrations]
TOML
cat > "$fixture/supabase/migrations/20260101000000_writer_probe_base.sql" <<'SQL'
CREATE TABLE public.writer_probe (
  id integer PRIMARY KEY
);
SQL

write_manifest() {
  (cd "$fixture" && sha256sum supabase/migrations/*.sql | sed 's#  supabase/#  supabase/#' > supabase/migrations/SHA256SUMS)
}
write_manifest
git -C "$fixture" init -q -b main
git -C "$fixture" config user.name 'Migration Writer Test'
git -C "$fixture" config user.email 'migration-writer-test@example.invalid'
git -C "$fixture" add supabase
git -C "$fixture" commit -q -m 'fixture baseline migration'
base_ref="$(git -C "$fixture" rev-parse HEAD)"

export SUPABASE_DB_URL="$MIGRATION_WRITER_TEST_DATABASE_URL"
apply_script="$repo_root/scripts/apply-pending-migrations.py"
cli="$repo_root/node_modules/.bin/supabase"

DB_TARGET=dev python3 "$apply_script" \
  --repo "$fixture" \
  --migrations-dir "$fixture/supabase/migrations" \
  --workdir "$fixture" \
  --base-ref "$base_ref" \
  --supabase "$cli"

cat > "$fixture/supabase/migrations/20260102000000_writer_probe_add_label.sql" <<'SQL'
ALTER TABLE public.writer_probe ADD COLUMN label text;
SQL
write_manifest

DB_TARGET=dev python3 "$apply_script" \
  --repo "$fixture" \
  --migrations-dir "$fixture/supabase/migrations" \
  --workdir "$fixture" \
  --base-ref "$base_ref" \
  --supabase "$cli"

column_exists="$(psql "$MIGRATION_WRITER_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -Atqc \
  "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute WHERE attrelid = 'public.writer_probe'::regclass AND attname = 'label' AND NOT attisdropped)")"
business_select="$(psql "$MIGRATION_WRITER_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -Atqc \
  "SELECT has_table_privilege('db_identity_reader', 'public.writer_probe', 'SELECT')")"
history="$(psql "$MIGRATION_WRITER_TEST_DATABASE_URL" -X -w -v ON_ERROR_STOP=1 -Atqc \
  "SELECT string_agg(version, ',' ORDER BY version) FROM supabase_migrations.schema_migrations")"
if [[ "$column_exists" != t || "$business_select" != f || "$history" != '20260101000000,20260102000000' ]]; then
  echo "PENDING migration was not fully applied to the disposable database." >&2
  exit 1
fi

cat > "$test_root/bin/should-not-run" <<'SH'
#!/usr/bin/env sh
echo invoked > "$MIGRATION_WRITER_TEST_SENTINEL"
exit 99
SH
chmod 700 "$test_root/bin/should-not-run"
export MIGRATION_WRITER_TEST_SENTINEL="$test_root/unexpected-cli-call"
DB_TARGET=dev python3 "$apply_script" \
  --repo "$fixture" \
  --migrations-dir "$fixture/supabase/migrations" \
  --workdir "$fixture" \
  --base-ref "$base_ref" \
  --supabase "$test_root/bin/should-not-run"
if [[ -e "$MIGRATION_WRITER_TEST_SENTINEL" ]]; then
  echo "IN_SYNC migration state unexpectedly invoked the Writer CLI." >&2
  exit 1
fi
echo 'PASS: PostgreSQL 17 PENDING migrations apply and IN_SYNC is a safe no-op'

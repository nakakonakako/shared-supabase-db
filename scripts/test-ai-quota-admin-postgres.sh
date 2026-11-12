#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source scripts/lib/ai-quota-test-db-url.sh
DB="$AI_QUOTA_TEST_DATABASE_URL"
# Only the explicitly opted-in dedicated loopback cluster is allowed.
[[ "$(psql "$DB" -X -Atqc "SELECT pg_catalog.to_regnamespace('ai_quota') IS NULL")" == t ]]
[[ "$(psql "$DB" -X -Atqc "SELECT count(*)=0 FROM pg_catalog.pg_roles WHERE rolname IN ('ai_quota_owner','ai_quota_backend','ai_quota_admin_owner','ai_quota_admin_login')")" == t ]]
psql "$DB" -X -v ON_ERROR_STOP=1 -f supabase/tests/ai_quota/setup.sql >/dev/null
psql "$DB" -X -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE ROLE migration_preflight_reader NOLOGIN;
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid primary key, confirmed_at timestamptz, last_sign_in_at timestamptz,
  is_anonymous boolean, deleted_at timestamptz, banned_until timestamptz);
ALTER TABLE auth.users ENABLE ROW LEVEL SECURITY;
COMMENT ON DATABASE ai_quota_test IS 'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku';
SQL
psql "$DB" -X -v ON_ERROR_STOP=1 -f supabase/migrations/20261014120000_s1_06_ai_quota_foundation.sql >/dev/null
psql "$DB" -X -v ON_ERROR_STOP=1 -f supabase/migrations/20261111100000_ai_quota_developer_exception.sql >/dev/null
psql "$DB" -X -v ON_ERROR_STOP=1 -f supabase/migrations/20261112100000_ai_quota_admin_operations.sql >/dev/null
psql "$DB" -X -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
INSERT INTO supabase_migrations.schema_migrations(version) VALUES ('20261014120000'),('20261111100000'),('20261112100000');
GRANT USAGE ON SCHEMA supabase_migrations, ai_quota TO migration_preflight_reader;
GRANT SELECT (version) ON supabase_migrations.schema_migrations TO migration_preflight_reader;
GRANT SELECT (id) ON ai_quota.settings TO migration_preflight_reader;
INSERT INTO auth.users VALUES
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',now(),now(),false,NULL,NULL),
('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',now(),now(),true,NULL,NULL),
('cccccccc-cccc-4ccc-8ccc-cccccccccccc',now(),now(),false,NULL,now()+interval '1 day'),
('dddddddd-dddd-4ddd-8ddd-dddddddddddd',NULL,NULL,false,NULL,NULL);
SQL
psql "$DB" -X -v ON_ERROR_STOP=1 -c 'SET ROLE migration_preflight_reader' -f supabase/diagnostics/verify_s1_06_ai_quota_integrity.sql >/dev/null
psql "$DB" -X -v ON_ERROR_STOP=1 -c 'SET ROLE migration_preflight_reader' -f supabase/diagnostics/verify_ai_quota_admin_integrity.sql >/dev/null
ADMIN_DB="${DB/postgresql:\/\/postgres@/postgresql:\/\/ai_quota_admin_login@}"
[[ "$ADMIN_DB" != "$DB" ]]
admin() { psql "$ADMIN_DB" -X -w -q -A -t -v ON_ERROR_STOP=1 -c "$1"; }
expect_denied() { if admin "$1" >/dev/null 2>&1; then echo 'Expected operation to fail' >&2; exit 1; fi; }
[[ "$(admin "SELECT ai_quota_admin.preview_developer('dev')")" == none ]]
expect_denied "SELECT ai_quota_admin.preview_developer('production')"
expect_denied "SELECT * FROM ai_quota.settings"
expect_denied "SELECT * FROM ai_quota_admin.operation_log"
expect_denied "SELECT ai_quota_auth_probe.is_valid_user('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')"
for bad in bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb cccccccc-cccc-4ccc-8ccc-cccccccccccc dddddddd-dddd-4ddd-8ddd-dddddddddddd eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee; do
  expect_denied "SELECT * FROM ai_quota_admin.change_developer('dev','set','none','$bad','tester',101)"
done
[[ "$(admin "SELECT changed FROM ai_quota_admin.change_developer('dev','set','none','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','tester',102)")" == t ]]
FINGERPRINT="$(printf '%s' 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' | sha256sum | cut -d' ' -f1)"
[[ "$(admin "SELECT ai_quota_admin.preview_developer('dev')")" == "$FINGERPRINT" ]]
[[ "$(admin "SELECT operation || ':' || actor FROM ai_quota_admin.audit_developer('dev',102)")" == set:tester ]]
expect_denied "SELECT * FROM ai_quota_admin.change_developer('dev','clear','none',NULL,'tester',103)"
expect_denied "SELECT * FROM ai_quota_admin.change_developer('dev','clear','$FINGERPRINT',NULL,'tester',102)"
[[ "$(admin "SELECT changed FROM ai_quota_admin.change_developer('dev','clear','$FINGERPRINT',NULL,'tester',104)")" == t ]]
[[ "$(admin "SELECT ai_quota_admin.preview_developer('dev')")" == none ]]
[[ "$(psql "$DB" -X -Atqc 'SELECT count(*) FROM ai_quota_admin.operation_log')" == 2 ]]
echo 'PASS: bounded admin role, account checks, audit, identity, stale/replay and Reader diagnostics'

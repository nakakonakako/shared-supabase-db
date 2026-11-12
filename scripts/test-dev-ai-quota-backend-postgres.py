"""Test only against an explicitly opted-in disposable SCRAM PostgreSQL cluster."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('backend_provision', ROOT / 'scripts/provision-dev-ai-quota-backend.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
if os.environ.get('AI_QUOTA_TEST_ALLOW_DISPOSABLE_DB') != 'YES' or os.environ.get('PGHOST') != '127.0.0.1' or os.environ.get('PGDATABASE') != 'ai_quota_test':
    raise SystemExit('Requires an explicitly opted-in dedicated loopback test cluster')
root = dict(os.environ, PGUSER='bootstrap', PGPASSWORD='bootstrap_test_password', PGSSLMODE='disable')
writer = dict(root, PGUSER='postgres', PGPASSWORD='writer_test_password')

def sql(env, statement):
    result = subprocess.run(['psql', '-X', '-w', '-q', '-v', 'ON_ERROR_STOP=1', '-c', statement], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        raise RuntimeError('disposable SQL setup failed')

def login(password):
    env = dict(root, PGUSER='ai_quota_backend', PGPASSWORD=password)
    return subprocess.run(['psql', '-X', '-w', '-q', '-c', 'SELECT current_user'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def attempt(password, expected):
    os.environ.update(writer)
    try:
        mod.provision('dev', password, 'ai_quota_backend')
    except mod.ProvisionError as error:
        if expected not in str(error):
            raise AssertionError(str(error)) from None
    else:
        if expected != 'success':
            raise AssertionError('expected failure')

for _ in range(30):
    if subprocess.run(['psql', '-X', '-w', '-q', '-c', 'SELECT 1'], env=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        break
    time.sleep(1)
else:
    raise SystemExit('disposable PostgreSQL did not become ready')

sql(root, "CREATE ROLE postgres LOGIN CREATEROLE PASSWORD 'writer_test_password'; COMMENT ON DATABASE ai_quota_test IS 'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku';")
sql(writer, 'CREATE ROLE ai_quota_backend LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS')
sql(root, 'CREATE SCHEMA ai_quota; GRANT USAGE ON SCHEMA ai_quota TO ai_quota_backend')
first, second = 'A' * 40, 'B' * 40
attempt(first, 'stage=password_state_lock; password_update=not_attempted')
assert not login(first)
sql(root, 'ALTER ROLE postgres SUPERUSER')
sql(root, "COMMENT ON DATABASE ai_quota_test IS 'wrong'")
attempt(first, 'stage=db_identity; password_update=not_attempted')
sql(root, "COMMENT ON DATABASE ai_quota_test IS 'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku'")
attempt(first, 'success')
assert login(first) and not login(second)
attempt(second, 'stage=password_state; password_update=not_attempted')
assert login(first) and not login(second)
sql(root, "DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ai_quota_backend' AND (NOT rolcanlogin OR rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls OR rolinherit)) OR EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.member WHERE r.rolname='ai_quota_backend') OR NOT has_schema_privilege('ai_quota_backend', 'ai_quota', 'USAGE') THEN RAISE EXCEPTION 'role attributes, memberships or grants changed'; END IF; END $$")
print('PASS: isolated SCRAM initialization, existing password protection, denied catalog access, identity and role attributes')

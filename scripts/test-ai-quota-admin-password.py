#!/usr/bin/env python3
"""Integration tests: dedicated disposable PostgreSQL 17 with SCRAM host auth."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('provision', ROOT / 'scripts/provision-ai-quota-admin.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

if os.environ.get('AI_QUOTA_TEST_ALLOW_DISPOSABLE_DB') != 'YES' or os.environ.get('PGHOST') != '127.0.0.1' or os.environ.get('PGDATABASE') != 'ai_quota_test':
    raise SystemExit('Requires an explicitly opted-in dedicated loopback test cluster')
root = dict(os.environ, PGUSER='bootstrap', PGPASSWORD='bootstrap_test_password', PGSSLMODE='disable')
writer = dict(root, PGUSER='postgres', PGPASSWORD='writer_test_password')
for _ in range(30):
    ready = subprocess.run(['psql', '-X', '-w', '-q', '-c', 'SELECT 1'], env=root,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if ready.returncode == 0:
        break
    time.sleep(1)
else:
    raise SystemExit('disposable PostgreSQL did not become ready')

def sql(env, statement):
    p = subprocess.run(['psql', '-X', '-w', '-q', '-v', 'ON_ERROR_STOP=1', '-c', statement], env=env, capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError('disposable SQL setup failed')

def login(pw):
    env = dict(root, PGUSER='ai_quota_admin_login', PGPASSWORD=pw)
    return subprocess.run(['psql', '-X', '-w', '-q', '-c', 'SELECT 1'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def attempt(password, should_pass):
    os.environ.update(writer)
    try:
        mod.provision('dev', password, 'ai_quota_admin_login')
    except mod.ProvisionError:
        if should_pass:
            raise
    else:
        if not should_pass:
            raise AssertionError('expected failure')

sql(root, "CREATE ROLE postgres LOGIN CREATEROLE PASSWORD 'writer_test_password'; COMMENT ON DATABASE ai_quota_test IS 'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku';")
sql(writer, 'CREATE ROLE ai_quota_admin_login LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS')
sql(root, "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles r ON r.oid=m.roleid JOIN pg_catalog.pg_roles u ON u.oid=m.member WHERE r.rolname='ai_quota_admin_login' AND u.rolname='postgres' AND m.admin_option) THEN RAISE EXCEPTION 'automatic admin grant missing'; END IF; END $$;")
first = 'A' * 40
second = 'B' * 40
assert not login(first)
attempt('', False)
sql(root, "COMMENT ON DATABASE ai_quota_test IS 'wrong';")
attempt(first, False)
assert not login(first)
sql(root, "COMMENT ON DATABASE ai_quota_test IS 'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku';")
sql(root, 'ALTER ROLE postgres NOCREATEROLE')
attempt(first, False)
sql(root, 'ALTER ROLE postgres CREATEROLE; REVOKE ADMIN OPTION FOR ai_quota_admin_login FROM postgres')
attempt(first, False)
sql(root, 'GRANT ai_quota_admin_login TO postgres WITH ADMIN TRUE, SET FALSE, INHERIT FALSE')
attempt(first, True)
assert login(first) and not login(second)
attempt(second, True)
assert login(second) and not login(first)
sql(root, "DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles r ON r.oid=m.member WHERE r.rolname='ai_quota_admin_login') OR pg_catalog.has_database_privilege('ai_quota_admin_login',current_database(),'CREATE') THEN RAISE EXCEPTION 'unexpected privilege'; END IF; END $$;")
print('PASS: SCRAM initial setup, rotation, denied privileges and identity, absent secret, login boundaries')

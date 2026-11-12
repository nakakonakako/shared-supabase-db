#!/usr/bin/env python3
"""Verify a Dev admin login and DB identity using only read-only SQL."""
import importlib.util
import os
from pathlib import Path
import re
import sys

from db_target_identity import EXPECTED_PROJECT_REFS, expected_database_identity

spec = importlib.util.spec_from_file_location('admin_provision', Path(__file__).with_name('provision-ai-quota-admin.py'))
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)


def verify(target):
    marker = expected_database_identity(target)
    if target != 'dev' or not marker or not os.environ.get('PGPASSWORD'):
        raise ValueError('secret_or_target_invalid')
    stage = 'connection_or_authentication'
    try:
        pq = lib.library()
        conn = lib.connect(pq)
        try:
            if pq.PQconnectionUsedPassword(conn) != 1:
                stage = 'password_authentication_unconfirmed'
                raise ValueError('invalid')
            stage = 'read_only_identity'
            lib.query(pq, conn, 'BEGIN TRANSACTION READ ONLY', 1)
            result = lib.query(pq, conn, "SELECT CASE WHEN current_user='ai_quota_admin_login' AND (SELECT pg_catalog.shobj_description(oid,'pg_database') FROM pg_catalog.pg_database WHERE datname=current_database())='" + marker + "' THEN 'ok' ELSE 'denied' END")
            if result != 'ok':
                raise ValueError('invalid')
            lib.query(pq, conn, 'COMMIT', 1)
        finally:
            pq.PQfinish(conn)
    except Exception:
        raise ValueError(stage) from None


def main():
    ref = EXPECTED_PROJECT_REFS['dev']
    env = os.environ
    allowed_host = re.fullmatch(r'aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com', env.get('PGHOST', ''))
    if not (env.get('GITHUB_REF') == 'refs/heads/main' and re.fullmatch(r'[0-9a-f]{40}', env.get('GITHUB_SHA', ''))
            and env.get('DB_TARGET') == 'dev' and env.get('DB_PROJECT_REF') == ref
            and env.get('DB_ENVIRONMENT') == 'development-db-apply' and allowed_host
            and env.get('PGUSER') == f'ai_quota_admin_login.{ref}' and env.get('PGDATABASE') == 'postgres'
            and env.get('PGPORT') == '5432' and env.get('PGSSLMODE') == 'require' and env.get('PGCONNECT_TIMEOUT') == '10'
            and not any(env.get(k) for k in ('PGHOSTADDR', 'PGSERVICE', 'PGSERVICEFILE', 'PGPASSFILE', 'PGOPTIONS', 'PGTARGETSESSIONATTRS', 'PGREQUIRESSL'))):
        print('admin login diagnostic: configuration_invalid', file=sys.stderr)
        return 2
    try:
        verify('dev')
    except ValueError as exc:
        print(f'admin login diagnostic: {exc}', file=sys.stderr)
        return 2
    print('admin login diagnostic: PASS (password authentication and Dev identity; read-only)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

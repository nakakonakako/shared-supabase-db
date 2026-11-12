#!/usr/bin/env python3
"""One-shot Dev authentication diagnosis. Never print error text or secret data."""
from __future__ import annotations

import ctypes
import importlib.util
import os
from pathlib import Path
import re
import sys

from db_target_identity import EXPECTED_PROJECT_REFS, expected_database_identity

spec = importlib.util.spec_from_file_location('provision', Path(__file__).with_name('provision-ai-quota-admin.py'))
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)


def error_category(message):
    text = message.lower()
    patterns = (
        ('circuit_breaker', ('circuit breaker open',)),
        ('pooler_credential_format', ('eauthquery',)),
        ('pooler_tenant_or_user', ('tenant or user not found',)),
        ('authentication', ('password authentication failed', 'authentication failed', 'sasl authentication failed', 'no password supplied')),
        ('timeout', ('timed out', 'timeout expired')),
        ('tls', ('ssl error', 'ssl connection', 'tls error', 'certificate verify failed', 'server does not support ssl')),
        ('dns', ('could not translate host name', 'name or service not known', 'temporary failure in name resolution')),
        ('network', ('connection refused', 'network is unreachable', 'connection reset', 'no route to host', 'server closed the connection')),
    )
    return next((name for name, values in patterns if any(x in text for x in values)), 'other_connection_error')


def open_connection(pq):
    conn = pq.PQconnectdb(b'')
    if not conn:
        return None, 'connection_allocation_failed'
    if pq.PQstatus(conn) == 0:
        return conn, None
    raw = pq.PQerrorMessage(conn)
    category = error_category(raw.decode('utf-8', errors='replace') if raw else '')
    pq.PQfinish(conn)
    return None, category


def record(stage, status, reason=None):
    print(f'{stage}: {status}' + (f' ({reason})' if reason else ''), flush=True)


def diagnose(admin_password, admin_user=None):
    completed = set()
    def emit(stage, status, reason=None):
        completed.add(stage)
        record(stage, status, reason)
    def finish(code):
        for name in ('secret_format', 'libpq', 'writer_connection', 'db_identity', 'admin_role', 'password_state', 'admin_authentication', 'admin_identity'):
            if name not in completed:
                record(name, 'SKIP', 'not_reached')
        return code
    valid = bool(re.fullmatch(r'[A-Za-z0-9._-]{32,128}', admin_password or ''))
    emit('secret_format', 'PASS' if valid else 'FAIL', None if valid else 'missing_or_invalid')
    try:
        pq = lib.library()
        pq.PQerrorMessage.argtypes = [ctypes.c_void_p]
        pq.PQerrorMessage.restype = ctypes.c_char_p
    except Exception:
        emit('libpq', 'FAIL', 'initialization_failed')
        emit('remaining', 'SKIP', 'libpq_unavailable')
        return finish(2)
    emit('libpq', 'PASS')
    writer, error = open_connection(pq)
    if writer is None:
        emit('writer_connection', 'FAIL', error)
        emit('remaining', 'SKIP', 'writer_unavailable')
        return finish(2)
    if pq.PQconnectionUsedPassword(writer) != 1:
        pq.PQfinish(writer)
        emit('writer_connection', 'FAIL', 'password_auth_unconfirmed')
        emit('remaining', 'SKIP', 'writer_unavailable')
        return finish(2)
    emit('writer_connection', 'PASS')
    marker = expected_database_identity('dev')
    try:
        lib.query(pq, writer, 'BEGIN TRANSACTION READ ONLY', 1)
        identity = lib.query(pq, writer, "SELECT CASE WHEN current_user='postgres' AND (SELECT pg_catalog.shobj_description(oid,'pg_database') FROM pg_catalog.pg_database WHERE datname=current_database())='" + marker + "' THEN 'ok' ELSE 'denied' END")
        if identity != 'ok':
            emit('db_identity', 'FAIL', 'mismatch')
            emit('remaining', 'SKIP', 'identity_unverified')
            return finish(2)
        emit('db_identity', 'PASS')
        role = lib.query(pq, writer, "SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='ai_quota_admin_login') THEN 'missing' WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='ai_quota_admin_login' AND rolcanlogin AND NOT rolsuper AND NOT rolreplication AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolbypassrls AND NOT rolinherit) THEN 'ok' ELSE 'invalid' END")
        if role not in ('ok', 'missing', 'invalid'):
            raise ValueError('unexpected')
        emit('admin_role', 'PASS' if role == 'ok' else 'FAIL', None if role == 'ok' else role)
        password_ok = True
        can_read = lib.query(pq, writer, "SELECT CASE WHEN pg_catalog.has_table_privilege(current_user,'pg_catalog.pg_authid','SELECT') OR (pg_catalog.has_column_privilege(current_user,'pg_catalog.pg_authid','rolname','SELECT') AND pg_catalog.has_column_privilege(current_user,'pg_catalog.pg_authid','rolpassword','SELECT')) THEN 'yes' ELSE 'no' END")
        if can_read == 'yes':
            state = lib.query(pq, writer, "SELECT CASE WHEN rolpassword IS NULL THEN 'unset' ELSE 'set' END FROM pg_catalog.pg_authid WHERE rolname='ai_quota_admin_login'") if role != 'missing' else 'unknown'
            if state not in ('set', 'unset', 'unknown'):
                raise ValueError('unexpected')
            password_ok = state != 'unset'
            emit('password_state', 'PASS' if state == 'set' else 'FAIL' if state == 'unset' else 'UNKNOWN', state)
        elif can_read == 'no':
            emit('password_state', 'UNKNOWN', 'insufficient_catalog_privilege')
        else:
            raise ValueError('unexpected')
        lib.query(pq, writer, 'COMMIT', 1)
    except Exception:
        emit('writer_read_only', 'FAIL', 'query_or_privilege_error')
        emit('admin_authentication', 'SKIP', 'writer_check_incomplete')
        return finish(2)
    finally:
        pq.PQfinish(writer)
    if not admin_password:
        emit('admin_authentication', 'SKIP', 'secret_missing')
        return finish(2)
    os.environ['PGUSER'] = admin_user or 'ai_quota_admin_login.' + EXPECTED_PROJECT_REFS['dev']
    os.environ['PGPASSWORD'] = admin_password
    admin, error = open_connection(pq)
    if admin is None:
        emit('admin_authentication', 'FAIL', error)
        return finish(2)
    try:
        if pq.PQconnectionUsedPassword(admin) != 1:
            emit('admin_authentication', 'FAIL', 'password_auth_unconfirmed')
            return finish(2)
        emit('admin_authentication', 'PASS')
        lib.query(pq, admin, 'BEGIN TRANSACTION READ ONLY', 1)
        identity = lib.query(pq, admin, "SELECT CASE WHEN current_user='ai_quota_admin_login' AND (SELECT pg_catalog.shobj_description(oid,'pg_database') FROM pg_catalog.pg_database WHERE datname=current_database())='" + marker + "' THEN 'ok' ELSE 'denied' END")
        if identity != 'ok':
            emit('admin_identity', 'FAIL', 'mismatch')
            return finish(2)
        lib.query(pq, admin, 'COMMIT', 1)
        emit('admin_identity', 'PASS')
    except Exception:
        emit('admin_identity', 'FAIL', 'query_error')
        return finish(2)
    finally:
        pq.PQfinish(admin)
    return finish(0 if valid and role == 'ok' and password_ok else 1)


def main():
    # Do not permit this program to connect if invoked outside the validated Dev job.
    env = os.environ
    ref = EXPECTED_PROJECT_REFS['dev']
    if not (env.get('GITHUB_REF') == 'refs/heads/main' and re.fullmatch(r'[0-9a-f]{40}', env.get('GITHUB_SHA', ''))
            and env.get('DB_TARGET') == 'dev' and env.get('DB_ENVIRONMENT') == 'development-db-apply'
            and env.get('DB_PROJECT_REF') == ref and env.get('DB_POOLER_HOST') == env.get('PGHOST')
            and re.fullmatch(r'aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com', env.get('PGHOST', ''))
            and env.get('PGUSER') == 'postgres.' + ref and env.get('PGPORT') == '5432'
            and env.get('PGDATABASE') == 'postgres' and env.get('PGSSLMODE') == 'require'
            and env.get('PGCONNECT_TIMEOUT') == '10' and env.get('PGPASSWORD')
            and not any(env.get(k) for k in ('PGHOSTADDR', 'PGSERVICE', 'PGSERVICEFILE', 'PGPASSFILE', 'PGOPTIONS', 'PGTARGETSESSIONATTRS', 'PGREQUIRESSL'))):
        record('configuration', 'FAIL', 'invalid')
        return 2
    try:
        return diagnose(env.pop('AI_QUOTA_ADMIN_PASSWORD', ''))
    except Exception:
        record('diagnostic', 'FAIL', 'internal_error')
        return 2


if __name__ == '__main__':
    sys.exit(main())

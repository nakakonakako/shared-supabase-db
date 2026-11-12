#!/usr/bin/env python3
"""Set the dedicated login password using a protected Writer connection."""
from __future__ import annotations

import ctypes
import ctypes.util
import os
import re
import sys

from db_target_identity import expected_database_identity


class ProvisionError(Exception):
    pass


def library():
    path = ctypes.util.find_library('pq')
    if not path:
        raise ProvisionError('libpq unavailable')
    pq = ctypes.CDLL(path)
    signatures = {
        'PQconnectdb': ([ctypes.c_char_p], ctypes.c_void_p),
        'PQstatus': ([ctypes.c_void_p], ctypes.c_int),
        'PQfinish': ([ctypes.c_void_p], None),
        'PQexec': ([ctypes.c_void_p, ctypes.c_char_p], ctypes.c_void_p),
        'PQresultStatus': ([ctypes.c_void_p], ctypes.c_int),
        'PQntuples': ([ctypes.c_void_p], ctypes.c_int),
        'PQgetvalue': ([ctypes.c_void_p, ctypes.c_int, ctypes.c_int], ctypes.c_char_p),
        'PQclear': ([ctypes.c_void_p], None),
        'PQencryptPasswordConn': ([ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p], ctypes.c_void_p),
        'PQfreemem': ([ctypes.c_void_p], None),
        'PQconnectionUsedPassword': ([ctypes.c_void_p], ctypes.c_int),
    }
    for name, (args, result) in signatures.items():
        fn = getattr(pq, name)
        fn.argtypes, fn.restype = args, result
    return pq


def connect(pq, connection_string=b''):
    conn = pq.PQconnectdb(connection_string)
    if not conn or pq.PQstatus(conn) != 0:
        if conn:
            pq.PQfinish(conn)
        raise ProvisionError('connection failed')
    return conn


def query(pq, conn, sql, expected_status=2):
    result = pq.PQexec(conn, sql.encode('ascii'))
    if not result:
        raise ProvisionError('database execution failed')
    try:
        if pq.PQresultStatus(result) != expected_status:
            raise ProvisionError('database execution failed')
        if expected_status == 2:
            if pq.PQntuples(result) != 1:
                raise ProvisionError('database result invalid')
            return pq.PQgetvalue(result, 0, 0).decode('ascii')
        return None
    finally:
        pq.PQclear(result)


def provision(target, password, admin_user):
    stage = 'secret_validation'
    alter = 'not_attempted'
    pq = None
    try:
        marker = expected_database_identity(target)
        if not marker or not password or '\x00' in password or not re.fullmatch(r'[A-Za-z0-9._-]{32,128}', password):
            raise ProvisionError('invalid')
        stage = 'libpq_initialization'
        pq = library()
        stage = 'writer_connection'
        conn = connect(pq)
        try:
            stage = 'writer_session'
            query(pq, conn, "SET statement_timeout = '15s'", 1)
            stage = 'db_identity'
            identity = "SELECT CASE WHEN current_user='postgres' AND (SELECT pg_catalog.shobj_description(oid,'pg_database') FROM pg_catalog.pg_database WHERE datname=current_database())='" + marker + "' THEN 'ok' ELSE 'denied' END"
            if query(pq, conn, identity) != 'ok':
                raise ProvisionError('invalid')
            stage = 'target_role'
            role = "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='ai_quota_admin_login' AND rolcanlogin AND NOT rolsuper AND NOT rolreplication AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolbypassrls AND NOT rolinherit) THEN 'ok' ELSE 'denied' END"
            if query(pq, conn, role) != 'ok':
                raise ProvisionError('invalid')
            stage = 'writer_createrole'
            create_role = "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname=current_user AND (rolsuper OR rolcreaterole)) THEN 'ok' ELSE 'denied' END"
            if query(pq, conn, create_role) != 'ok':
                raise ProvisionError('invalid')
            stage = 'writer_admin_option'
            admin_option = "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname=current_user AND rolsuper) OR EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles r ON r.oid=m.roleid JOIN pg_catalog.pg_roles u ON u.oid=m.member WHERE r.rolname='ai_quota_admin_login' AND u.rolname=current_user AND m.admin_option) THEN 'ok' ELSE 'denied' END"
            if query(pq, conn, admin_option) != 'ok':
                raise ProvisionError('invalid')
            stage = 'verifier_generation'
            verifier_ptr = pq.PQencryptPasswordConn(conn, password.encode(), b'ai_quota_admin_login', b'scram-sha-256')
            if not verifier_ptr:
                raise ProvisionError('invalid')
            try:
                verifier = ctypes.string_at(verifier_ptr).decode('ascii')
            finally:
                pq.PQfreemem(verifier_ptr)
            if not re.fullmatch(r'SCRAM-SHA-256\$[0-9]+:[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+', verifier):
                raise ProvisionError('invalid')
            stage = 'password_update'
            alter = 'unknown'
            print('password_update: attempt_started; outcome=unknown', flush=True)
            query(pq, conn, "ALTER ROLE ai_quota_admin_login PASSWORD '" + verifier + "'", 1)
            alter = 'confirmed'
            print('password_update: confirmed', flush=True)
        finally:
            pq.PQfinish(conn)
        stage = 'admin_authentication'
        os.environ['PGUSER'] = admin_user
        os.environ['PGPASSWORD'] = password
        check = connect(pq)
        try:
            if pq.PQconnectionUsedPassword(check) != 1:
                raise ProvisionError('invalid')
            stage = 'admin_identity'
            result = query(pq, check, "SELECT CASE WHEN current_user='ai_quota_admin_login' AND (SELECT pg_catalog.shobj_description(oid,'pg_database') FROM pg_catalog.pg_database WHERE datname=current_database())='" + marker + "' THEN 'ok' ELSE 'denied' END")
            if result != 'ok':
                raise ProvisionError('invalid')
        finally:
            pq.PQfinish(check)
    except Exception:
        # Never expose raw SQL, libpq errors, passwords, or verifier material.
        raise ProvisionError(f'stage={stage}; password_update={alter}') from None


def main():
    target = os.environ.get('DB_TARGET', '')
    password = os.environ.pop('AI_QUOTA_ADMIN_PASSWORD', '')
    try:
        provision(target, password, 'ai_quota_admin_login.' + os.environ['DB_PROJECT_REF'])
    except ProvisionError as exc:
        print(f'provision failed: {exc}; inspect before retry', file=sys.stderr)
        return 2
    except Exception:
        print('provision failed: stage=configuration; password_update=not_attempted', file=sys.stderr)
        return 2
    print('admin password updated; dedicated password-authenticated login and DB identity verified')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

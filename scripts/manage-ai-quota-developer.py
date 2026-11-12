#!/usr/bin/env python3
"""Run the protected developer-exception operation through its dedicated DB role."""
from __future__ import annotations

import os
import hashlib
import re
import shutil
import subprocess
import sys
import uuid

from db_target_identity import EXPECTED_PROJECT_REFS

HOST = re.compile(r"^aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com$")
SHA = re.compile(r"^[0-9a-f]{40}$")
UNSUPPORTED_LIBPQ_OVERRIDES = (
    "PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE", "PGPASSFILE", "PGOPTIONS",
    "PGTARGETSESSIONATTRS", "PGREQUIRESSL",
)

FINGERPRINT = re.compile(r"(?:none|[0-9a-f]{64})\Z")
ACTOR = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}\Z")


def validated_inputs(env: dict[str, str]) -> tuple[str, str, str, str, str, str, str]:
    target = env.get("DB_TARGET", "")
    operation = env.get("ADMIN_OPERATION", "")
    new_id = env.get("ADMIN_USER_ID", "")
    expected = env.get("ADMIN_EXPECTED", "")
    actor = env.get("GITHUB_ACTOR", "")
    run_id = env.get("GITHUB_RUN_ID", "")
    audit_run_id = env.get("ADMIN_AUDIT_RUN_ID", "")
    if target not in EXPECTED_PROJECT_REFS or operation not in {"preview", "set", "clear", "audit"}:
        raise ValueError("invalid target or operation")
    if operation == "set":
        try:
            parsed = uuid.UUID(new_id)
        except (ValueError, AttributeError):
            raise ValueError("invalid user ID") from None
        if str(parsed) != new_id or parsed.int == 0:
            raise ValueError("invalid user ID")
    elif new_id:
        raise ValueError("user ID must be empty for preview and clear")
    if operation in {"preview", "audit"}:
        if expected:
            raise ValueError("expected fingerprint must be empty for preview")
    elif not FINGERPRINT.fullmatch(expected):
        raise ValueError("expected fingerprint is required")
    if not ACTOR.fullmatch(actor) or not re.fullmatch(r"[1-9][0-9]{0,17}", run_id):
        raise ValueError("invalid audit context")
    if operation == "audit":
        if not re.fullmatch(r"[1-9][0-9]{0,17}", audit_run_id):
            raise ValueError("audit run ID is required")
    elif audit_run_id:
        raise ValueError("audit run ID is only valid for audit")
    return target, operation, new_id, expected, actor, run_id, audit_run_id


def validate_connection(env: dict[str, str], target: str) -> None:
    ref = EXPECTED_PROJECT_REFS[target]
    expected_env = "development-db-apply" if target == "dev" else "production-db-apply"
    host = env.get("DB_POOLER_HOST", "")
    valid = (
        env.get("GITHUB_REF") == "refs/heads/main"
        and bool(SHA.fullmatch(env.get("GITHUB_SHA", "")))
        and env.get("DB_ENVIRONMENT") == expected_env
        and env.get("DB_PROJECT_REF") == ref
        and bool(HOST.fullmatch(host))
        and env.get("PGHOST") == host
        and env.get("PGPORT") == "5432"
        and env.get("PGDATABASE") == "postgres"
        and env.get("PGUSER") == f"ai_quota_admin_login.{ref}"
        and env.get("PGSSLMODE") == "require"
        and env.get("PGCONNECT_TIMEOUT") == "10"
        and bool(env.get("PGPASSWORD"))
        and not any(env.get(key) for key in UNSUPPORTED_LIBPQ_OVERRIDES)
    )
    if not valid:
        raise ValueError("unsafe or mismatched admin DB configuration")


def main() -> int:
    env = dict(os.environ)
    try:
        target, op, new_id, expected, actor, run_id, audit_run_id = validated_inputs(env)
        if env.get("ADMIN_PREFLIGHT") != "1":
            validate_connection(env, target)
    except ValueError as exc:
        print(f"admin operation: {exc}", file=sys.stderr)
        return 2
    if env.get("ADMIN_PREFLIGHT") == "1":
        new_fingerprint = hashlib.sha256(new_id.encode("ascii")).hexdigest() if new_id else "none"
        print(f"Target: {target}; operation: {op}; expected: {expected or 'not applicable'}; proposed: {new_fingerprint}; audit run: {audit_run_id or 'not applicable'}; run: {run_id}")
        return 0
    psql = shutil.which("psql")
    if not psql:
        print("admin operation: psql unavailable", file=sys.stderr)
        return 2
    variables = {"target": target, "op": op, "user_id": new_id, "expected": expected, "actor": actor, "run_id": run_id, "audit_run_id": audit_run_id}
    args = [psql, "-X", "-w", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"]
    for key, value in variables.items():
        args.extend(["-v", f"{key}={value}"])
    if op == "preview":
        sql = "BEGIN TRANSACTION READ ONLY; SET LOCAL statement_timeout='15s'; SELECT ai_quota_admin.preview_developer(:'target'); COMMIT;\n"
    elif op == "audit":
        sql = ("BEGIN TRANSACTION READ ONLY; SET LOCAL statement_timeout='15s'; "
               "SELECT operation || '|' || actor || '|' || before_fingerprint || '|' || after_fingerprint "
               "FROM ai_quota_admin.audit_developer(:'target', :'audit_run_id'::bigint); COMMIT;\n")
    else:
        sql = ("BEGIN; SET LOCAL lock_timeout='3s'; SET LOCAL statement_timeout='15s'; "
               "SELECT old_fingerprint || '|' || new_fingerprint FROM ai_quota_admin.change_developer("
               ":'target', :'op', :'expected', NULLIF(:'user_id','')::uuid, :'actor', :'run_id'::bigint); COMMIT;\n")
    try:
        result = subprocess.run(args, input=sql, capture_output=True, text=True, timeout=30, check=False, env=env)
    except (OSError, subprocess.SubprocessError, UnicodeError):
        print("admin operation: execution failed or outcome unknown; do not retry without review", file=sys.stderr)
        return 2
    if result.returncode != 0:
        print("admin operation: rejected or outcome unknown; inspect state before any retry", file=sys.stderr)
        return 2
    output = result.stdout.strip()
    parts = output.split("|")
    if (op == "preview" and (len(parts) != 1 or not FINGERPRINT.fullmatch(parts[0]))) or (
        op == "audit" and (len(parts) != 4 or parts[0] not in {"set", "clear"} or not ACTOR.fullmatch(parts[1])
                           or not all(FINGERPRINT.fullmatch(p) for p in parts[2:]))
    ) or (
        op in {"set", "clear"} and (len(parts) != 2 or not all(FINGERPRINT.fullmatch(p) for p in parts) or parts[0] != expected
                             or parts[1] != (hashlib.sha256(new_id.encode("ascii")).hexdigest() if new_id else "none"))
    ):
        print("admin operation: unexpected result; inspect state before any retry", file=sys.stderr)
        return 2
    if op == "preview":
        print(f"current fingerprint: {parts[0]}")
    elif op == "audit":
        print(f"audit run: {audit_run_id}; operation: {parts[0]}; actor: {parts[1]}; before: {parts[2]}; after: {parts[3]}")
    else:
        print(f"change committed; before fingerprint: {parts[0]}; after fingerprint: {parts[1]}; run: {run_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

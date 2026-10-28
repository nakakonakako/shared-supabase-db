#!/usr/bin/env python3
"""Fail-closed validation for the target-specific migration Writer connection."""

from __future__ import annotations

import os
import re
import sys

HOST = re.compile(r"^aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com$")
PROJECT_REF = re.compile(r"^[A-Za-z0-9]+$")
SHA = re.compile(r"^[0-9a-f]{40}$")
UNSUPPORTED_LIBPQ_OVERRIDES = (
    "PGHOSTADDR",
    "PGSERVICE",
    "PGSERVICEFILE",
    "PGPASSFILE",
    "PGOPTIONS",
    "PGTARGETSESSIONATTRS",
    "PGREQUIRESSL",
)


def main() -> int:
    target = os.environ.get("DB_TARGET", "")
    environment = os.environ.get("DB_ENVIRONMENT", "")
    host = os.environ.get("DB_POOLER_HOST", "")
    project_ref = os.environ.get("DB_PROJECT_REF", "")
    role = os.environ.get("DB_CONNECTION_ROLE", "")
    user_prefix = "migration_preflight_login" if role == "reader" else "postgres"
    expected_environment = {
        ("dev", "reader"): "development-db-check",
        ("production", "reader"): "production-db-check",
        ("dev", "writer"): "development-db-apply",
        ("production", "writer"): "production-db-apply",
    }.get((target, role), "")
    password_valid = bool(os.environ.get("PGPASSWORD", ""))

    valid = (
        expected_environment != ""
        and environment == expected_environment
        and os.environ.get("GITHUB_REF") == "refs/heads/main"
        and bool(SHA.fullmatch(os.environ.get("GITHUB_SHA", "")))
        and bool(HOST.fullmatch(host))
        and bool(PROJECT_REF.fullmatch(project_ref))
        and os.environ.get("PGHOST") == host
        and os.environ.get("PGPORT") == "5432"
        and os.environ.get("PGDATABASE") == "postgres"
        and os.environ.get("PGUSER") == f"{user_prefix}.{project_ref}"
        and os.environ.get("PGSSLMODE") == "require"
        and os.environ.get("PGCONNECT_TIMEOUT") == "10"
        and password_valid
        and not any(os.environ.get(name) for name in UNSUPPORTED_LIBPQ_OVERRIDES)
    )
    if not valid:
        print("migration DB target: missing, mismatched, or unsafe Environment configuration", file=sys.stderr)
        return 2
    print(f"migration DB target: {target} {role} configuration valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Fail-closed validation for the dedicated Dev Reader connection target."""

from __future__ import annotations

import os
import re
import sys

SESSION_POOLER_HOST = re.compile(r"^aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com$")
PROJECT_REF = re.compile(r"^[A-Za-z0-9]+$")
MAIN_SHA = re.compile(r"^[0-9a-f]{40}$")
UNSUPPORTED_LIBPQ_OVERRIDES = (
    "PGHOSTADDR",
    "PGSERVICE",
    "PGSERVICEFILE",
    "PGPASSFILE",
    "PGOPTIONS",
    "PGTARGETSESSIONATTRS",
    "PGREQUIRESSL",
)
PRODUCTION_CREDENTIAL_NAMES = (
    "PROD_SUPABASE_POOLER_HOST",
    "PROD_SUPABASE_PROJECT_REF",
    "MIGRATION_READER_PASSWORD",
)


def main() -> int:
    host = os.environ.get("DEV_SUPABASE_POOLER_HOST", "")
    project_ref = os.environ.get("DEV_SUPABASE_PROJECT_REF", "")
    expected_user = f"migration_preflight_login.{project_ref}"

    valid = (
        os.environ.get("GITHUB_REF") == "refs/heads/main"
        and bool(MAIN_SHA.fullmatch(os.environ.get("GITHUB_SHA", "")))
        and bool(SESSION_POOLER_HOST.fullmatch(host))
        and bool(PROJECT_REF.fullmatch(project_ref))
        and os.environ.get("PGHOST") == host
        and os.environ.get("PGPORT") == "5432"
        and os.environ.get("PGDATABASE") == "postgres"
        and os.environ.get("PGUSER") == expected_user
        and os.environ.get("PGSSLMODE") == "require"
        and os.environ.get("PGCONNECT_TIMEOUT") == "10"
        and bool(os.environ.get("DEV_MIGRATION_READER_PASSWORD", ""))
        and not any(os.environ.get(name) for name in UNSUPPORTED_LIBPQ_OVERRIDES)
        and not any(os.environ.get(name) for name in PRODUCTION_CREDENTIAL_NAMES)
    )
    if not valid:
        print(
            "Dev DB contract check: missing, mismatched, or unsafe Environment configuration",
            file=sys.stderr,
        )
        return 2
    print("Dev DB contract check: target configuration valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

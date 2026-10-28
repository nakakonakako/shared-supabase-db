#!/usr/bin/env python3
"""Compare a read-only database-side identity marker with a code-pinned target."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

from db_target_identity import expected_database_identity

QUERY = """
BEGIN TRANSACTION READ ONLY;
SELECT pg_catalog.shobj_description(d.oid, 'pg_database')
FROM pg_catalog.pg_database AS d
WHERE d.datname = pg_catalog.current_database();
COMMIT;
"""


def main() -> int:
    target = os.environ.get("DB_TARGET", "")
    expected = expected_database_identity(target)
    if expected is None:
        print("database identity verification: target configuration is invalid", file=sys.stderr)
        return 2

    psql = shutil.which("psql")
    if psql is None:
        print("database identity verification: read-only catalog query could not execute", file=sys.stderr)
        return 2

    try:
        result = subprocess.run(
            [psql, "-X", "-w", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1", "-c", QUERY],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
            env=os.environ.copy(),
        )
    except (OSError, subprocess.TimeoutExpired):
        print("database identity verification: read-only catalog query could not execute", file=sys.stderr)
        return 2

    if result.returncode != 0:
        print("database identity verification: read-only catalog query failed", file=sys.stderr)
        return 2
    if result.stdout.strip() != expected:
        print("database identity verification: database marker is missing or mismatched", file=sys.stderr)
        return 1

    print(f"database identity verification: {target} server-side marker matches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

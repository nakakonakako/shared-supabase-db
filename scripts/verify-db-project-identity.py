#!/usr/bin/env python3
"""Compare a read-only database-side identity marker with a code-pinned target."""

from __future__ import annotations

import os
import re
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

PSQL_FAILURE_CATEGORIES = (
    ("connection_timeout", ("connection timed out", "operation timed out", "timeout expired")),
    (
        "SSL / TLS",
        (
            "ssl error",
            "ssl syscall",
            "ssl connection",
            "tls error",
            "tls handshake",
            "certificate verify failed",
            "server does not support ssl",
        ),
    ),
    (
        "authentication",
        (
            "password authentication failed",
            "sasl authentication failed",
            "no password supplied",
            "fe_sendauth: no password supplied",
        ),
    ),
    (
        "pooler / connection_limit",
        (
            "too many clients already",
            "remaining connection slots are reserved",
            "max clients reached",
            "max_client_conn",
            "no more connections allowed",
            "connection pool exhausted",
        ),
    ),
    ("connection_refused", ("connection refused",)),
    (
        "network / DNS",
        (
            "could not translate host name",
            "name or service not known",
            "temporary failure in name resolution",
            "nodename nor servname provided",
            "network is unreachable",
            "no route to host",
            "connection reset by peer",
            "server closed the connection unexpectedly",
        ),
    ),
)


def classify_psql_failure(returncode: int, stderr: str) -> str:
    """Map known libpq/psql diagnostics to fixed labels without returning source text."""
    normalized = stderr.casefold()
    for category, markers in PSQL_FAILURE_CATEGORIES:
        if any(marker in normalized for marker in markers):
            return category
    if re.search(r'\brole\s+"[^"]+"\s+does not exist', normalized):
        return "authentication"
    if returncode == 3 or any(re.search(r"(?m)^ERROR:", line) for line in stderr.splitlines()):
        return "SQL execution error"
    return "unknown"


def main() -> int:
    target = os.environ.get("DB_TARGET", "")
    expected = expected_database_identity(target)
    if expected is None:
        print("database identity verification: target configuration is invalid", file=sys.stderr)
        return 2

    psql = shutil.which("psql")
    if psql is None:
        print(
            "database identity verification: read-only catalog query failed (unknown)",
            file=sys.stderr,
        )
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
    except subprocess.TimeoutExpired:
        print(
            "database identity verification: read-only catalog query failed (unknown)",
            file=sys.stderr,
        )
        return 2
    except OSError:
        print(
            "database identity verification: read-only catalog query failed (unknown)",
            file=sys.stderr,
        )
        return 2

    if result.returncode != 0:
        category = classify_psql_failure(result.returncode, result.stderr)
        print(
            f"database identity verification: read-only catalog query failed ({category})",
            file=sys.stderr,
        )
        return 2
    if result.stdout.strip() != expected:
        print("database identity verification: database marker is missing or mismatched", file=sys.stderr)
        return 1

    print(f"database identity verification: {target} server-side marker matches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

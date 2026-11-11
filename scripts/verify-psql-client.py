#!/usr/bin/env python3
"""Verify the runner's psql without contacting a database or installing packages."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys

# The supported DB server is PostgreSQL 17. PostgreSQL recommends a psql
# major at least as new as the server. Only reviewed majors are accepted.
SUPPORTED_MAJORS = frozenset({17, 18})
VERSION_PATTERN = re.compile(r"^psql \(PostgreSQL\) (\d+)\.\d+(?:\s+\([^\r\n]*\))?\s*$")


def main() -> int:
    executable = shutil.which("psql")
    if executable is None:
        print("psql is unavailable; a PostgreSQL 17 or 18 client is required", file=sys.stderr)
        return 1
    # Debian's pg_wrapper selects a client using PATH, PGHOST, PGPORT,
    # PGCLUSTER and user configuration. Preserve that selection context so
    # the checked version is the one subsequent psql calls will use.
    version_env = os.environ.copy()
    version_env.pop("PGPASSWORD", None)
    version_env.pop("PGPASSFILE", None)
    version_env["LC_ALL"] = "C"
    try:
        result = subprocess.run(
            [executable, "--version"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
            env=version_env,
        )
    except (OSError, subprocess.SubprocessError, UnicodeError):
        print("Could not determine psql version", file=sys.stderr)
        return 1
    match = VERSION_PATTERN.fullmatch(result.stdout)
    if result.returncode != 0 or not match:
        print("Could not determine psql version", file=sys.stderr)
        return 1
    major = int(match.group(1))
    if major not in SUPPORTED_MAJORS:
        print(f"Unsupported psql major {major}; PostgreSQL 17 or 18 client required", file=sys.stderr)
        return 1
    print(f"PostgreSQL client verified: {executable} ({result.stdout.strip()})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

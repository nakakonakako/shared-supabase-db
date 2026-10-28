#!/usr/bin/env python3
"""Run production Reader and schema diagnostics; distinguish drift from execution errors."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

DIAGNOSTICS = (
    "verify_production_db_reader.sql",
    "verify_migration_reader_bootstrap.sql",
    "verify_s1_08_rpc_integrity.sql",
    "verify_s1_06_ai_quota_integrity.sql",
    "verify_s1_f01_acl_integrity.sql",
)
ASSERTION_SQLSTATE = "P0001"
SQLSTATE_PATTERN = re.compile(r"\bERROR:\s+([0-9A-Z]{5}):")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--diagnostics-dir", type=Path, default=Path("supabase/diagnostics"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    mismatch = False
    for name in DIAGNOSTICS:
        try:
            result = subprocess.run(
                [
                    "psql",
                    "-X",
                    "-w",
                    "-v",
                    "ON_ERROR_STOP=1",
                    "-v",
                    "VERBOSITY=verbose",
                    "-f",
                    str(args.diagnostics_dir / name),
                ],
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            print("production DB integrity check: execution failed", file=sys.stderr)
            return 2

        if result.returncode == 0:
            continue

        sqlstates = SQLSTATE_PATTERN.findall(result.stderr)
        if sqlstates and all(state == ASSERTION_SQLSTATE for state in sqlstates):
            mismatch = True
            continue

        print("production DB integrity check: connection or execution failed", file=sys.stderr)
        return 2

    result = "MISMATCH" if mismatch else "PASS"
    args.output.write_text(f"result={result}\n", encoding="utf-8")
    print(f"production DB integrity check: {result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

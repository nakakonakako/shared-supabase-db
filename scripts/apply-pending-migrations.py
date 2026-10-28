#!/usr/bin/env python3
"""Apply only a safe pending migration suffix; treat an in-sync database as a no-op."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--migrations-dir", type=Path, default=Path("supabase/migrations"))
    parser.add_argument("--workdir", type=Path, default=Path.cwd())
    parser.add_argument("--base-ref", required=True)
    parser.add_argument("--psql", default="psql")
    parser.add_argument("--supabase", default="supabase")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="migration-apply-state-") as directory:
        output = Path(directory) / "state"
        try:
            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("check-migration-history.py")),
                    "--repo",
                    str(args.repo.resolve()),
                    "--migrations-dir",
                    str(args.migrations_dir),
                    "--base-ref",
                    args.base_ref,
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
                timeout=45,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            print("migration apply: history check failed; no migration was applied", file=sys.stderr)
            return 2

        try:
            state_lines = output.read_text(encoding="utf-8").splitlines()
        except OSError:
            print("migration apply: history check was inconclusive; no migration was applied", file=sys.stderr)
            return 2
        states = [line.removeprefix("state=") for line in state_lines if line.startswith("state=")]
        if len(states) != 1:
            print("migration apply: history check was inconclusive; no migration was applied", file=sys.stderr)
            return 2
        state = states[0]
        if state == "IN_SYNC" and result.returncode == 0:
            print("migration apply: IN_SYNC; safe no-op")
            return 0
        if state != "PENDING" or result.returncode != 1:
            print(f"migration apply: {state}; no migration was applied", file=sys.stderr)
            return 2

    database_url = os.environ.get("SUPABASE_DB_URL", "")
    if not database_url:
        print("migration apply: pending migrations require a configured writer connection", file=sys.stderr)
        return 2

    try:
        applied = subprocess.run(
            [
                args.supabase,
                "db",
                "push",
                "--workdir",
                str(args.workdir.resolve()),
                "--db-url",
                database_url,
                "--yes",
                "--skip-vault",
            ],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        print("migration apply: Supabase migration command failed; postflight is required", file=sys.stderr)
        return 2
    if applied.returncode != 0:
        print("migration apply: Supabase migration command failed; postflight is required", file=sys.stderr)
        return 2
    print("migration apply: pending migrations submitted; Reader postflight is required")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

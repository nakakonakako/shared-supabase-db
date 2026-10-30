#!/usr/bin/env python3
"""Allow only valid IN_SYNC or prefix-PENDING history for the read-only Writer probe."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path


CHECKER = Path(__file__).with_name("check-migration-history.py")
ALLOWED_RESULTS = {("IN_SYNC", 0), ("PENDING", 1)}


def read_state(path: Path) -> str | None:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    if len(lines) != 1 or not lines[0].startswith("state="):
        return None
    state = lines[0][len("state=") :]
    if state not in {"IN_SYNC", "PENDING", "REMOTE_ONLY", "ERROR"}:
        return None
    return state


def is_allowed_result(state: str, exit_code: int) -> bool:
    return (state, exit_code) in ALLOWED_RESULTS


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-ref", required=True)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="production-writer-history-") as temporary:
        state_file = Path(temporary) / "state"
        try:
            result = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--base-ref",
                    args.base_ref,
                    "--output",
                    str(state_file),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (OSError, subprocess.SubprocessError):
            print("Production Writer probe history: ERROR (checker execution failed)", file=sys.stderr)
            return 2

        state = read_state(state_file)
        if state is None:
            print("Production Writer probe history: ERROR (missing or invalid state)", file=sys.stderr)
            return 2
        if not is_allowed_result(state, result.returncode):
            print(
                f"Production Writer probe history: {state} rejected (checker exit {result.returncode})",
                file=sys.stderr,
            )
            return 2

        print(f"Production Writer probe history: {state} (checker exit {result.returncode})")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run the shared migration-history checker and summarize a Dev read-only plan."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

VERSION = re.compile(r"^\d{14}$")
RESULT_LINE = re.compile(r"^migration preflight: (IN_SYNC|PENDING|REMOTE_ONLY|ERROR)(?=[: (])", re.MULTILINE)
PENDING_LINE = re.compile(r"^migration preflight: PENDING: ([0-9,]+)$", re.MULTILINE)


def evaluate_history_result(
    returncode: int, state_output: str, checker_output: str
) -> tuple[str, list[str], bool]:
    """Accept only the expected state/exit-code pairs; PENDING is a valid plan."""
    state_lines = [line for line in state_output.splitlines() if line]
    if len(state_lines) != 1 or not state_lines[0].startswith("state="):
        return "ERROR", [], False

    state = state_lines[0].removeprefix("state=")
    result_states = RESULT_LINE.findall(checker_output)
    if result_states != [state]:
        return "ERROR", [], False

    pending: list[str] = []
    if state == "IN_SYNC" and returncode == 0:
        return state, pending, True
    if state == "PENDING" and returncode == 1:
        match = PENDING_LINE.search(checker_output)
        if match is None:
            return "ERROR", [], False
        pending = match.group(1).split(",")
        if not pending or any(not VERSION.fullmatch(version) for version in pending):
            return "ERROR", [], False
        if pending != sorted(set(pending)):
            return "ERROR", [], False
        return state, pending, True
    if state == "REMOTE_ONLY" and returncode == 1:
        return state, [], False
    if state == "ERROR" and returncode == 2:
        return state, [], False
    return "ERROR", [], False


def write_summary(path: Path | None, state: str, pending: list[str]) -> None:
    if path is None:
        return
    lines = [
        f"- Migration history: **{state}**",
        "- DB contract compatibility: not checked by this workflow; run the separate Dev consumer contract check",
    ]
    if state == "PENDING":
        lines.extend(["", "### Pending migration versions", "", *[f"- `{version}`" for version in pending]])
    lines.append("")
    with path.open("a", encoding="utf-8") as stream:
        stream.write("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--migrations-dir", type=Path, default=Path("supabase/migrations"))
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base-ref", help="also validate migration immutability against this ref")
    parser.add_argument("--summary-file", type=Path, help="append a GitHub Actions job summary")
    args = parser.parse_args()

    checker = Path(__file__).with_name("check-migration-history.py")
    try:
        with tempfile.TemporaryDirectory(prefix="dev-migration-plan-") as temp_dir:
            state_file = Path(temp_dir) / "history-state"
            command = [
                sys.executable,
                str(checker),
                "--migrations-dir",
                str(args.migrations_dir),
                "--repo",
                str(args.repo),
                "--output",
                str(state_file),
            ]
            if args.base_ref:
                command.extend(["--base-ref", args.base_ref])
            result = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            state_output = state_file.read_text(encoding="utf-8") if state_file.exists() else ""
            checker_output = result.stdout + result.stderr
    except (OSError, subprocess.SubprocessError, UnicodeError):
        state, pending, success = "ERROR", [], False
        checker_output = ""
    else:
        state, pending, success = evaluate_history_result(
            result.returncode, state_output, checker_output
        )

    if state == "IN_SYNC":
        print("Migration history: IN_SYNC")
    elif state == "PENDING":
        print("Migration history: PENDING (planned migrations; no migration was applied)")
        print("Pending versions: " + ", ".join(pending))
    elif state == "REMOTE_ONLY":
        print("Migration history: REMOTE_ONLY; refusing to treat it as a valid plan", file=sys.stderr)
    else:
        print("Migration history: ERROR; history result was unavailable or inconclusive", file=sys.stderr)

    try:
        write_summary(args.summary_file, state, pending)
    except OSError:
        print("Migration plan summary could not be written", file=sys.stderr)
        return 1
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())

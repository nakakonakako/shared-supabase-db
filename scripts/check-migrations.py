#!/usr/bin/env python3
"""Validate the migration inventory, naming convention, and pinned hashes."""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

NAME = re.compile(r"^(\d{14})_[A-Za-z0-9][A-Za-z0-9_-]*\.sql$")
INITIAL_BASELINE_COUNT = 14


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1], help="shared repository checkout")
    args = parser.parse_args()
    migrations = args.repo / "supabase" / "migrations"
    checksums = migrations / "SHA256SUMS"
    files = sorted(migrations.glob("*.sql"))
    if len(files) < INITIAL_BASELINE_COUNT:
        print(f"expected at least {INITIAL_BASELINE_COUNT} baseline migrations, found {len(files)}", file=sys.stderr)
        return 1

    versions: set[str] = set()
    for path in files:
        match = NAME.fullmatch(path.name)
        if match is None:
            print(f"invalid migration filename: {path.name}", file=sys.stderr)
            return 1
        if match.group(1) in versions:
            print(f"duplicate migration version: {match.group(1)}", file=sys.stderr)
            return 1
        versions.add(match.group(1))

    expected: dict[str, str] = {}
    try:
        for line in checksums.read_text(encoding="utf-8").splitlines():
            digest, relative = line.split(maxsplit=1)
            relative = relative.removeprefix("*")
            name = Path(relative).name
            if name in expected or not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise ValueError
            expected[name] = digest
    except (OSError, ValueError):
        print("invalid migration checksum manifest", file=sys.stderr)
        return 1

    actual_names = {path.name for path in files}
    if set(expected) != actual_names:
        print("migration checksum manifest does not match SQL files", file=sys.stderr)
        return 1
    for path in files:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected[path.name]:
            print(f"migration checksum mismatch: {path.name}", file=sys.stderr)
            return 1
    print(f"migration inventory valid ({len(files)} immutable files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Fail if a workflow run no longer targets the current origin/main tip."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

SHA = re.compile(r"^[0-9a-f]{40}$")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("expected_sha")
    args = parser.parse_args()
    if not SHA.fullmatch(args.expected_sha):
        print("main SHA check failed: invalid expected commit", file=sys.stderr)
        return 2
    try:
        result = subprocess.run(
            ["git", "ls-remote", "origin", "refs/heads/main"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        print("main SHA check failed: cannot read the remote main ref", file=sys.stderr)
        return 2
    remote_sha = result.stdout.split(maxsplit=1)[0] if result.stdout.strip() else ""
    if not SHA.fullmatch(remote_sha) or remote_sha != args.expected_sha:
        print("main SHA check failed: workflow commit is stale", file=sys.stderr)
        return 1
    print("main SHA check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

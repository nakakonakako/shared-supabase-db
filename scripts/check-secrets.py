#!/usr/bin/env python3
"""Reject common credential material in repository files without printing values."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

PATTERNS = (
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
    re.compile(r"(?i)\b(?:sb_secret_[A-Za-z0-9_-]{20,}|sb_publishable_[A-Za-z0-9_-]{20,})\b"),
    re.compile(r"(?i)(?:SUPABASE_SERVICE_ROLE_KEY|SUPABASE_DB_PASSWORD|SERVICE_ROLE_KEY)\s*[:=]\s*[\"']?(?!env\()[A-Za-z0-9._-]{16,}"),
    re.compile(r"(?i)postgres(?:ql)?://[^\s:/@]+:[^\s@]{8,}@"),
)


def main() -> int:
    result = subprocess.run(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"],
        check=True,
        capture_output=True,
    )
    violations: list[str] = []
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path:
            continue
        path = Path(raw_path.decode("utf-8", errors="surrogateescape"))
        if not path.is_file():
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeError, OSError):
            continue
        if any(pattern.search(content) for pattern in PATTERNS):
            violations.append(path.as_posix())
    if violations:
        for path in violations:
            print(f"possible credential material: {path}", file=sys.stderr)
        return 1
    print("no configured credential patterns found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

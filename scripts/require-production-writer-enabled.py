#!/usr/bin/env python3
"""Require deliberate Production Writer enablement before a pending apply."""

from __future__ import annotations

import os
import sys


def main() -> int:
    if os.environ.get("PROD_DB_WRITER_ENABLED") != "true":
        print("shared Production Writer is disabled; no migration was applied", file=sys.stderr)
        return 2
    print("shared Production Writer cutover is enabled")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

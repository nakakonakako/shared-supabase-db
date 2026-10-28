#!/usr/bin/env python3
"""Keep the shared Dev apply route disabled until the legacy writer is retired."""

from __future__ import annotations

import os
import sys


def main() -> int:
    if os.environ.get("DEV_DB_WRITER_ENABLED") != "true":
        print("shared Dev Writer is disabled; complete the documented cutover first", file=sys.stderr)
        return 2
    print("shared Dev Writer cutover is enabled")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

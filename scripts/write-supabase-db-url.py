#!/usr/bin/env python3
"""Write a percent-encoded database URL to the Actions environment without logging it."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from urllib.parse import quote


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    host = os.environ.get("PGHOST", "")
    port = os.environ.get("PGPORT", "5432")
    database = os.environ.get("PGDATABASE", "postgres")
    user = os.environ.get("PGUSER", "")
    password = os.environ.get("PGPASSWORD", "")
    sslmode = os.environ.get("PGSSLMODE", "require")
    if (
        not host
        or re.search(r"[\s/@?#:]", host)
        or not port.isdigit()
        or not 1 <= int(port) <= 65535
        or not user
        or not password
        or sslmode not in {"require", "verify-full"}
        or any(character in user or character in password for character in ("\n", "\r"))
    ):
        print("database URL setup failed: required connection settings are invalid", file=sys.stderr)
        return 2

    encoded_password = quote(password, safe="")
    url = (
        f"postgresql://{quote(user, safe='')}:{encoded_password}"
        f"@{host}:{port}/{quote(database, safe='')}?sslmode={sslmode}"
    )
    try:
        with args.output.open("a", encoding="utf-8") as output:
            output.write(f"SUPABASE_DB_URL={url}\n")
    except OSError:
        print("database URL setup failed: runner environment file is unavailable", file=sys.stderr)
        return 2
    print("database connection prepared")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

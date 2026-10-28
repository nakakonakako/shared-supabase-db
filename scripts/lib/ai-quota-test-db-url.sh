#!/usr/bin/env bash
# Accept only an explicitly opted-in, loopback, dedicated disposable database.
set -euo pipefail

if [[ "${AI_QUOTA_TEST_ALLOW_DISPOSABLE_DB:-}" != "YES" ]]; then
  echo "Set AI_QUOTA_TEST_ALLOW_DISPOSABLE_DB=YES only for a fresh disposable database." >&2
  return 1 2>/dev/null || exit 1
fi

if [[ -z "${AI_QUOTA_TEST_DATABASE_URL:-}" ]]; then
  echo "AI_QUOTA_TEST_DATABASE_URL must point to a fresh local ai_quota_test database in a dedicated disposable cluster." >&2
  return 1 2>/dev/null || exit 1
fi

python3 - <<'PY'
import os
from urllib.parse import urlsplit

parsed = urlsplit(os.environ["AI_QUOTA_TEST_DATABASE_URL"])
if parsed.scheme not in {"postgres", "postgresql"}:
    raise SystemExit("AI_QUOTA_TEST_DATABASE_URL must use a PostgreSQL URL")
if parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
    raise SystemExit("AI quota SQL tests may only connect to loopback PostgreSQL")
if parsed.path.removeprefix("/") != "ai_quota_test":
    raise SystemExit("AI quota SQL tests require the dedicated database name ai_quota_test")
PY

export AI_QUOTA_TEST_DATABASE_URL

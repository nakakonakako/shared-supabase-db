#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT}/scripts/lib/ai-quota-test-db-url.sh"
out_a="$(mktemp)"
out_b="$(mktemp)"
cleanup() { rm -f "$out_a" "$out_b"; }
trap cleanup EXIT
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -q <<'SQL'
DELETE FROM ai_quota.requests;
UPDATE ai_quota.settings SET emergency_stop=false, unknown_usage_breaker_threshold=1,
  ocr_daily_limit_per_user=1, ocr_daily_limit_global=1,
  concurrent_limit_per_user=1, concurrent_limit_global=1,
  developer_user_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' WHERE id=1;
SQL
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc "SELECT outcome FROM ai_quota.claim_ai_request('00000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'ocr')" >"$out_a" &
pid_a=$!
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc "SELECT outcome FROM ai_quota.claim_ai_request('00000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'ocr')" >"$out_b" &
pid_b=$!
wait "$pid_a"
wait "$pid_b"
if [[ "$(cat "$out_a" "$out_b" | sort | tr '\n' ' ')" != 'granted rejected ' ]]; then
  echo 'FAIL: developer concurrent claims exceeded the global concurrency limit' >&2
  exit 1
fi
[[ "$(psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc 'SELECT count(*) FROM ai_quota.requests WHERE daily_limit_exempt')" == 1 ]]
echo 'PASS: concurrent developer OCR claims obey the concurrency limit'

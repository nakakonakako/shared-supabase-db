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
  ocr_daily_limit_per_user=100, ocr_daily_limit_global=100,
  concurrent_limit_per_user=10, concurrent_limit_global=10,
  developer_user_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  developer_valid_from=clock_timestamp() - interval '1 minute',
  developer_expires_at=clock_timestamp() + interval '1 hour',
  developer_max_uses=1, developer_used_count=0 WHERE id=1;
SELECT * FROM ai_quota.claim_ai_request('00000000-0000-4000-8000-000000000001', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'ocr');
SELECT * FROM ai_quota.finish_ai_request('00000000-0000-4000-8000-000000000001', false, false, NULL, NULL, NULL);
SQL
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc "SELECT outcome FROM ai_quota.claim_ai_request('00000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'ocr')" >"$out_a" &
pid_a=$!
psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc "SELECT outcome FROM ai_quota.claim_ai_request('00000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'ocr')" >"$out_b" &
pid_b=$!
wait "$pid_a"
wait "$pid_b"
if [[ "$(cat "$out_a" "$out_b" | sort | tr '\n' ' ')" != 'granted rejected ' ]]; then
  echo 'FAIL: concurrent exception claims exceeded or failed to use the allowance' >&2
  exit 1
fi
[[ "$(psql "$AI_QUOTA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atqc 'SELECT developer_used_count FROM ai_quota.settings WHERE id=1')" == 1 ]]
echo 'PASS: concurrent exception claims consume exactly one slot'

#!/usr/bin/env bash
# Real-Postgres concurrency probe under global concurrent_limit_global = 1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/ai-quota-test-db-url.sh"

USER_A='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
USER_B='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
REQ_A='00000000-0000-4000-8000-0000000000a1'
REQ_B='00000000-0000-4000-8000-0000000000b2'
UNK_1='00000000-0000-4000-8000-0000000000c1'
UNK_2='00000000-0000-4000-8000-0000000000c2'
UNK_3='00000000-0000-4000-8000-0000000000c3'
BRK_A='00000000-0000-4000-8000-0000000000d1'
BRK_B='00000000-0000-4000-8000-0000000000d2'

cleanup() {
  psql "$AI_QUOTA_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
DELETE FROM ai_quota.requests WHERE request_id IN (
  '${REQ_A}'::uuid, '${REQ_B}'::uuid,
  '${UNK_1}'::uuid, '${UNK_2}'::uuid, '${UNK_3}'::uuid,
  '${BRK_A}'::uuid, '${BRK_B}'::uuid
);
UPDATE ai_quota.settings SET
  concurrent_limit_per_user = 1,
  concurrent_limit_global = 1,
  ocr_daily_limit_per_user = 100,
  ocr_daily_limit_global = 100,
  unknown_usage_breaker_threshold = 3,
  emergency_stop = false
WHERE id = 1;
SQL
}
trap cleanup EXIT

psql "$AI_QUOTA_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
UPDATE ai_quota.settings SET
  concurrent_limit_per_user = 1,
  concurrent_limit_global = 1,
  ocr_daily_limit_per_user = 100,
  ocr_daily_limit_global = 100,
  unknown_usage_breaker_threshold = 3,
  emergency_stop = false
WHERE id = 1;
SQL

OUT_A_FILE="$(mktemp)"
OUT_B_FILE="$(mktemp)"

(
  psql "$AI_QUOTA_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -t -A -c \
    "SELECT outcome FROM ai_quota.claim_ai_request('${REQ_A}'::uuid, '${USER_A}'::uuid, 'ocr');" \
    >"$OUT_A_FILE"
) &
PID_A=$!

(
  psql "$AI_QUOTA_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -t -A -c \
    "SELECT outcome FROM ai_quota.claim_ai_request('${REQ_B}'::uuid, '${USER_B}'::uuid, 'ocr');" \
    >"$OUT_B_FILE"
) &
PID_B=$!

wait "$PID_A"
wait "$PID_B"

OUT_A="$(tr -d '[:space:]' <"$OUT_A_FILE")"
OUT_B="$(tr -d '[:space:]' <"$OUT_B_FILE")"
rm -f "$OUT_A_FILE" "$OUT_B_FILE"

GRANTED=0
REJECTED=0
[[ "$OUT_A" == "granted" ]] && GRANTED=$((GRANTED + 1))
[[ "$OUT_B" == "granted" ]] && GRANTED=$((GRANTED + 1))
[[ "$OUT_A" == "rejected" ]] && REJECTED=$((REJECTED + 1))
[[ "$OUT_B" == "rejected" ]] && REJECTED=$((REJECTED + 1))

if [[ "$GRANTED" -ne 1 || "$REJECTED" -ne 1 ]]; then
  echo "Unexpected concurrent claim outcomes: A=${OUT_A} B=${OUT_B}" >&2
  exit 1
fi
echo "PASS: concurrent claim probe (one granted, one rejected: A=${OUT_A} B=${OUT_B})"

psql "$AI_QUOTA_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
DELETE FROM ai_quota.requests WHERE request_id IN ('${REQ_A}'::uuid, '${REQ_B}'::uuid);
UPDATE ai_quota.settings SET
  concurrent_limit_per_user = 5,
  concurrent_limit_global = 5,
  ocr_daily_limit_per_user = 100,
  ocr_daily_limit_global = 100,
  unknown_usage_breaker_threshold = 3,
  monthly_cost_cap_micro_jpy = 800000000,
  emergency_stop = false
WHERE id = 1;
INSERT INTO ai_quota.requests (
  request_id, user_id, kind, started_at, jst_day, jst_month, status,
  lease_expires_at, usage_available, finished_at, unknown_at,
  snapshot_model_id, snapshot_input_price_usd_per_million,
  snapshot_output_price_usd_per_million, snapshot_thought_price_usd_per_million,
  snapshot_fx_jpy_per_usd
)
SELECT request_id::uuid, '${USER_A}'::uuid, 'ocr', pg_catalog.clock_timestamp(),
  (pg_catalog.clock_timestamp() AT TIME ZONE 'Asia/Tokyo')::date,
  pg_catalog.date_trunc('month', pg_catalog.clock_timestamp() AT TIME ZONE 'Asia/Tokyo')::date,
  'unknown_usage', pg_catalog.clock_timestamp(), false, pg_catalog.clock_timestamp(),
  pg_catalog.clock_timestamp(),
  'gemini-3-flash-preview', 500000, 3000000, 3000000, 200
FROM (VALUES ('${UNK_1}'), ('${UNK_2}'), ('${UNK_3}')) AS seeded(request_id);
SQL

OUT_A_FILE="$(mktemp)"
OUT_B_FILE="$(mktemp)"
(
  psql "$AI_QUOTA_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -t -A -c \
    "SELECT reject_reason FROM ai_quota.claim_ai_request('${BRK_A}'::uuid, '${USER_A}'::uuid, 'ocr');" \
    >"$OUT_A_FILE"
) &
PID_A=$!
(
  psql "$AI_QUOTA_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -t -A -c \
    "SELECT reject_reason FROM ai_quota.claim_ai_request('${BRK_B}'::uuid, '${USER_B}'::uuid, 'ocr');" \
    >"$OUT_B_FILE"
) &
PID_B=$!
wait "$PID_A"
wait "$PID_B"
OUT_A="$(tr -d '[:space:]' <"$OUT_A_FILE")"
OUT_B="$(tr -d '[:space:]' <"$OUT_B_FILE")"
rm -f "$OUT_A_FILE" "$OUT_B_FILE"

if [[ "$OUT_A" == "unknown_usage_breaker" && "$OUT_B" == "unknown_usage_breaker" ]]; then
  echo "PASS: concurrent claims stay stopped after three same-day unknown rows (A=${OUT_A} B=${OUT_B})"
  exit 0
fi

echo "Unexpected concurrent breaker outcomes: A=${OUT_A} B=${OUT_B}" >&2
exit 1

-- Isolated SQL tests for ai_quota RPCs. Run via scripts/run-ai-quota-sql-tests.sh
\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE test_assertions (
  name text primary key,
  passed boolean not null,
  detail text not null
);

CREATE OR REPLACE FUNCTION pg_temp.test_assert(p_name text, p_ok boolean, p_detail text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO test_assertions (name, passed, detail)
  VALUES (p_name, coalesce(p_ok, false), p_detail);
END;
$$;

DO $tests$
DECLARE
  u1 uuid := '11111111-1111-4111-8111-111111111111';
  u2 uuid := '22222222-2222-4222-8222-222222222222';
  u3 uuid := '33333333-3333-4333-8333-333333333333';
  r_id uuid;
  r_outcome text;
  r_reason text;
  r_cost bigint;
  r_status text;
  v_day date;
  v_month date;
  v_lease timestamptz;
  v_unknown_at timestamptz;
  v_daily bigint;
  v_unknown_rows bigint;
  v_prev_jst_day date;
  i integer;
BEGIN
  SELECT jst_day, jst_month INTO v_day, v_month
  FROM ai_quota._jst_bounds(pg_catalog.now());

  PERFORM pg_temp.test_assert(
    'jst_bounds_utc_boundary',
    (SELECT jst_day FROM ai_quota._jst_bounds(timestamptz '2026-10-14 14:59:59+00'))
      = date '2026-10-14'
    AND (SELECT jst_day FROM ai_quota._jst_bounds(timestamptz '2026-10-14 15:00:00+00'))
      = date '2026-10-15',
    'JST day rollover at 15:00 UTC'
  );
  PERFORM pg_temp.test_assert(
    'jst_month_boundary',
    (SELECT jst_month FROM ai_quota._jst_bounds(timestamptz '2026-10-31 14:59:59+00'))
      = date '2026-10-01'
    AND (SELECT jst_month FROM ai_quota._jst_bounds(timestamptz '2026-10-31 15:00:00+00'))
      = date '2026-11-01',
    'JST month rollover at 15:00 UTC'
  );

  PERFORM pg_temp.test_assert(
    'default_settings',
    (SELECT ocr_daily_limit_per_user FROM ai_quota.settings WHERE id = 1) = 20
    AND (SELECT monthly_cost_cap_micro_jpy FROM ai_quota.settings WHERE id = 1) = 800000000
    AND (SELECT unknown_usage_breaker_threshold FROM ai_quota.settings WHERE id = 1) = 3
    AND (SELECT model_id FROM ai_quota.settings WHERE id = 1) = 'gemini-3-flash-preview',
    'singleton defaults'
  );

  r_id := gen_random_uuid();
  SELECT outcome INTO r_outcome FROM ai_quota.claim_ai_request(r_id, u1, 'ocr');
  PERFORM pg_temp.test_assert('basic_claim', r_outcome = 'granted', r_outcome);

  UPDATE ai_quota.settings SET
    input_price_usd_per_million = 9000000,
    output_price_usd_per_million = 9000000,
    thought_price_usd_per_million = 9000000,
    fx_jpy_per_usd = 400
  WHERE id = 1;

  SELECT outcome INTO r_outcome FROM ai_quota.claim_ai_request(r_id, u1, 'ocr');
  PERFORM pg_temp.test_assert('claim_idempotent', r_outcome = 'idempotent', r_outcome);

  SELECT outcome INTO r_outcome FROM ai_quota.claim_ai_request(r_id, u2, 'ocr');
  PERFORM pg_temp.test_assert(
    'claim_idempotency_conflict',
    r_outcome = 'rejected',
    r_outcome
  );

  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.finish_ai_request(r_id, true, true, 1000, 2000, 3000);
  PERFORM pg_temp.test_assert('finish_measured', r_outcome = 'finished', r_outcome);

  SELECT estimated_cost_micro_jpy INTO r_cost FROM ai_quota.requests WHERE request_id = r_id;
  PERFORM pg_temp.test_assert(
    'finish_cost_with_thought',
    r_cost = 3100000,
    format('expected 3100000 micro-JPY, got %s', r_cost)
  );
  PERFORM pg_temp.test_assert(
    'claim_price_snapshot_used_for_finish',
    (SELECT snapshot_input_price_usd_per_million = 500000
        AND snapshot_output_price_usd_per_million = 3000000
        AND snapshot_fx_jpy_per_usd = 200
        AND estimated_cost_micro_jpy = 3100000
       FROM ai_quota.requests WHERE request_id = r_id),
    'finish uses claim-time prices'
  );
  UPDATE ai_quota.settings SET
    input_price_usd_per_million = 500000,
    output_price_usd_per_million = 3000000,
    thought_price_usd_per_million = 3000000,
    fx_jpy_per_usd = 200
  WHERE id = 1;

  SELECT outcome INTO r_outcome
  FROM ai_quota.finish_ai_request(r_id, true, true, 1000, 2000, 3000);
  PERFORM pg_temp.test_assert('finish_idempotent', r_outcome = 'idempotent', r_outcome);

  SELECT outcome INTO r_outcome
  FROM ai_quota.finish_ai_request(r_id, true, true, 1, 2, 3);
  PERFORM pg_temp.test_assert(
    'finish_conflict',
    r_outcome = 'rejected',
    r_outcome
  );

  r_id := gen_random_uuid();
  PERFORM pg_temp.test_assert(
    'failed_usage_claim',
    (SELECT outcome FROM ai_quota.claim_ai_request(r_id, u1, 'csv_estimate')) = 'granted',
    'claim for known-usage failure'
  );
  PERFORM ai_quota.finish_ai_request(r_id, false, true, 1, 2, 0);
  PERFORM pg_temp.test_assert(
    'failed_status_keeps_measured_cost',
    (SELECT status = 'failed' AND estimated_cost_micro_jpy > 0
       FROM ai_quota.requests WHERE request_id = r_id),
    'known-usage API error is recorded as failed and billed'
  );

  r_id := gen_random_uuid();
  SELECT outcome INTO r_outcome FROM ai_quota.claim_ai_request(r_id, u1, 'chat');
  PERFORM pg_temp.test_assert('second_claim', r_outcome = 'granted', r_outcome);
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.finish_ai_request(r_id, false, false, null, null, null);
  PERFORM pg_temp.test_assert(
    'unknown_usage_finish',
    r_outcome = 'finished'
    AND (SELECT status = 'unknown_usage'
         AND estimated_cost_micro_jpy IS NULL
         AND unknown_at IS NOT NULL
         AND unknown_at = finished_at
       FROM ai_quota.requests WHERE request_id = r_id),
    r_outcome
  );

  -- Two unresolved unknowns on the same JST day still allow a claim.
  -- The claim that is later finished as the third unknown is itself allowed,
  -- because the breaker counts rows already recorded as unknown_usage.
  r_id := gen_random_uuid();
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(r_id, u2, 'ocr');
  PERFORM pg_temp.test_assert(
    'unknown_one_allows_claim',
    r_outcome = 'granted',
    coalesce(r_reason, r_outcome)
  );
  PERFORM ai_quota.finish_ai_request(r_id, false, false, null, null, null);

  r_id := gen_random_uuid();
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(r_id, u2, 'chat');
  PERFORM pg_temp.test_assert(
    'unknown_two_allows_claim',
    r_outcome = 'granted',
    coalesce(r_reason, r_outcome)
  );
  PERFORM ai_quota.finish_ai_request(r_id, false, false, null, null, null);

  SELECT pg_catalog.count(*) INTO v_unknown_rows
  FROM ai_quota.requests
  WHERE status = 'unknown_usage';
  PERFORM pg_temp.test_assert(
    'unknown_three_recorded',
    v_unknown_rows = 3
    AND (SELECT ai_quota._unknown_usage_count(v_day)) = 3,
    format('unknown rows=%s', v_unknown_rows)
  );

  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u2, 'ocr');
  PERFORM pg_temp.test_assert(
    'unknown_usage_breaker',
    r_outcome = 'rejected' AND r_reason = 'unknown_usage_breaker',
    coalesce(r_reason, r_outcome)
  );

  -- Moving the accounting month does not clear a same-day breaker.
  UPDATE ai_quota.requests
  SET jst_month = (pg_catalog.date_trunc('month', v_day::timestamp) - interval '1 month')::date
  WHERE status = 'unknown_usage';
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u1, 'ocr');
  PERFORM pg_temp.test_assert(
    'unknown_usage_same_jst_day_ignores_month',
    r_outcome = 'rejected' AND r_reason = 'unknown_usage_breaker',
    coalesce(r_reason, r_outcome)
  );

  SELECT c.user_count INTO v_daily
  FROM ai_quota._count_daily(u1, 'chat', v_day) AS c;
  v_prev_jst_day := v_day - 1;
  UPDATE ai_quota.requests
  SET unknown_at = (v_prev_jst_day::timestamp + interval '12 hours') AT TIME ZONE 'Asia/Tokyo'
  WHERE status = 'unknown_usage';

  PERFORM pg_temp.test_assert(
    'unknown_history_retained_and_daily_consumption_kept',
    (SELECT pg_catalog.count(*) FROM ai_quota.requests WHERE status = 'unknown_usage') = 3
    AND (SELECT pg_catalog.bool_and(jst_day = v_day) FROM ai_quota.requests WHERE status = 'unknown_usage')
    AND (SELECT c.user_count FROM ai_quota._count_daily(u1, 'chat', v_day) AS c) = v_daily
    AND v_daily >= 1
    AND (SELECT ai_quota._unknown_usage_count(v_day)) = 0
    AND (SELECT ai_quota._unknown_usage_count(v_prev_jst_day)) = 3,
    format('daily user chat count=%s', v_daily)
  );

  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u3, 'ocr');
  PERFORM pg_temp.test_assert(
    'unknown_breaker_releases_next_jst_day',
    r_outcome = 'granted',
    coalesce(r_reason, r_outcome)
  );
  PERFORM pg_temp.test_assert(
    'unknown_history_not_deleted_on_release',
    (SELECT pg_catalog.count(*) FROM ai_quota.requests WHERE status = 'unknown_usage') = 3,
    'previous unknown rows remain'
  );

  SELECT request_id, unknown_at INTO r_id, v_unknown_at
  FROM ai_quota.requests
  WHERE status = 'unknown_usage'
  ORDER BY request_id
  LIMIT 1;
  SELECT outcome, status INTO r_outcome, r_status
  FROM ai_quota.finish_ai_request(r_id, true, true, 4, 5, 6);
  PERFORM pg_temp.test_assert(
    'late_finish_releases_breaker_and_keeps_unknown_at',
    r_outcome = 'finished'
    AND r_status = 'succeeded'
    AND (SELECT status = 'succeeded' AND unknown_at = v_unknown_at AND unknown_at IS NOT NULL
         FROM ai_quota.requests WHERE request_id = r_id)
    AND (SELECT ai_quota._unknown_usage_count(v_prev_jst_day)) = 2
    AND (SELECT outcome FROM ai_quota.claim_ai_request(gen_random_uuid(), u1, 'chat')) = 'granted',
    coalesce(r_outcome, 'no outcome')
  );

  DELETE FROM ai_quota.requests;

  -- A lease that expired on an earlier JST day is unknown history, not today's outage.
  v_lease := pg_catalog.clock_timestamp() - interval '3 days';
  v_prev_jst_day := (v_lease AT TIME ZONE 'Asia/Tokyo')::date;
  INSERT INTO ai_quota.requests (
    request_id, user_id, kind, started_at, jst_day, jst_month, status, lease_expires_at,
    snapshot_model_id, snapshot_input_price_usd_per_million,
    snapshot_output_price_usd_per_million, snapshot_thought_price_usd_per_million,
    snapshot_fx_jpy_per_usd
  ) VALUES (
    gen_random_uuid(), u1, 'ocr', v_lease, v_prev_jst_day,
    pg_catalog.date_trunc('month', v_lease AT TIME ZONE 'Asia/Tokyo')::date,
    'active', v_lease,
    'gemini-3-flash-preview', 500000, 3000000, 3000000, 200
  );
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u2, 'ocr');
  PERFORM pg_temp.test_assert(
    'stale_expired_lease_does_not_trip_today',
    r_outcome = 'granted'
    AND (SELECT ai_quota._unknown_usage_count(v_day)) = 0
    AND EXISTS (
      SELECT 1 FROM ai_quota.requests
      WHERE user_id = u1
        AND status = 'unknown_usage'
        AND unknown_at = v_lease
        AND jst_day = v_prev_jst_day
    )
    AND (SELECT c.user_count FROM ai_quota._count_daily(u1, 'ocr', v_prev_jst_day) AS c) = 1,
    coalesce(r_reason, r_outcome)
  );

  DELETE FROM ai_quota.requests;
  FOR i IN 1..2 LOOP
    v_lease := pg_catalog.clock_timestamp() - interval '1 second';
    INSERT INTO ai_quota.requests (
      request_id, user_id, kind, started_at, jst_day, jst_month, status, lease_expires_at,
      snapshot_model_id, snapshot_input_price_usd_per_million,
      snapshot_output_price_usd_per_million, snapshot_thought_price_usd_per_million,
      snapshot_fx_jpy_per_usd
    ) VALUES (
      gen_random_uuid(), u1, 'chat', v_lease, v_day, v_month,
      'active', v_lease,
      'gemini-3-flash-preview', 500000, 3000000, 3000000, 200
    );
  END LOOP;
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u2, 'chat');
  PERFORM pg_temp.test_assert(
    'two_same_day_expired_leases_allow_claim',
    r_outcome = 'granted'
    AND (SELECT pg_catalog.count(*) FROM ai_quota.requests WHERE status = 'unknown_usage') = 2
    AND NOT EXISTS (
      SELECT 1 FROM ai_quota.requests
      WHERE status = 'unknown_usage'
        AND unknown_at IS DISTINCT FROM lease_expires_at
    ),
    coalesce(r_reason, r_outcome)
  );

  DELETE FROM ai_quota.requests;
  FOR i IN 1..3 LOOP
    v_lease := pg_catalog.clock_timestamp() - interval '1 second';
    INSERT INTO ai_quota.requests (
      request_id, user_id, kind, started_at, jst_day, jst_month, status, lease_expires_at,
      snapshot_model_id, snapshot_input_price_usd_per_million,
      snapshot_output_price_usd_per_million, snapshot_thought_price_usd_per_million,
      snapshot_fx_jpy_per_usd
    ) VALUES (
      gen_random_uuid(), u1, 'chat', v_lease, v_day, v_month,
      'active', v_lease,
      'gemini-3-flash-preview', 500000, 3000000, 3000000, 200
    );
  END LOOP;
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u2, 'chat');
  PERFORM pg_temp.test_assert(
    'three_same_day_expired_leases_trip_breaker',
    r_outcome = 'rejected'
    AND r_reason = 'unknown_usage_breaker'
    AND (SELECT pg_catalog.count(*) FROM ai_quota.requests WHERE status = 'unknown_usage') = 3
    AND (SELECT pg_catalog.count(*) FROM ai_quota.requests WHERE status = 'active') = 0
    AND NOT EXISTS (
      SELECT 1 FROM ai_quota.requests
      WHERE status = 'unknown_usage'
        AND unknown_at IS DISTINCT FROM lease_expires_at
    ),
    coalesce(r_reason, r_outcome)
  );

  DELETE FROM ai_quota.requests;
  UPDATE ai_quota.settings SET emergency_stop = true WHERE id = 1;
  r_id := gen_random_uuid();
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(r_id, u2, 'ocr');
  PERFORM pg_temp.test_assert(
    'emergency_stop',
    r_outcome = 'rejected' AND r_reason = 'emergency_stop',
    coalesce(r_reason, r_outcome)
  );
  UPDATE ai_quota.settings SET emergency_stop = false WHERE id = 1;

  UPDATE ai_quota.settings
  SET ocr_daily_limit_per_user = 1,
      ocr_daily_limit_global = 100,
      chat_daily_limit_per_user = 100,
      chat_daily_limit_global = 100
  WHERE id = 1;

  DELETE FROM ai_quota.requests WHERE user_id = u3;

  r_id := gen_random_uuid();
  PERFORM pg_temp.test_assert(
    'daily_limit_user',
    (SELECT outcome FROM ai_quota.claim_ai_request(r_id, u3, 'ocr')) = 'granted',
    'first ocr claim for u3'
  );
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u3, 'ocr');
  PERFORM pg_temp.test_assert(
    'daily_limit_user_block',
    r_outcome = 'rejected' AND r_reason = 'daily_limit_user',
    coalesce(r_reason, r_outcome)
  );

  UPDATE ai_quota.settings
  SET csv_estimate_daily_limit_per_user = 1,
      csv_estimate_daily_limit_global = 100,
      concurrent_limit_per_user = 5,
      concurrent_limit_global = 5
  WHERE id = 1;
  PERFORM pg_temp.test_assert(
    'csv_estimate_daily_limit_first',
    (SELECT outcome FROM ai_quota.claim_ai_request(gen_random_uuid(), u3, 'csv_estimate')) = 'granted',
    'first csv estimate claim'
  );
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u3, 'csv_estimate');
  PERFORM pg_temp.test_assert(
    'csv_estimate_daily_limit_block',
    r_outcome = 'rejected' AND r_reason = 'daily_limit_user',
    coalesce(r_reason, r_outcome)
  );

  UPDATE ai_quota.settings SET
    csv_estimate_daily_limit_per_user = 5,
    csv_estimate_daily_limit_global = 1
  WHERE id = 1;
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u2, 'csv_estimate');
  PERFORM pg_temp.test_assert(
    'csv_estimate_daily_limit_global_block',
    r_outcome = 'rejected' AND r_reason = 'daily_limit_global',
    coalesce(r_reason, r_outcome)
  );

  UPDATE ai_quota.settings SET
    chat_daily_limit_per_user = 1,
    chat_daily_limit_global = 100
  WHERE id = 1;
  PERFORM pg_temp.test_assert(
    'chat_daily_limit_first',
    (SELECT outcome FROM ai_quota.claim_ai_request(gen_random_uuid(), u3, 'chat')) = 'granted',
    'first chat claim'
  );
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u3, 'chat');
  PERFORM pg_temp.test_assert(
    'chat_daily_limit_user_block',
    r_outcome = 'rejected' AND r_reason = 'daily_limit_user',
    coalesce(r_reason, r_outcome)
  );
  UPDATE ai_quota.settings SET
    chat_daily_limit_per_user = 5,
    chat_daily_limit_global = 1
  WHERE id = 1;
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u2, 'chat');
  PERFORM pg_temp.test_assert(
    'chat_daily_limit_global_block',
    r_outcome = 'rejected' AND r_reason = 'daily_limit_global',
    coalesce(r_reason, r_outcome)
  );

  UPDATE ai_quota.settings
  SET ocr_daily_limit_per_user = 50,
      csv_estimate_daily_limit_per_user = 5,
      csv_estimate_daily_limit_global = 20,
      chat_daily_limit_per_user = 20,
      chat_daily_limit_global = 50,
      ocr_daily_limit_global = 2,
      concurrent_limit_per_user = 5,
      concurrent_limit_global = 5
  WHERE id = 1;

  DELETE FROM ai_quota.requests;

  r_id := gen_random_uuid();
  PERFORM pg_temp.test_assert(
    'global_daily_first',
    (SELECT outcome FROM ai_quota.claim_ai_request(r_id, u1, 'ocr')) = 'granted',
    'global daily 1'
  );
  r_id := gen_random_uuid();
  PERFORM pg_temp.test_assert(
    'global_daily_second',
    (SELECT outcome FROM ai_quota.claim_ai_request(r_id, u2, 'ocr')) = 'granted',
    'global daily 2'
  );
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u3, 'ocr');
  PERFORM pg_temp.test_assert(
    'daily_limit_global_block',
    r_outcome = 'rejected' AND r_reason = 'daily_limit_global',
    coalesce(r_reason, r_outcome)
  );

  DELETE FROM ai_quota.requests;
  UPDATE ai_quota.settings
  SET ocr_daily_limit_global = 100,
      concurrent_limit_per_user = 1,
      concurrent_limit_global = 5
  WHERE id = 1;

  r_id := gen_random_uuid();
  PERFORM pg_temp.test_assert(
    'concurrency_hold',
    (SELECT outcome FROM ai_quota.claim_ai_request(r_id, u1, 'chat')) = 'granted',
    'active lease'
  );
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u1, 'chat');
  PERFORM pg_temp.test_assert(
    'concurrency_user_block',
    r_outcome = 'rejected' AND r_reason = 'concurrency_user',
    coalesce(r_reason, r_outcome)
  );

  UPDATE ai_quota.requests
  SET lease_expires_at = pg_catalog.clock_timestamp() - interval '1 second'
  WHERE user_id = u1 AND status = 'active'
  RETURNING lease_expires_at INTO v_lease;

  SELECT outcome INTO r_outcome
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u1, 'chat');
  PERFORM pg_temp.test_assert(
    'expired_lease_records_unknown_and_releases_concurrency',
    r_outcome = 'granted'
    AND EXISTS (
      SELECT 1 FROM ai_quota.requests
      WHERE user_id = u1
        AND status = 'unknown_usage'
        AND unknown_at = v_lease
    ),
    coalesce(r_outcome, 'no outcome')
  );

  SELECT request_id INTO r_id
  FROM ai_quota.requests
  WHERE user_id = u1 AND status = 'active'
  ORDER BY started_at DESC
  LIMIT 1;

  PERFORM pg_temp.test_assert(
    'renew_active',
    (SELECT outcome FROM ai_quota.renew_ai_lease(r_id)) = 'renewed',
    'renew'
  );

  UPDATE ai_quota.requests
  SET lease_expires_at = pg_catalog.now() - interval '1 minute'
  WHERE request_id = r_id;

  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.renew_ai_lease(r_id);
  PERFORM pg_temp.test_assert(
    'renew_after_expiry',
    r_outcome = 'rejected' AND r_reason = 'lease_expired',
    coalesce(r_reason, r_outcome)
  );

  SELECT outcome INTO r_outcome
  FROM ai_quota.finish_ai_request(r_id, false, false, null, null, null);
  PERFORM pg_temp.test_assert('finish_unknown_first', r_outcome = 'finished', r_outcome);

  SELECT outcome INTO r_outcome
  FROM ai_quota.finish_ai_request(r_id, false, false, null, null, null);
  PERFORM pg_temp.test_assert('finish_unknown_idempotent', r_outcome = 'idempotent', r_outcome);

  SELECT outcome INTO r_outcome
  FROM ai_quota.finish_ai_request(r_id, true, true, 10, 5, 2);
  PERFORM pg_temp.test_assert('late_finish_settles_unknown', r_outcome = 'finished', r_outcome);

  r_id := gen_random_uuid();
  PERFORM pg_temp.test_assert(
    'late_finish_claim',
    (SELECT outcome FROM ai_quota.claim_ai_request(r_id, u2, 'csv_estimate')) = 'granted',
    'csv claim'
  );
  UPDATE ai_quota.requests
  SET lease_expires_at = pg_catalog.now() - interval '5 minutes'
  WHERE request_id = r_id;
  SELECT outcome INTO r_outcome
  FROM ai_quota.finish_ai_request(r_id, true, true, 10, 0, 0);
  PERFORM pg_temp.test_assert('late_finish', r_outcome = 'finished', r_outcome);

  UPDATE ai_quota.settings
  SET monthly_cost_cap_micro_jpy = 800000000,
      ocr_daily_limit_per_user = 100,
      ocr_daily_limit_global = 100,
      concurrent_limit_per_user = 10,
      concurrent_limit_global = 10
  WHERE id = 1;

  DELETE FROM ai_quota.requests;

  r_id := gen_random_uuid();
  PERFORM pg_temp.test_assert(
    'month_cap_first',
    (SELECT outcome FROM ai_quota.claim_ai_request(r_id, u1, 'ocr')) = 'granted',
    'claim under cap'
  );
  PERFORM pg_temp.test_assert(
    'month_cap_finish',
    (SELECT outcome FROM ai_quota.finish_ai_request(r_id, true, true, 8000000, 0, 0)) = 'finished',
    'finish to consume cap'
  );
  PERFORM pg_temp.test_assert(
    'monthly_cost_cap_exact_value',
    (SELECT estimated_cost_micro_jpy = 800000000
       FROM ai_quota.requests WHERE request_id = r_id),
    'measured usage reaches exactly 800 JPY'
  );
  SELECT outcome, reject_reason INTO r_outcome, r_reason
  FROM ai_quota.claim_ai_request(gen_random_uuid(), u2, 'ocr');
  PERFORM pg_temp.test_assert(
    'monthly_cost_cap_block',
    r_outcome = 'rejected' AND r_reason = 'monthly_cost_cap',
    coalesce(r_reason, r_outcome)
  );

  PERFORM pg_temp.test_assert(
    'snapshot_immutable',
    (SELECT snapshot_model_id FROM ai_quota.requests WHERE request_id = r_id)
      = 'gemini-3-flash-preview',
    'snapshot stored at claim'
  );
  UPDATE ai_quota.settings SET model_id = 'other-model' WHERE id = 1;
  PERFORM pg_temp.test_assert(
    'snapshot_not_updated',
    (SELECT snapshot_model_id FROM ai_quota.requests WHERE request_id = r_id)
      = 'gemini-3-flash-preview',
    'snapshot unchanged after settings change'
  );

  PERFORM pg_temp.test_assert(
    'backend_no_table_select',
    pg_catalog.has_table_privilege('ai_quota_backend', 'ai_quota.settings', 'SELECT') = false
    AND pg_catalog.has_table_privilege('ai_quota_backend', 'ai_quota.requests', 'SELECT') = false,
    'direct table privileges revoked'
  );

  PERFORM pg_temp.test_assert(
    'backend_rpc_execute',
    pg_catalog.has_function_privilege(
      'ai_quota_backend',
      'ai_quota.claim_ai_request(uuid,uuid,text)',
      'EXECUTE'
    ),
    'claim execute grant'
  );

  PERFORM pg_temp.test_assert(
    'data_api_rpc_denied',
    NOT pg_catalog.has_function_privilege('anon', 'ai_quota.claim_ai_request(uuid,uuid,text)', 'EXECUTE')
    AND NOT pg_catalog.has_function_privilege('authenticated', 'ai_quota.claim_ai_request(uuid,uuid,text)', 'EXECUTE')
    AND NOT pg_catalog.has_function_privilege('service_role', 'ai_quota.claim_ai_request(uuid,uuid,text)', 'EXECUTE'),
    'all Data API roles must lack execute'
  );
END;
$tests$;

DO $report$
DECLARE
  v_count integer;
  v_total integer;
  r record;
BEGIN
  SELECT pg_catalog.count(*) FILTER (WHERE NOT passed), pg_catalog.count(*)
    INTO v_count, v_total
  FROM test_assertions;
  IF v_count > 0 THEN
    FOR r IN SELECT name, detail FROM test_assertions WHERE NOT passed ORDER BY name LOOP
      RAISE NOTICE 'FAIL: % — %', r.name, r.detail;
    END LOOP;
    RAISE EXCEPTION 'ai_quota SQL tests failed (% of % assertions)', v_count, v_total;
  END IF;
  RAISE NOTICE 'PASS: ai_quota SQL tests (% assertions checked)', v_total;
END;
$report$;

ROLLBACK;

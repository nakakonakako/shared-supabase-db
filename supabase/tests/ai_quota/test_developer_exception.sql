\set ON_ERROR_STOP on
BEGIN;
DO $test$
DECLARE
  dev uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  other_user uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  r record;
  i integer;
  request uuid;
BEGIN
  DELETE FROM ai_quota.requests;
  UPDATE ai_quota.settings SET emergency_stop = false,
    unknown_usage_breaker_threshold = 1, ocr_daily_limit_per_user = 100,
    ocr_daily_limit_global = 100, concurrent_limit_per_user = 10,
    concurrent_limit_global = 10, monthly_cost_cap_micro_jpy = 800000000,
    developer_user_id = dev, developer_valid_from = clock_timestamp() - interval '1 minute',
    developer_expires_at = clock_timestamp() + interval '1 hour',
    developer_max_uses = 2, developer_used_count = 0 WHERE id = 1;

  -- Normal operation must not consume the exceptional allowance.
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.outcome <> 'granted' OR (SELECT developer_used_count FROM ai_quota.settings WHERE id = 1) <> 0 THEN
    RAISE EXCEPTION 'normal claim consumed exception';
  END IF;
  PERFORM ai_quota.finish_ai_request(r.request_id, true, true, 1, 1, 0);
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), other_user, 'ocr');
  PERFORM ai_quota.finish_ai_request(r.request_id, false, false, NULL, NULL, NULL);

  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), other_user, 'ocr');
  IF r.reject_reason <> 'unknown_usage_breaker' THEN RAISE EXCEPTION 'other user bypassed breaker'; END IF;

  UPDATE ai_quota.settings SET emergency_stop = true WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason <> 'emergency_stop' THEN RAISE EXCEPTION 'emergency stop bypassed'; END IF;
  UPDATE ai_quota.settings SET emergency_stop = false, ocr_daily_limit_per_user = 1 WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason <> 'daily_limit_user' THEN RAISE EXCEPTION 'daily limit bypassed'; END IF;
  UPDATE ai_quota.settings SET ocr_daily_limit_per_user = 100, ocr_daily_limit_global = 2 WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason <> 'daily_limit_global' THEN RAISE EXCEPTION 'global daily limit bypassed'; END IF;
  UPDATE ai_quota.settings SET ocr_daily_limit_global = 100, monthly_cost_cap_micro_jpy = 1 WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason <> 'monthly_cost_cap' THEN RAISE EXCEPTION 'monthly limit bypassed'; END IF;
  UPDATE ai_quota.settings SET monthly_cost_cap_micro_jpy = 800000000 WHERE id = 1;
  IF (SELECT developer_used_count FROM ai_quota.settings WHERE id = 1) <> 0 THEN RAISE EXCEPTION 'rejections consumed allowance'; END IF;

  request := gen_random_uuid();
  SELECT * INTO r FROM ai_quota.claim_ai_request(request, dev, 'ocr');
  IF r.outcome <> 'granted' THEN RAISE EXCEPTION 'eligible developer rejected'; END IF;
  SELECT * INTO r FROM ai_quota.claim_ai_request(request, dev, 'ocr');
  IF r.outcome <> 'idempotent' OR (SELECT developer_used_count FROM ai_quota.settings WHERE id = 1) <> 1 THEN RAISE EXCEPTION 'idempotency consumed allowance'; END IF;
  UPDATE ai_quota.settings SET concurrent_limit_per_user = 1 WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason <> 'concurrency_user' OR (SELECT developer_used_count FROM ai_quota.settings WHERE id = 1) <> 1 THEN RAISE EXCEPTION 'concurrency limit bypassed'; END IF;
  UPDATE ai_quota.settings SET concurrent_limit_per_user = 10, concurrent_limit_global = 1 WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason <> 'concurrency_global' THEN RAISE EXCEPTION 'global concurrency limit bypassed'; END IF;
  UPDATE ai_quota.settings SET concurrent_limit_global = 10 WHERE id = 1;
  PERFORM ai_quota.finish_ai_request(request, false, false, NULL, NULL, NULL);
  IF NOT EXISTS (SELECT 1 FROM ai_quota.requests WHERE request_id = request AND status = 'unknown_usage' AND usage_available = false) THEN RAISE EXCEPTION 'unknown usage not preserved'; END IF;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.outcome <> 'granted' THEN RAISE EXCEPTION 'second claim failed'; END IF;
  PERFORM ai_quota.finish_ai_request(r.request_id, true, true, 3, 2, 1);
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason <> 'unknown_usage_breaker' THEN RAISE EXCEPTION 'exhausted allowance bypassed'; END IF;
  UPDATE ai_quota.settings SET developer_used_count = 0,
    developer_valid_from = clock_timestamp() - interval '2 hours',
    developer_expires_at = clock_timestamp() - interval '1 hour' WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason <> 'unknown_usage_breaker' THEN RAISE EXCEPTION 'expired allowance bypassed'; END IF;
  UPDATE ai_quota.settings SET developer_valid_from = clock_timestamp() + interval '1 hour',
    developer_expires_at = clock_timestamp() + interval '2 hours' WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason <> 'unknown_usage_breaker' THEN RAISE EXCEPTION 'future allowance bypassed'; END IF;
  BEGIN
    UPDATE ai_quota.settings SET developer_max_uses = 6 WHERE id = 1;
    RAISE EXCEPTION 'unbounded allowance accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE ai_quota.settings SET developer_expires_at = developer_valid_from + interval '25 hours' WHERE id = 1;
    RAISE EXCEPTION 'overlong allowance accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE ai_quota.settings SET developer_user_id = NULL, developer_valid_from = NULL,
    developer_expires_at = NULL, developer_max_uses = NULL, developer_used_count = NULL WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason <> 'unknown_usage_breaker' THEN RAISE EXCEPTION 'unset allowance bypassed'; END IF;
  FOREACH i IN ARRAY ARRAY[1, 2, 3] LOOP
    IF pg_catalog.has_function_privilege((ARRAY['anon','authenticated','service_role'])[i], 'ai_quota.claim_ai_request(uuid,uuid,text)', 'EXECUTE')
      OR pg_catalog.has_column_privilege((ARRAY['anon','authenticated','service_role'])[i], 'ai_quota.settings', 'developer_user_id', 'UPDATE') THEN
      RAISE EXCEPTION 'client can impersonate or alter exception';
    END IF;
  END LOOP;
  IF pg_catalog.has_column_privilege('ai_quota_backend', 'ai_quota.settings', 'developer_user_id', 'UPDATE')
    OR pg_catalog.has_column_privilege('ai_quota_backend', 'ai_quota.settings', 'developer_max_uses', 'UPDATE')
    OR pg_catalog.has_column_privilege('ai_quota_backend', 'ai_quota.settings', 'developer_used_count', 'UPDATE') THEN
    RAISE EXCEPTION 'backend can modify exception';
  END IF;
  RAISE NOTICE 'PASS: developer exception limits, identity and usage';
END
$test$;
ROLLBACK;

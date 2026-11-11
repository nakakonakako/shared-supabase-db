\set ON_ERROR_STOP on
BEGIN;
DO $test$
DECLARE
  dev uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  other_user uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  r record;
  counts record;
  request uuid;
  day_jst date := (clock_timestamp() AT TIME ZONE 'Asia/Tokyo')::date;
  month_jst date := date_trunc('month', clock_timestamp() AT TIME ZONE 'Asia/Tokyo')::date;
  measured bigint;
  i integer;
BEGIN
  DELETE FROM ai_quota.requests;
  UPDATE ai_quota.settings SET emergency_stop = false,
    unknown_usage_breaker_threshold = 1, ocr_daily_limit_per_user = 1,
    ocr_daily_limit_global = 1, concurrent_limit_per_user = 10,
    concurrent_limit_global = 10, monthly_cost_cap_micro_jpy = 800000000,
    developer_user_id = NULL WHERE id = 1;

  -- A pre-exception request continues to count even after enabling it.
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), other_user, 'ocr');
  IF r.outcome IS DISTINCT FROM 'granted' THEN RAISE EXCEPTION 'normal claim failed'; END IF;
  PERFORM ai_quota.finish_ai_request(r.request_id, true, true, 1, 1, 0);
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason IS DISTINCT FROM 'daily_limit_global' THEN RAISE EXCEPTION 'global limit not enforced without exception'; END IF;
  UPDATE ai_quota.settings SET developer_user_id = dev WHERE id = 1;

  -- More than the former cap, despite global and personal daily limits.
  FOR i IN 1..7 LOOP
    SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
    IF r.outcome IS DISTINCT FROM 'granted' THEN RAISE EXCEPTION 'developer OCR rejected at %', i; END IF;
    IF NOT (SELECT daily_limit_exempt FROM ai_quota.requests WHERE request_id = r.request_id) THEN RAISE EXCEPTION 'missing exemption snapshot'; END IF;
    PERFORM ai_quota.finish_ai_request(r.request_id, true, true, 100, 100, 0);
  END LOOP;
  SELECT * INTO counts FROM ai_quota._count_daily(dev, 'ocr', day_jst);
  IF counts.user_count <> 0 OR counts.global_count <> 1 THEN RAISE EXCEPTION 'developer OCR consumed daily quota'; END IF;
  SELECT ai_quota._measured_month_cost_micro_jpy(month_jst) INTO measured;
  IF measured <= 0 OR (SELECT count(*) FROM ai_quota.requests WHERE daily_limit_exempt) <> 7 THEN RAISE EXCEPTION 'developer usage or cost missing'; END IF;
  IF (SELECT sum(estimated_cost_micro_jpy) FROM ai_quota.requests WHERE daily_limit_exempt) <= 0 THEN RAISE EXCEPTION 'developer measured cost missing'; END IF;
  IF measured IS DISTINCT FROM (SELECT sum(estimated_cost_micro_jpy) FROM ai_quota.requests WHERE jst_month = month_jst AND status IN ('succeeded', 'failed')) THEN
    RAISE EXCEPTION 'developer measured cost excluded from month total';
  END IF;

  -- Unknown developer usage is retained and blocks normal users, while OCR remains available to the developer.
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  request := r.request_id;
  PERFORM ai_quota.finish_ai_request(request, false, false, NULL, NULL, NULL);
  IF NOT EXISTS (SELECT 1 FROM ai_quota.requests WHERE request_id = request AND status = 'unknown_usage' AND NOT usage_available AND daily_limit_exempt) THEN RAISE EXCEPTION 'unknown usage missing'; END IF;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), other_user, 'ocr');
  IF r.reject_reason IS DISTINCT FROM 'unknown_usage_breaker' THEN RAISE EXCEPTION 'normal user bypassed breaker'; END IF;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'chat');
  IF r.reject_reason IS DISTINCT FROM 'unknown_usage_breaker' THEN RAISE EXCEPTION 'developer chat bypassed breaker'; END IF;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'csv_estimate');
  IF r.reject_reason IS DISTINCT FROM 'unknown_usage_breaker' THEN RAISE EXCEPTION 'developer CSV bypassed breaker'; END IF;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.outcome IS DISTINCT FROM 'granted' THEN RAISE EXCEPTION 'developer did not bypass breaker'; END IF;
  request := r.request_id;
  SELECT * INTO r FROM ai_quota.claim_ai_request(request, dev, 'ocr');
  IF r.outcome IS DISTINCT FROM 'idempotent' THEN RAISE EXCEPTION 'idempotency changed'; END IF;

  UPDATE ai_quota.settings SET concurrent_limit_per_user = 1 WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason IS DISTINCT FROM 'concurrency_user' THEN RAISE EXCEPTION 'user concurrency bypassed'; END IF;
  UPDATE ai_quota.settings SET concurrent_limit_per_user = 10, concurrent_limit_global = 1 WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason IS DISTINCT FROM 'concurrency_global' THEN RAISE EXCEPTION 'global concurrency bypassed'; END IF;
  PERFORM ai_quota.finish_ai_request(request, true, true, 1, 1, 0);
  UPDATE ai_quota.settings SET concurrent_limit_global = 10, monthly_cost_cap_micro_jpy = 1 WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason IS DISTINCT FROM 'monthly_cost_cap' THEN RAISE EXCEPTION 'monthly cap bypassed'; END IF;
  UPDATE ai_quota.settings SET monthly_cost_cap_micro_jpy = 800000000, emergency_stop = true WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason IS DISTINCT FROM 'emergency_stop' THEN RAISE EXCEPTION 'emergency stop bypassed'; END IF;
  UPDATE ai_quota.settings SET emergency_stop = false, developer_user_id = NULL WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason IS DISTINCT FROM 'unknown_usage_breaker' THEN RAISE EXCEPTION 'disabled exception still bypasses breaker'; END IF;
  SELECT * INTO counts FROM ai_quota._count_daily(other_user, 'ocr', day_jst);
  IF counts.global_count <> 1 THEN RAISE EXCEPTION 'disabled exception changed historical daily count'; END IF;
  -- Remove breaker by a legitimate measured late finish; global limit must still count only the original normal request.
  SELECT request_id INTO request FROM ai_quota.requests WHERE status = 'unknown_usage' LIMIT 1;
  PERFORM ai_quota.finish_ai_request(request, false, true, 1, 1, 0);
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason IS DISTINCT FROM 'daily_limit_global' THEN RAISE EXCEPTION 'global limit not enforced after disable'; END IF;
  UPDATE ai_quota.settings SET ocr_daily_limit_global = 2 WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.outcome IS DISTINCT FROM 'granted' OR (SELECT daily_limit_exempt FROM ai_quota.requests WHERE request_id = r.request_id) THEN RAISE EXCEPTION 'post-disable request not counted'; END IF;
  SELECT * INTO counts FROM ai_quota._count_daily(other_user, 'ocr', day_jst);
  IF counts.global_count <> 2 THEN RAISE EXCEPTION 'post-disable count incorrect'; END IF;
  FOR i IN 1..3 LOOP
    IF pg_catalog.has_function_privilege((ARRAY['anon','authenticated','service_role'])[i], 'ai_quota.claim_ai_request(uuid,uuid,text)', 'EXECUTE')
      OR pg_catalog.has_column_privilege((ARRAY['anon','authenticated','service_role'])[i], 'ai_quota.settings', 'developer_user_id', 'UPDATE') THEN
      RAISE EXCEPTION 'client can impersonate or alter exception';
    END IF;
  END LOOP;
  IF pg_catalog.has_column_privilege('ai_quota_backend', 'ai_quota.settings', 'developer_user_id', 'UPDATE')
    OR pg_catalog.has_column_privilege('ai_quota_backend', 'ai_quota.requests', 'daily_limit_exempt', 'UPDATE') THEN
    RAISE EXCEPTION 'backend can modify exemption';
  END IF;
  RAISE NOTICE 'PASS: developer OCR exception, daily snapshots, limits and usage';
END
$test$;
DO $normal_users$
DECLARE
  dev uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  u1 uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  u2 uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  u3 uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
  r record;
  i integer;
BEGIN
  DELETE FROM ai_quota.requests;
  UPDATE ai_quota.settings SET developer_user_id = dev, emergency_stop = false,
    unknown_usage_breaker_threshold = 3, ocr_daily_limit_per_user = 1,
    ocr_daily_limit_global = 2, concurrent_limit_per_user = 10,
    concurrent_limit_global = 10, monthly_cost_cap_micro_jpy = 800000000,
    chat_daily_limit_per_user = 1 WHERE id = 1;
  FOR i IN 1..7 LOOP
    SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
    IF r.outcome IS DISTINCT FROM 'granted' THEN RAISE EXCEPTION 'developer claim failed'; END IF;
    PERFORM ai_quota.finish_ai_request(r.request_id, true, true, 1, 1, 0);
  END LOOP;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), u1, 'ocr');
  IF r.outcome IS DISTINCT FROM 'granted' THEN RAISE EXCEPTION 'developer OCR blocked normal user during exception'; END IF;
  PERFORM ai_quota.finish_ai_request(r.request_id, true, true, 1, 1, 0);
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'chat');
  IF r.outcome IS DISTINCT FROM 'granted' THEN RAISE EXCEPTION 'first chat failed'; END IF;
  PERFORM ai_quota.finish_ai_request(r.request_id, true, true, 1, 1, 0);
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'chat');
  IF r.reject_reason IS DISTINCT FROM 'daily_limit_user' THEN RAISE EXCEPTION 'developer chat daily limit bypassed'; END IF;
  UPDATE ai_quota.settings SET developer_user_id = NULL WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), u2, 'ocr');
  IF r.outcome IS DISTINCT FROM 'granted' THEN RAISE EXCEPTION 'historical developer OCR blocked normal user after disable'; END IF;
  PERFORM ai_quota.finish_ai_request(r.request_id, true, true, 1, 1, 0);
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), u3, 'ocr');
  IF r.reject_reason IS DISTINCT FROM 'daily_limit_global' THEN RAISE EXCEPTION 'normal user global limit not enforced'; END IF;
  RAISE NOTICE 'PASS: normal daily quota during and after exception';
END
$normal_users$;
DO $personal_limit$
DECLARE
  dev uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  r record;
BEGIN
  DELETE FROM ai_quota.requests;
  UPDATE ai_quota.settings SET developer_user_id = NULL, emergency_stop = false,
    unknown_usage_breaker_threshold = 3, ocr_daily_limit_per_user = 1,
    ocr_daily_limit_global = 20, concurrent_limit_per_user = 10,
    concurrent_limit_global = 10, monthly_cost_cap_micro_jpy = 800000000 WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  PERFORM ai_quota.finish_ai_request(r.request_id, true, true, 1, 1, 0);
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.reject_reason IS DISTINCT FROM 'daily_limit_user' THEN RAISE EXCEPTION 'personal limit not enforced before activation'; END IF;
  UPDATE ai_quota.settings SET developer_user_id = dev WHERE id = 1;
  SELECT * INTO r FROM ai_quota.claim_ai_request(gen_random_uuid(), dev, 'ocr');
  IF r.outcome IS DISTINCT FROM 'granted' THEN RAISE EXCEPTION 'developer OCR did not bypass personal daily limit'; END IF;
  RAISE NOTICE 'PASS: developer OCR bypasses an already reached personal limit';
END
$personal_limit$;
ROLLBACK;

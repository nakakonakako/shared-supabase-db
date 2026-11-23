-- Verifies the gemini-3.8-flash settings migration. Run after that migration.
\set ON_ERROR_STOP on

BEGIN;

DO $tests$
DECLARE
  s ai_quota.settings%rowtype;
  v_cost bigint;
BEGIN
  SELECT * INTO s FROM ai_quota.settings WHERE id = 1;

  IF s.model_id IS DISTINCT FROM 'gemini-3.8-flash'
     OR s.input_price_usd_per_million IS DISTINCT FROM 1500000
     OR s.output_price_usd_per_million IS DISTINCT FROM 7500000
     OR s.thought_price_usd_per_million IS DISTINCT FROM 7500000
     OR s.monthly_cost_cap_micro_jpy IS DISTINCT FROM 3000000000 THEN
    RAISE EXCEPTION 'gemini-3.8-flash settings were not applied';
  END IF;

  -- Unrelated settings keep their values.
  IF s.fx_jpy_per_usd IS DISTINCT FROM 200 OR s.emergency_stop THEN
    RAISE EXCEPTION 'unrelated ai_quota settings changed';
  END IF;

  -- 1000 input + 2000 output + 3000 thought tokens at the new rates and 200 JPY/USD.
  v_cost := ai_quota._compute_cost_micro_jpy(
    1000, 2000, 3000,
    s.input_price_usd_per_million, s.output_price_usd_per_million,
    s.thought_price_usd_per_million, s.fx_jpy_per_usd
  );
  IF v_cost IS DISTINCT FROM 7800000 THEN
    RAISE EXCEPTION 'expected 7800000 micro-JPY, got %', v_cost;
  END IF;

  RAISE NOTICE 'PASS: gemini-3.8-flash settings';
END;
$tests$;

ROLLBACK;

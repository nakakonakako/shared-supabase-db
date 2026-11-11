-- One bounded, administrator-configured exception to the unknown-usage breaker.
-- Existing claim signature, role grants, and all other limits stay unchanged.
begin;

do $guard$
begin
  if session_user is distinct from current_user then
    raise exception 'migration requires the session user';
  end if;
  if not (select rolsuper from pg_catalog.pg_roles where rolname = current_user)
     and (pg_catalog.pg_has_role(current_user, 'ai_quota_owner', 'USAGE')
       or pg_catalog.pg_has_role(current_user, 'ai_quota_owner', 'SET')) then
    raise exception 'migration user must not already have effective owner access';
  end if;
  if exists (
    select 1 from pg_catalog.pg_auth_members m
    join pg_catalog.pg_roles granted on granted.oid = m.roleid
    join pg_catalog.pg_roles member on member.oid = m.member
    join pg_catalog.pg_roles grantor on grantor.oid = m.grantor
    where granted.rolname = 'ai_quota_owner' and member.rolname = current_user
      and grantor.rolname = current_user
  ) then
    raise exception 'migration must not replace an existing owner membership grant';
  end if;
end
$guard$;

grant ai_quota_owner to current_user with set true, inherit false;
set local role ai_quota_owner;

alter table ai_quota.settings
  add column developer_user_id uuid,
  add column developer_valid_from timestamptz,
  add column developer_expires_at timestamptz,
  add column developer_max_uses integer,
  add column developer_used_count integer,
  add constraint developer_exception_valid check (
    (developer_user_id is null and developer_valid_from is null
      and developer_expires_at is null and developer_max_uses is null
      and developer_used_count is null)
    or
    (developer_user_id is not null and developer_valid_from is not null
      and developer_expires_at is not null and developer_max_uses is not null
      and developer_used_count is not null
      and developer_expires_at > developer_valid_from
      and developer_expires_at <= developer_valid_from + interval '24 hours'
      and developer_max_uses between 1 and 5
      and developer_used_count between 0 and developer_max_uses)
  );

create or replace function ai_quota.claim_ai_request(
  p_request_id uuid,
  p_user_id uuid,
  p_kind text
)
returns table (
  outcome text,
  reject_reason text,
  request_id uuid,
  user_id uuid,
  kind text,
  status text,
  lease_expires_at timestamptz,
  started_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_settings ai_quota.settings%rowtype;
  v_now timestamptz;
  v_jst_day date;
  v_jst_month date;
  v_existing ai_quota.requests%rowtype;
  v_per_user integer;
  v_global_limit integer;
  v_daily_user_count bigint;
  v_daily_global_count bigint;
  v_active_user_count bigint;
  v_active_global_count bigint;
  v_month_cost bigint;
  v_unknown_count bigint;
  v_exception_used boolean := false;
begin
  if p_request_id is null or p_user_id is null or p_kind is null then
    raise exception using errcode = '22023', message = 'request id, user id, and kind are required';
  end if;
  if p_kind not in ('ocr', 'chat', 'csv_estimate') then
    raise exception using errcode = '22023', message = 'invalid ai request kind';
  end if;

  select s.* into v_settings
  from ai_quota.settings as s
  where s.id = 1
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'ai quota settings missing';
  end if;

  v_now := pg_catalog.clock_timestamp();
  select b.jst_day, b.jst_month
    into v_jst_day, v_jst_month
  from ai_quota._jst_bounds(v_now) as b;

  select r.* into v_existing
  from ai_quota.requests as r
  where r.request_id = p_request_id;

  if found then
    if v_existing.user_id is distinct from p_user_id
       or v_existing.kind is distinct from p_kind then
      outcome := 'rejected';
      reject_reason := 'idempotency_conflict';
      request_id := v_existing.request_id;
      user_id := v_existing.user_id;
      kind := v_existing.kind;
      status := v_existing.status;
      lease_expires_at := v_existing.lease_expires_at;
      started_at := v_existing.started_at;
      return next;
      return;
    end if;

    outcome := 'idempotent';
    reject_reason := null;
    request_id := v_existing.request_id;
    user_id := v_existing.user_id;
    kind := v_existing.kind;
    status := v_existing.status;
    lease_expires_at := v_existing.lease_expires_at;
    started_at := v_existing.started_at;
    return next;
    return;
  end if;

  if v_settings.emergency_stop then
    outcome := 'rejected';
    reject_reason := 'emergency_stop';
    return next;
    return;
  end if;

  -- Expired workers may have consumed tokens before crashing. Record them as
  -- unknown. unknown_at is the lease expiry, so a lease that expired on an
  -- earlier JST day does not count toward today's breaker.
  update ai_quota.requests as r
  set status = 'unknown_usage',
      usage_available = false,
      input_tokens = null,
      output_tokens = null,
      thought_tokens = null,
      total_tokens = null,
      estimated_cost_micro_jpy = null,
      finished_at = v_now,
      unknown_at = r.lease_expires_at
  where r.status = 'active'
    and r.lease_expires_at <= v_now;

  v_unknown_count := ai_quota._unknown_usage_count(v_jst_day);
  if v_unknown_count >= v_settings.unknown_usage_breaker_threshold then
    if v_settings.developer_user_id = p_user_id
       and v_settings.developer_valid_from <= v_now
       and v_now < v_settings.developer_expires_at
       and v_settings.developer_used_count < v_settings.developer_max_uses then
      v_exception_used := true;
    else
      outcome := 'rejected';
      reject_reason := 'unknown_usage_breaker';
      return next;
      return;
    end if;
  end if;

  select l.per_user, l.global_limit
    into v_per_user, v_global_limit
  from ai_quota._daily_limits(v_settings, p_kind) as l;

  select c.user_count, c.global_count
    into v_daily_user_count, v_daily_global_count
  from ai_quota._count_daily(p_user_id, p_kind, v_jst_day) as c;

  if v_daily_user_count >= v_per_user then
    outcome := 'rejected';
    reject_reason := 'daily_limit_user';
    return next;
    return;
  end if;

  if v_daily_global_count >= v_global_limit then
    outcome := 'rejected';
    reject_reason := 'daily_limit_global';
    return next;
    return;
  end if;

  select a.user_active, a.global_active
    into v_active_user_count, v_active_global_count
  from ai_quota._count_active_leases(p_user_id, v_now) as a;

  if v_active_user_count >= v_settings.concurrent_limit_per_user then
    outcome := 'rejected';
    reject_reason := 'concurrency_user';
    return next;
    return;
  end if;

  if v_active_global_count >= v_settings.concurrent_limit_global then
    outcome := 'rejected';
    reject_reason := 'concurrency_global';
    return next;
    return;
  end if;

  v_month_cost := ai_quota._measured_month_cost_micro_jpy(v_jst_month);
  if v_month_cost >= v_settings.monthly_cost_cap_micro_jpy then
    outcome := 'rejected';
    reject_reason := 'monthly_cost_cap';
    return next;
    return;
  end if;

  insert into ai_quota.requests as r (
    request_id,
    user_id,
    kind,
    started_at,
    jst_day,
    jst_month,
    status,
    lease_expires_at,
    snapshot_model_id,
    snapshot_input_price_usd_per_million,
    snapshot_output_price_usd_per_million,
    snapshot_thought_price_usd_per_million,
    snapshot_fx_jpy_per_usd
  ) values (
    p_request_id,
    p_user_id,
    p_kind,
    v_now,
    v_jst_day,
    v_jst_month,
    'active',
    v_now + pg_catalog.make_interval(secs => v_settings.lease_duration_seconds),
    v_settings.model_id,
    v_settings.input_price_usd_per_million,
    v_settings.output_price_usd_per_million,
    v_settings.thought_price_usd_per_million,
    v_settings.fx_jpy_per_usd
  )
  returning r.* into v_existing;

  -- Only an actually granted claim consumes a slot, atomically with the
  -- request insert and under the settings row lock held throughout claim.
  if v_exception_used then
    update ai_quota.settings as s
    set developer_used_count = s.developer_used_count + 1
    where s.id = 1;
  end if;

  outcome := 'granted';
  reject_reason := null;
  request_id := v_existing.request_id;
  user_id := v_existing.user_id;
  kind := v_existing.kind;
  status := v_existing.status;
  lease_expires_at := v_existing.lease_expires_at;
  started_at := v_existing.started_at;
  return next;
end;
$function$;

reset role;
revoke ai_quota_owner from current_user;

do $guard$
begin
  if exists (
    select 1 from pg_catalog.pg_auth_members m
    join pg_catalog.pg_roles granted on granted.oid = m.roleid
    join pg_catalog.pg_roles member on member.oid = m.member
    where granted.rolname = 'ai_quota_owner' and member.rolname = current_user
      and (m.set_option or m.inherit_option)
  ) then
    raise exception 'migration user retains effective ai_quota_owner access';
  end if;
end
$guard$;
commit;

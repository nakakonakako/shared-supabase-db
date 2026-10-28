-- S1-06 PR 2A: private ai_quota schema, settings/requests tables, and claim/renew/finish RPCs.
-- Backend connects as role ai_quota_backend (password configured out of band; not stored here).
--
-- One transaction. Existing ai_quota_owner / ai_quota_backend roles are refused.
-- Attributes are set only on CREATE ROLE (no ALTER ROLE). PostgreSQL 17 does not
-- grant the creator effective SET membership, so this migration grants it
-- explicitly and revokes that grant before commit. Database CREATE is granted to ai_quota_owner only
-- long enough to create the schema, then revoked. Tables and functions are
-- created while SET LOCAL ROLE ai_quota_owner, so they do not need OWNER TO.

begin;

do $roles$
declare
  v_existing text;
begin
  if session_user is distinct from current_user then
    raise exception using
      errcode = '42501',
      message = 'ai_quota migration must run as the session user, not under SET ROLE';
  end if;

  select pg_catalog.string_agg(existing.rolname, ', ' order by existing.rolname)
    into v_existing
  from pg_catalog.pg_roles as existing
  where existing.rolname in ('ai_quota_owner', 'ai_quota_backend');

  if v_existing is not null then
    raise exception using
      errcode = '42501',
      message = 'ai_quota migration refused: role already exists ('
        || v_existing
        || '). Existing roles are not reused or altered.';
  end if;
end
$roles$;

create role ai_quota_owner
  nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
create role ai_quota_backend
  login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;

-- CREATE ROLE already grants the creator ADMIN OPTION on this membership.
-- SET allows SET ROLE. INHERIT stays false so owner rights are not implicit.
grant ai_quota_owner to current_user with set true, inherit false;

do $grant_db_create$
begin
  execute format(
    'grant create on database %I to %I',
    current_database(),
    'ai_quota_owner'
  );
end
$grant_db_create$;

set local role ai_quota_owner;
create schema ai_quota authorization ai_quota_owner;
reset role;

do $revoke_db_create$
begin
  execute format(
    'revoke create on database %I from %I',
    current_database(),
    'ai_quota_owner'
  );
end
$revoke_db_create$;

set local role ai_quota_owner;

revoke all on schema ai_quota from public;
revoke all on schema ai_quota from anon, authenticated, service_role;

create table ai_quota.settings (
  id smallint primary key,
  emergency_stop boolean not null default false,
  unknown_usage_breaker_threshold integer not null default 3
    constraint unknown_usage_breaker_threshold_positive check (unknown_usage_breaker_threshold > 0),
  lease_duration_seconds integer not null default 240
    constraint lease_duration_seconds_positive check (lease_duration_seconds > 0),
  monthly_cost_cap_micro_jpy bigint not null default 800000000
    constraint monthly_cost_cap_non_negative check (monthly_cost_cap_micro_jpy >= 0),
  model_id text not null default 'gemini-3-flash-preview',
  input_price_usd_per_million bigint not null default 500000,
  output_price_usd_per_million bigint not null default 3000000,
  thought_price_usd_per_million bigint not null default 3000000,
  fx_jpy_per_usd integer not null default 200
    constraint fx_jpy_per_usd_positive check (fx_jpy_per_usd > 0),
  ocr_daily_limit_per_user integer not null default 20,
  ocr_daily_limit_global integer not null default 50,
  chat_daily_limit_per_user integer not null default 20,
  chat_daily_limit_global integer not null default 50,
  csv_estimate_daily_limit_per_user integer not null default 5,
  csv_estimate_daily_limit_global integer not null default 20,
  concurrent_limit_per_user integer not null default 1,
  concurrent_limit_global integer not null default 3,
  constraint settings_singleton check (id = 1),
  constraint daily_limits_positive check (
    ocr_daily_limit_per_user > 0
    and ocr_daily_limit_global > 0
    and chat_daily_limit_per_user > 0
    and chat_daily_limit_global > 0
    and csv_estimate_daily_limit_per_user > 0
    and csv_estimate_daily_limit_global > 0
    and concurrent_limit_per_user > 0
    and concurrent_limit_global > 0
  ),
  constraint prices_non_negative check (
    input_price_usd_per_million >= 0
    and output_price_usd_per_million >= 0
    and thought_price_usd_per_million >= 0
  )
);

insert into ai_quota.settings (id) values (1)
on conflict (id) do nothing;

create table ai_quota.requests (
  request_id uuid primary key,
  user_id uuid not null,
  kind text not null,
  started_at timestamptz not null,
  jst_day date not null,
  jst_month date not null,
  status text not null default 'active',
  lease_expires_at timestamptz not null,
  input_tokens bigint,
  output_tokens bigint,
  thought_tokens bigint,
  total_tokens bigint,
  estimated_cost_micro_jpy bigint,
  usage_available boolean,
  unknown_at timestamptz,
  snapshot_model_id text not null,
  snapshot_input_price_usd_per_million bigint not null,
  snapshot_output_price_usd_per_million bigint not null,
  snapshot_thought_price_usd_per_million bigint not null,
  snapshot_fx_jpy_per_usd integer not null,
  finished_at timestamptz,
  constraint requests_kind_valid check (
    kind in ('ocr', 'chat', 'csv_estimate')
  ),
  constraint requests_status_valid check (
    status in ('active', 'succeeded', 'failed', 'unknown_usage')
  ),
  constraint requests_terminal_usage_shape check (
    (
      status = 'active'
      and unknown_at is null
    )
    or (
      status in ('succeeded', 'failed')
      and usage_available is true
      and input_tokens is not null
      and output_tokens is not null
      and thought_tokens is not null
      and total_tokens is not null
      and estimated_cost_micro_jpy is not null
      and finished_at is not null
    )
    or (
      status = 'unknown_usage'
      and usage_available is false
      and input_tokens is null
      and output_tokens is null
      and thought_tokens is null
      and total_tokens is null
      and estimated_cost_micro_jpy is null
      and finished_at is not null
      and unknown_at is not null
    )
  )
);

create index requests_user_kind_day_idx
  on ai_quota.requests (user_id, kind, jst_day);

create index requests_kind_day_idx
  on ai_quota.requests (kind, jst_day);

create index requests_jst_month_status_idx
  on ai_quota.requests (jst_month, status);

create index requests_active_lease_idx
  on ai_quota.requests (lease_expires_at)
  where status = 'active';

create index requests_unknown_usage_unknown_at_idx
  on ai_quota.requests (unknown_at)
  where status = 'unknown_usage';

revoke all on table ai_quota.settings from public, anon, authenticated, service_role;
revoke all on table ai_quota.requests from public, anon, authenticated, service_role;

create or replace function ai_quota._jst_bounds(p_now timestamptz)
returns table (jst_day date, jst_month date)
language sql
immutable
set search_path = ''
as $function$
  select
    (p_now at time zone 'Asia/Tokyo')::date as jst_day,
    pg_catalog.date_trunc(
      'month',
      p_now at time zone 'Asia/Tokyo'
    )::date as jst_month;
$function$;

revoke all on function ai_quota._jst_bounds(timestamptz) from public;

create or replace function ai_quota._daily_limits(
  p_settings ai_quota.settings,
  p_kind text,
  out per_user integer,
  out global_limit integer
)
returns record
language plpgsql
immutable
set search_path = ''
as $function$
begin
  case p_kind
    when 'ocr' then
      per_user := p_settings.ocr_daily_limit_per_user;
      global_limit := p_settings.ocr_daily_limit_global;
    when 'chat' then
      per_user := p_settings.chat_daily_limit_per_user;
      global_limit := p_settings.chat_daily_limit_global;
    when 'csv_estimate' then
      per_user := p_settings.csv_estimate_daily_limit_per_user;
      global_limit := p_settings.csv_estimate_daily_limit_global;
    else
      raise exception using errcode = '22023', message = 'invalid ai request kind';
  end case;
end;
$function$;

revoke all on function ai_quota._daily_limits(ai_quota.settings, text) from public;

create or replace function ai_quota._compute_cost_micro_jpy(
  p_input_tokens bigint,
  p_output_tokens bigint,
  p_thought_tokens bigint,
  p_input_price_usd_per_million bigint,
  p_output_price_usd_per_million bigint,
  p_thought_price_usd_per_million bigint,
  p_fx_jpy_per_usd integer
)
returns bigint
language sql
immutable
set search_path = ''
as $function$
  select pg_catalog.ceil(
    (
      coalesce(p_input_tokens, 0)::numeric * p_input_price_usd_per_million
      + coalesce(p_output_tokens, 0)::numeric * p_output_price_usd_per_million
      + coalesce(p_thought_tokens, 0)::numeric * p_thought_price_usd_per_million
    ) * p_fx_jpy_per_usd::numeric / 1000000
  )::bigint;
$function$;

revoke all on function ai_quota._compute_cost_micro_jpy(
  bigint, bigint, bigint, bigint, bigint, bigint, integer
) from public;

create or replace function ai_quota._count_daily(
  p_user_id uuid,
  p_kind text,
  p_jst_day date
)
returns table (user_count bigint, global_count bigint)
language sql
stable
set search_path = ''
as $function$
  select
    pg_catalog.count(*) filter (where r.user_id = p_user_id) as user_count,
    pg_catalog.count(*) as global_count
  from ai_quota.requests as r
  where r.kind = p_kind
    and r.jst_day = p_jst_day
    and r.status in ('active', 'succeeded', 'failed', 'unknown_usage');
$function$;

revoke all on function ai_quota._count_daily(uuid, text, date) from public;

create or replace function ai_quota._count_active_leases(
  p_user_id uuid,
  p_now timestamptz
)
returns table (user_active bigint, global_active bigint)
language sql
stable
set search_path = ''
as $function$
  select
    pg_catalog.count(*) filter (where r.user_id = p_user_id) as user_active,
    pg_catalog.count(*) as global_active
  from ai_quota.requests as r
  where r.status = 'active'
    and r.lease_expires_at > p_now;
$function$;

revoke all on function ai_quota._count_active_leases(uuid, timestamptz) from public;

create or replace function ai_quota._measured_month_cost_micro_jpy(p_jst_month date)
returns bigint
language sql
stable
set search_path = ''
as $function$
  select coalesce(
    pg_catalog.sum(r.estimated_cost_micro_jpy),
    0::bigint
  )
  from ai_quota.requests as r
  where r.jst_month = p_jst_month
    and r.status in ('succeeded', 'failed');
$function$;

revoke all on function ai_quota._measured_month_cost_micro_jpy(date) from public;

create or replace function ai_quota._unknown_usage_count(p_jst_day date)
returns bigint
language sql
stable
set search_path = ''
as $function$
  -- Unresolved unknown_usage counts only on the JST day of unknown_at.
  -- Older rows stay in requests and keep their claim-day quota consumption.
  select pg_catalog.count(*)
  from ai_quota.requests as r
  where r.status = 'unknown_usage'
    and r.unknown_at >= (p_jst_day::timestamp without time zone at time zone 'Asia/Tokyo')
    and r.unknown_at < ((p_jst_day + 1)::timestamp without time zone at time zone 'Asia/Tokyo');
$function$;

revoke all on function ai_quota._unknown_usage_count(date) from public;

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
    outcome := 'rejected';
    reject_reason := 'unknown_usage_breaker';
    return next;
    return;
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

create or replace function ai_quota.renew_ai_lease(p_request_id uuid)
returns table (
  outcome text,
  reject_reason text,
  request_id uuid,
  lease_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_settings ai_quota.settings%rowtype;
  v_now timestamptz;
  v_row ai_quota.requests%rowtype;
begin
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;

  select s.* into v_settings
  from ai_quota.settings as s
  where s.id = 1
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'ai quota settings missing';
  end if;

  v_now := pg_catalog.clock_timestamp();

  select r.* into v_row
  from ai_quota.requests as r
  where r.request_id = p_request_id
  for update;

  if not found then
    outcome := 'rejected';
    reject_reason := 'request_not_found';
    return next;
    return;
  end if;

  if v_row.status <> 'active' then
    outcome := 'rejected';
    reject_reason := 'not_active';
    request_id := v_row.request_id;
    lease_expires_at := v_row.lease_expires_at;
    return next;
    return;
  end if;

  if v_row.lease_expires_at <= v_now then
    outcome := 'rejected';
    reject_reason := 'lease_expired';
    request_id := v_row.request_id;
    lease_expires_at := v_row.lease_expires_at;
    return next;
    return;
  end if;

  update ai_quota.requests as r
  set lease_expires_at = v_now + pg_catalog.make_interval(secs => v_settings.lease_duration_seconds)
  where r.request_id = p_request_id
  returning r.lease_expires_at into lease_expires_at;

  outcome := 'renewed';
  reject_reason := null;
  request_id := p_request_id;
  return next;
end;
$function$;

create or replace function ai_quota.finish_ai_request(
  p_request_id uuid,
  p_succeeded boolean,
  p_usage_available boolean,
  p_input_tokens bigint,
  p_output_tokens bigint,
  p_thought_tokens bigint
)
returns table (
  outcome text,
  reject_reason text,
  request_id uuid,
  status text,
  estimated_cost_micro_jpy bigint,
  finished_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_settings ai_quota.settings%rowtype;
  v_now timestamptz;
  v_row ai_quota.requests%rowtype;
  v_total bigint;
  v_cost bigint;
begin
  if p_request_id is null or p_succeeded is null or p_usage_available is null then
    raise exception using errcode = '22023', message = 'request id, result, and usage availability are required';
  end if;

  select s.* into v_settings
  from ai_quota.settings as s
  where s.id = 1
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'ai quota settings missing';
  end if;

  v_now := pg_catalog.clock_timestamp();

  select r.* into v_row
  from ai_quota.requests as r
  where r.request_id = p_request_id
  for update;

  if not found then
    outcome := 'rejected';
    reject_reason := 'request_not_found';
    return next;
    return;
  end if;

  if v_row.status in ('succeeded', 'failed') then
    if p_usage_available then
      if (v_row.status = 'succeeded') is distinct from p_succeeded
         or v_row.usage_available is distinct from true
         or v_row.input_tokens is distinct from p_input_tokens
         or v_row.output_tokens is distinct from p_output_tokens
         or v_row.thought_tokens is distinct from p_thought_tokens then
        outcome := 'rejected';
        reject_reason := 'finish_conflict';
        request_id := v_row.request_id;
        status := v_row.status;
        estimated_cost_micro_jpy := v_row.estimated_cost_micro_jpy;
        finished_at := v_row.finished_at;
        return next;
        return;
      end if;
    else
      outcome := 'rejected';
      reject_reason := 'finish_conflict';
      request_id := v_row.request_id;
      status := v_row.status;
      estimated_cost_micro_jpy := v_row.estimated_cost_micro_jpy;
      finished_at := v_row.finished_at;
      return next;
      return;
    end if;

    outcome := 'idempotent';
    reject_reason := null;
    request_id := v_row.request_id;
    status := v_row.status;
    estimated_cost_micro_jpy := v_row.estimated_cost_micro_jpy;
    finished_at := v_row.finished_at;
    return next;
    return;
  end if;

  if v_row.status = 'unknown_usage' and not p_usage_available then
    outcome := 'idempotent';
    reject_reason := null;
    request_id := v_row.request_id;
    status := v_row.status;
    estimated_cost_micro_jpy := null;
    finished_at := v_row.finished_at;
    return next;
    return;
  end if;

  if v_row.status not in ('active', 'unknown_usage') then
    outcome := 'rejected';
    reject_reason := 'not_active';
    request_id := v_row.request_id;
    status := v_row.status;
    estimated_cost_micro_jpy := v_row.estimated_cost_micro_jpy;
    finished_at := v_row.finished_at;
    return next;
    return;
  end if;

  if not p_usage_available then
    if p_input_tokens is not null or p_output_tokens is not null or p_thought_tokens is not null then
      raise exception using errcode = '22023', message = 'token counts must be null when usage is unavailable';
    end if;
    update ai_quota.requests as r
    set status = 'unknown_usage',
        usage_available = false,
        input_tokens = null,
        output_tokens = null,
        thought_tokens = null,
        total_tokens = null,
        estimated_cost_micro_jpy = null,
        finished_at = v_now,
        unknown_at = v_now
    where r.request_id = p_request_id
    returning r.status, r.estimated_cost_micro_jpy, r.finished_at
      into status, estimated_cost_micro_jpy, finished_at;

    outcome := 'finished';
    reject_reason := null;
    request_id := p_request_id;
    return next;
    return;
  end if;

  if p_input_tokens is null or p_output_tokens is null or p_thought_tokens is null then
    raise exception using errcode = '22023', message = 'token counts are required when usage is available';
  end if;
  if p_input_tokens < 0 or p_output_tokens < 0 or p_thought_tokens < 0
     or p_input_tokens > 1000000000000
     or p_output_tokens > 1000000000000
     or p_thought_tokens > 1000000000000 then
    raise exception using errcode = '22023', message = 'token counts are outside the supported range';
  end if;

  v_total := p_input_tokens + p_output_tokens + p_thought_tokens;
  -- A late measured finish settles unknown_usage to succeeded/failed.
  -- unknown_at is intentionally left in place as history and drops out of
  -- the breaker because the status is no longer unknown_usage.
  v_cost := ai_quota._compute_cost_micro_jpy(
    p_input_tokens,
    p_output_tokens,
    p_thought_tokens,
    v_row.snapshot_input_price_usd_per_million,
    v_row.snapshot_output_price_usd_per_million,
    v_row.snapshot_thought_price_usd_per_million,
    v_row.snapshot_fx_jpy_per_usd
  );

  update ai_quota.requests as r
  set status = case when p_succeeded then 'succeeded' else 'failed' end,
      usage_available = true,
      input_tokens = p_input_tokens,
      output_tokens = p_output_tokens,
      thought_tokens = p_thought_tokens,
      total_tokens = v_total,
      estimated_cost_micro_jpy = v_cost,
      finished_at = v_now
  where r.request_id = p_request_id
  returning r.status, r.estimated_cost_micro_jpy, r.finished_at
    into status, estimated_cost_micro_jpy, finished_at;

  outcome := 'finished';
  reject_reason := null;
  request_id := p_request_id;
  return next;
end;
$function$;

revoke all on function ai_quota.claim_ai_request(uuid, uuid, text) from public;
revoke all on function ai_quota.renew_ai_lease(uuid) from public;
revoke all on function ai_quota.finish_ai_request(uuid, boolean, boolean, bigint, bigint, bigint) from public;
revoke all on function ai_quota.claim_ai_request(uuid, uuid, text) from anon, authenticated, service_role;
revoke all on function ai_quota.renew_ai_lease(uuid) from anon, authenticated, service_role;
revoke all on function ai_quota.finish_ai_request(uuid, boolean, boolean, bigint, bigint, bigint)
  from anon, authenticated, service_role;

grant usage on schema ai_quota to ai_quota_backend;
grant execute on function ai_quota.claim_ai_request(uuid, uuid, text) to ai_quota_backend;
grant execute on function ai_quota.renew_ai_lease(uuid) to ai_quota_backend;
grant execute on function ai_quota.finish_ai_request(uuid, boolean, boolean, bigint, bigint, bigint) to ai_quota_backend;

-- Integrity verification reads the singleton after the temporary SET
-- membership is revoked. A platform-created ADMIN-only membership may remain.
-- No table writes and no RPC EXECUTE are granted to the migration role.
grant usage on schema ai_quota to session_user;
grant select on table ai_quota.settings to session_user;

reset role;

revoke ai_quota_owner from current_user;

do $migration_privileges_cleared$
begin
  -- Supabase/PostgreSQL may create an immutable ADMIN-only membership for
  -- the trusted migration user when CREATE ROLE runs. The explicit SET
  -- membership above is revoked; only effective SET/INHERIT must be absent.
  if exists (
    select 1
    from pg_catalog.pg_auth_members as m
    join pg_catalog.pg_roles as granted on granted.oid = m.roleid
    join pg_catalog.pg_roles as member on member.oid = m.member
    where granted.rolname = 'ai_quota_owner'
      and member.rolname = current_user
      and (m.set_option or m.inherit_option)
  ) then
    raise exception using
      errcode = '42501',
      message = 'migration role retains effective SET or INHERIT access to ai_quota_owner';
  end if;

  if pg_catalog.has_database_privilege(
    'ai_quota_owner',
    current_database(),
    'CREATE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'ai_quota_owner still has CREATE on the current database';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_roles
    where rolname = 'ai_quota_owner'
      and rolcanlogin = false
      and rolinherit = false
      and rolsuper = false
      and rolcreatedb = false
      and rolcreaterole = false
      and rolreplication = false
      and rolbypassrls = false
  ) or not exists (
    select 1
    from pg_catalog.pg_roles
    where rolname = 'ai_quota_backend'
      and rolcanlogin = true
      and rolinherit = false
      and rolsuper = false
      and rolcreatedb = false
      and rolcreaterole = false
      and rolreplication = false
      and rolbypassrls = false
  ) then
    raise exception using
      errcode = '42501',
      message = 'ai_quota role attributes do not match the least-privilege design';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_class as c
    join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
    join pg_catalog.pg_roles as r on r.oid = c.relowner
    where n.nspname = 'ai_quota'
      and c.relkind = 'r'
      and r.rolname is distinct from 'ai_quota_owner'
  ) or exists (
    select 1
    from pg_catalog.pg_proc as p
    join pg_catalog.pg_namespace as n on n.oid = p.pronamespace
    join pg_catalog.pg_roles as r on r.oid = p.proowner
    where n.nspname = 'ai_quota'
      and (
        r.rolname is distinct from 'ai_quota_owner'
        or p.proconfig is distinct from array['search_path=""']::text[]
      )
  ) or (
    select r.rolname
    from pg_catalog.pg_namespace as n
    join pg_catalog.pg_roles as r on r.oid = n.nspowner
    where n.nspname = 'ai_quota'
  ) is distinct from 'ai_quota_owner' then
    raise exception using
      errcode = '42501',
      message = 'ai_quota schema, tables, or functions are not owned by ai_quota_owner';
  end if;

  if (
    select pg_catalog.count(*)
    from ai_quota.settings
    where id = 1
  ) is distinct from 1 then
    raise exception using
      errcode = 'P0001',
      message = 'ai_quota.settings singleton is missing';
  end if;
end
$migration_privileges_cleared$;

commit;

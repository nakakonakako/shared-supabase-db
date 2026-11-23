-- Switch the AI quota pricing snapshot to gemini-3.8-flash and raise the
-- measured monthly cost cap to 3,000 JPY. Only these five settings change;
-- limits, breaker, lease, FX, and emergency stop stay as they are.
--
-- Prices are micro-USD per 1M tokens. They use the published rates that apply
-- from 2027-01-01 (input 1.50, output including thinking 7.50), which are twice
-- the rates through 2026-12-31 (0.75 / 3.75), so the cap is never under-counted.
-- Requests already recorded keep their claim-time price snapshot.
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

update ai_quota.settings
set
  model_id = 'gemini-3.8-flash',
  input_price_usd_per_million = 1500000,
  output_price_usd_per_million = 7500000,
  thought_price_usd_per_million = 7500000,
  monthly_cost_cap_micro_jpy = 3000000000
where id = 1;

do $verify$
begin
  if not exists (
    select 1 from ai_quota.settings
    where id = 1
      and model_id = 'gemini-3.8-flash'
      and input_price_usd_per_million = 1500000
      and output_price_usd_per_million = 7500000
      and thought_price_usd_per_million = 7500000
      and monthly_cost_cap_micro_jpy = 3000000000
  ) then
    raise exception 'ai quota settings update was not applied';
  end if;
end
$verify$;

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

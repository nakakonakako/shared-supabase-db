\set ON_ERROR_STOP on

begin;

insert into auth.users (id) values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

do $migration_security$
declare
  v_function oid := 'public.broadcast_price_memo_invalidation()'::regprocedure;
  v_config text[];
  v_policy_count integer;
begin
  select proconfig into v_config from pg_catalog.pg_proc where oid = v_function;
  if not (select prosecdef from pg_catalog.pg_proc where oid = v_function)
    or not ('search_path=""' = any (v_config))
    or (select rolname from pg_catalog.pg_roles where oid = (select proowner from pg_catalog.pg_proc where oid = v_function)) <> 'postgres'
    or pg_catalog.has_function_privilege('authenticated', v_function, 'EXECUTE')
    or pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
    or pg_catalog.has_function_privilege('service_role', v_function, 'EXECUTE')
    or exists (
      select 1 from pg_catalog.aclexplode(
        coalesce((select proacl from pg_catalog.pg_proc where oid = v_function),
                 pg_catalog.acldefault('f', (select proowner from pg_catalog.pg_proc where oid = v_function)))
      ) as acl where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
    ) then
    raise exception 'trigger function security attributes or execute grants are incorrect';
  end if;

  select count(*) into v_policy_count
  from pg_catalog.pg_policies
  where schemaname = 'realtime' and tablename = 'messages';
  if v_policy_count <> 1
    or not exists (
      select 1 from pg_catalog.pg_policies
      where schemaname = 'realtime'
        and tablename = 'messages'
        and policyname = 'price-memo users can receive own private broadcasts'
        and cmd = 'SELECT'
        and roles = array['authenticated']::name[]
        and qual like '%extension = ''broadcast''%'
        and qual like '%realtime.topic()%'
        and qual like '%auth.uid()%'
    )
    or exists (
      select 1 from pg_catalog.pg_policies
      where schemaname = 'realtime'
        and tablename = 'messages'
        and cmd <> 'SELECT'
    ) then
    raise exception 'Realtime receive policy is broader than the required authenticated private-topic SELECT';
  end if;

  if (select count(*) from pg_catalog.pg_trigger
      where tgrelid in (
        'public.price_folders'::regclass,
        'public.price_records'::regclass,
        'public.price_memo_items'::regclass,
        'public.price_stores'::regclass
      ) and tgname = 'price_memo_broadcast_invalidation' and not tgisinternal) <> 4 then
    raise exception 'expected exactly one broadcast trigger on each of the four price tables';
  end if;
end
$migration_security$;

-- A authenticated CRUD on all four tables creates only minimal private events.
select pg_catalog.set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
set local role authenticated;
insert into public.price_folders (id, user_id)
values ('10000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111');
insert into public.price_records (id, user_id, folder_id)
values ('30000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', '10000000-0000-4000-8000-000000000001');
insert into public.price_memo_items (id, user_id, folder_id)
values ('50000000-0000-4000-8000-000000000005', '11111111-1111-4111-8111-111111111111', '10000000-0000-4000-8000-000000000001');
insert into public.price_stores (id, user_id)
values ('70000000-0000-4000-8000-000000000007', '11111111-1111-4111-8111-111111111111');
update public.price_folders set user_id = user_id where id = '10000000-0000-4000-8000-000000000001';
update public.price_records set user_id = user_id where id = '30000000-0000-4000-8000-000000000003';
update public.price_memo_items set user_id = user_id where id = '50000000-0000-4000-8000-000000000005';
update public.price_stores set user_id = user_id where id = '70000000-0000-4000-8000-000000000007';
delete from public.price_records where id = '30000000-0000-4000-8000-000000000003';
delete from public.price_memo_items where id = '50000000-0000-4000-8000-000000000005';
delete from public.price_stores where id = '70000000-0000-4000-8000-000000000007';
reset role;

do $event_payloads$
begin
  if (select count(*) from realtime.messages) <> 11 then
    raise exception 'expected 11 direct row events, got %', (select count(*) from realtime.messages);
  end if;
  if exists (
    select 1 from realtime.messages
    where topic <> 'price-memo:user:11111111-1111-4111-8111-111111111111'
      or extension <> 'broadcast'
      or event <> 'price-memo-change'
      or not is_private
      or payload <> jsonb_build_object(
        'table', payload ->> 'table',
        'operation', payload ->> 'operation'
      )
      or payload ->> 'table' not in ('price_folders', 'price_records', 'price_memo_items', 'price_stores')
      or payload ->> 'operation' not in ('INSERT', 'UPDATE', 'DELETE')
  ) then
    raise exception 'a Broadcast event has an invalid topic, privacy, event or non-minimal payload';
  end if;
  if (select count(*) from realtime.messages where payload ->> 'operation' = 'INSERT') <> 4
    or (select count(*) from realtime.messages where payload ->> 'operation' = 'UPDATE') <> 4
    or (select count(*) from realtime.messages where payload ->> 'operation' = 'DELETE') <> 3
    or exists (
      select 1 from unnest(array['price_folders', 'price_records', 'price_memo_items', 'price_stores']) as t(table_name)
      where not exists (select 1 from realtime.messages where payload ->> 'table' = t.table_name and payload ->> 'operation' = 'INSERT')
        or not exists (select 1 from realtime.messages where payload ->> 'table' = t.table_name and payload ->> 'operation' = 'UPDATE')
    ) then
    raise exception 'one or more table operation notifications are missing';
  end if;
end
$event_payloads$;

-- Other Realtime extensions are not visible through the price-memo policy.
insert into realtime.messages (topic, extension, event, payload, is_private)
values (
  'price-memo:user:11111111-1111-4111-8111-111111111111',
  'presence',
  'unrelated',
  '{"table":"not-for-price-memo"}',
  true
);

-- SELECT is scoped to the exact topic and broadcast extension; no INSERT policy exists.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select pg_catalog.set_config('realtime.topic', 'price-memo:user:11111111-1111-4111-8111-111111111111', true);
do $own_topic$
begin
  if (select count(*) from realtime.messages) <> 11 then
    raise exception 'authenticated user could not read their own private topic';
  end if;
end
$own_topic$;
select pg_catalog.set_config('realtime.topic', 'price-memo:user:22222222-2222-4222-8222-222222222222', true);
do $other_topic$
begin
  if (select count(*) from realtime.messages) <> 0 then
    raise exception 'authenticated user read another user private topic';
  end if;
end
$other_topic$;
do $client_send$
begin
  begin
    insert into realtime.messages (topic, extension, event, payload, is_private)
    values ('price-memo:user:22222222-2222-4222-8222-222222222222', 'broadcast', 'forged', '{}', true);
    raise exception 'authenticated client unexpectedly sent a Broadcast';
  exception when insufficient_privilege then
    null;
  end;
end
$client_send$;
reset role;

set local role anon;
select pg_catalog.set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select pg_catalog.set_config('realtime.topic', 'price-memo:user:11111111-1111-4111-8111-111111111111', true);
do $anonymous$
begin
  if (select count(*) from realtime.messages) <> 0 then
    raise exception 'anonymous user read a private Broadcast';
  end if;
end
$anonymous$;
reset role;

-- A trusted owner change invalidates both the old and the new owner topic.
do $ownership_change$
declare
  v_before_id bigint := (select coalesce(max(id), 0) from realtime.messages);
begin
  insert into public.price_stores (id, user_id)
  values ('70000000-0000-4000-8000-000000000010', '11111111-1111-4111-8111-111111111111');
  v_before_id := (select coalesce(max(id), 0) from realtime.messages);
  update public.price_stores
  set user_id = '22222222-2222-4222-8222-222222222222'
  where id = '70000000-0000-4000-8000-000000000010';
  if (select count(*) from realtime.messages
      where id > v_before_id
        and payload ->> 'table' = 'price_stores'
        and payload ->> 'operation' = 'UPDATE'
        and topic in (
          'price-memo:user:11111111-1111-4111-8111-111111111111',
          'price-memo:user:22222222-2222-4222-8222-222222222222'
        )) <> 2 then
    raise exception 'owner change did not notify both previous and new owner';
  end if;
end
$ownership_change$;

-- A folder FK cascade emits child DELETE invalidations as well as the parent.
do $cascade$
declare
  v_before_id bigint;
begin
  insert into public.price_folders (id, user_id)
  values ('10000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111');
  insert into public.price_records (id, user_id, folder_id)
  values ('30000000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', '10000000-0000-4000-8000-000000000002');
  insert into public.price_memo_items (id, user_id, folder_id)
  values ('50000000-0000-4000-8000-000000000006', '11111111-1111-4111-8111-111111111111', '10000000-0000-4000-8000-000000000002');
  v_before_id := (select max(id) from realtime.messages);
  delete from public.price_folders where id = '10000000-0000-4000-8000-000000000002';
  if (select count(*) from realtime.messages
      where id > v_before_id and payload ->> 'operation' = 'DELETE') <> 3
    or (select count(*) from realtime.messages
      where id > v_before_id and payload ->> 'table' = 'price_folders' and payload ->> 'operation' = 'DELETE') <> 1
    or (select count(*) from realtime.messages
      where id > v_before_id and payload ->> 'table' = 'price_records' and payload ->> 'operation' = 'DELETE') <> 1
    or (select count(*) from realtime.messages
      where id > v_before_id and payload ->> 'table' = 'price_memo_items' and payload ->> 'operation' = 'DELETE') <> 1 then
    raise exception 'folder cascade did not notify the parent and both child tables';
  end if;
end
$cascade$;

-- The existing account deletion RPC still succeeds and its row triggers notify.
do $bulk_delete_setup$
begin
  insert into public.price_folders (id, user_id)
  values ('10000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111');
  insert into public.price_records (id, user_id, folder_id)
  values ('30000000-0000-4000-8000-000000000005', '11111111-1111-4111-8111-111111111111', '10000000-0000-4000-8000-000000000003');
  insert into public.price_memo_items (id, user_id, folder_id)
  values ('50000000-0000-4000-8000-000000000007', '11111111-1111-4111-8111-111111111111', '10000000-0000-4000-8000-000000000003');
  insert into public.price_stores (id, user_id)
  values ('70000000-0000-4000-8000-000000000008', '11111111-1111-4111-8111-111111111111');
end
$bulk_delete_setup$;
select pg_catalog.set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
set local role authenticated;
select public.delete_my_price_memo_data();
reset role;
do $bulk_delete_assertions$
begin
  if exists (
    select 1 from realtime.messages
    where payload ->> 'operation' = 'DELETE'
      and payload ->> 'table' not in ('price_folders', 'price_records', 'price_memo_items', 'price_stores')
  ) or not exists (
    select 1 from realtime.messages where topic = 'price-memo:user:11111111-1111-4111-8111-111111111111'
      and payload ->> 'table' = 'price_memo_items' and payload ->> 'operation' = 'DELETE'
  ) or not exists (
    select 1 from realtime.messages where topic = 'price-memo:user:11111111-1111-4111-8111-111111111111'
      and payload ->> 'table' = 'price_records' and payload ->> 'operation' = 'DELETE'
  ) or not exists (
    select 1 from realtime.messages where topic = 'price-memo:user:11111111-1111-4111-8111-111111111111'
      and payload ->> 'table' = 'price_folders' and payload ->> 'operation' = 'DELETE'
  ) or not exists (
    select 1 from realtime.messages where topic = 'price-memo:user:11111111-1111-4111-8111-111111111111'
      and payload ->> 'table' = 'price_stores' and payload ->> 'operation' = 'DELETE'
  ) then
    raise exception 'bulk deletion did not produce expected table invalidations';
  end if;
  if (select count(*) from auth.users) <> 2 then
    raise exception 'price-memo bulk delete changed Auth users';
  end if;
end
$bulk_delete_assertions$;

-- Failed notification delivery does not fail the user's ordinary write.
select pg_catalog.set_config('realtime.test_fail_send', 'on', true);
select pg_catalog.set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
set local role authenticated;
insert into public.price_stores (id, user_id)
values ('70000000-0000-4000-8000-000000000009', '22222222-2222-4222-8222-222222222222');
reset role;
select pg_catalog.set_config('realtime.test_fail_send', '', true);
do $send_failure$
begin
  if not exists (select 1 from public.price_stores where id = '70000000-0000-4000-8000-000000000009') then
    raise exception 'ordinary write failed when Broadcast delivery failed';
  end if;
end
$send_failure$;

-- Transaction rollback rolls its Broadcast messages back with the row change.
do $transaction_rollback$
declare
  v_before_count bigint := (select count(*) from realtime.messages);
begin
  begin
    update public.price_stores set user_id = user_id
    where id = '70000000-0000-4000-8000-000000000009';
    raise exception 'intentional transaction rollback probe';
  exception when others then
    if sqlerrm <> 'intentional transaction rollback probe' then raise; end if;
  end;
  if (select count(*) from realtime.messages) <> v_before_count then
    raise exception 'rolled back data change left a Broadcast message';
  end if;
end
$transaction_rollback$;

rollback;

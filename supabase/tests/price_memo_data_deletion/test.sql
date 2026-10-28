\set ON_ERROR_STOP on

begin;

create function public.fail_price_store_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'intentional rollback probe';
end
$$;

insert into auth.users (id) values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');
insert into public.receipts (id, user_id) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '22222222-2222-4222-8222-222222222222');
insert into public.receipt_items (id, user_id, receipt_id) values
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', '22222222-2222-4222-8222-222222222222', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
insert into public.price_folders (id, user_id) values
  ('10000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111'),
  ('20000000-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222');
insert into public.price_records (id, user_id, folder_id, receipt_item_id) values
  ('30000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', '10000000-0000-4000-8000-000000000001', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  ('40000000-0000-4000-8000-000000000004', '22222222-2222-4222-8222-222222222222', '20000000-0000-4000-8000-000000000002', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd');
insert into public.price_memo_items (id, user_id, folder_id) values
  ('50000000-0000-4000-8000-000000000005', '11111111-1111-4111-8111-111111111111', '10000000-0000-4000-8000-000000000001'),
  ('60000000-0000-4000-8000-000000000006', '22222222-2222-4222-8222-222222222222', '20000000-0000-4000-8000-000000000002');
insert into public.price_stores (id, user_id) values
  ('70000000-0000-4000-8000-000000000007', '11111111-1111-4111-8111-111111111111'),
  ('80000000-0000-4000-8000-000000000008', '22222222-2222-4222-8222-222222222222');

-- The invoker cannot use the RPC without an authenticated grant.
select pg_catalog.set_config('request.jwt.claim.sub', '', true);
set local role anon;
do $anonymous$
begin
  begin
    perform public.delete_my_price_memo_data();
    raise exception 'anonymous RPC call unexpectedly succeeded';
  exception when insufficient_privilege then
    null;
  end;
end
$anonymous$;
reset role;

-- An authenticated role with no auth.uid() is rejected by the function body.
set local role authenticated;
do $missing_identity$
begin
  begin
    perform public.delete_my_price_memo_data();
    raise exception 'unauthenticated RPC call unexpectedly succeeded';
  exception when sqlstate '28000' then
    null;
  end;
end
$missing_identity$;

-- Fail after memo items, records, and folders have been deleted; the RPC
-- statement must roll all of those changes back.
select pg_catalog.set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
reset role;
create trigger fail_store_delete before delete on public.price_stores
for each row execute function public.fail_price_store_delete();
set local role authenticated;
do $rollback$
begin
  begin
    perform public.delete_my_price_memo_data();
    raise exception 'failure probe unexpectedly succeeded';
  exception when others then
    if sqlerrm = 'failure probe unexpectedly succeeded' then raise; end if;
  end;
end
$rollback$;
reset role;
drop trigger fail_store_delete on public.price_stores;

do $rollback_assertions$
begin
  if (select count(*) from public.price_memo_items where user_id = '11111111-1111-4111-8111-111111111111') <> 1
    or (select count(*) from public.price_records where user_id = '11111111-1111-4111-8111-111111111111') <> 1
    or (select count(*) from public.price_folders where user_id = '11111111-1111-4111-8111-111111111111') <> 1
    or (select count(*) from public.price_stores where user_id = '11111111-1111-4111-8111-111111111111') <> 1 then
    raise exception 'partial deletion remained after the forced failure';
  end if;
end
$rollback_assertions$;

-- Successful deletion clears only the caller's four price-memo tables.
set local role authenticated;
select public.delete_my_price_memo_data();
reset role;

do $success_assertions$
begin
  if (select count(*) from public.price_memo_items where user_id = '11111111-1111-4111-8111-111111111111') <> 0
    or (select count(*) from public.price_records where user_id = '11111111-1111-4111-8111-111111111111') <> 0
    or (select count(*) from public.price_folders where user_id = '11111111-1111-4111-8111-111111111111') <> 0
    or (select count(*) from public.price_stores where user_id = '11111111-1111-4111-8111-111111111111') <> 0 then
    raise exception 'caller data was not fully deleted';
  end if;
  if (select count(*) from public.price_memo_items where user_id = '22222222-2222-4222-8222-222222222222') <> 1
    or (select count(*) from public.price_records where user_id = '22222222-2222-4222-8222-222222222222') <> 1
    or (select count(*) from public.price_folders where user_id = '22222222-2222-4222-8222-222222222222') <> 1
    or (select count(*) from public.price_stores where user_id = '22222222-2222-4222-8222-222222222222') <> 1 then
    raise exception 'another user data was changed';
  end if;
  if (select count(*) from auth.users) <> 2
    or (select count(*) from public.receipts) <> 2
    or (select count(*) from public.receipt_items) <> 2 then
    raise exception 'Auth or receipt-app data was changed';
  end if;
end
$success_assertions$;

-- Empty targets are a successful no-op.
set local role authenticated;
select public.delete_my_price_memo_data();
reset role;

rollback;

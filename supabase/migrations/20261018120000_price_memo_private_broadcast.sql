-- Send invalidation-only notifications to each price-memo user's private topic.
-- The client must re-fetch rows through the existing RLS-protected APIs.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $preflight$
begin
  if pg_catalog.to_regclass('realtime.messages') is null then
    raise exception 'price-memo Broadcast requires realtime.messages';
  end if;

  if not (
    select relrowsecurity
    from pg_catalog.pg_class
    where oid = 'realtime.messages'::regclass
  ) then
    raise exception 'price-memo Broadcast requires RLS on realtime.messages';
  end if;

  if pg_catalog.to_regprocedure('realtime.send(jsonb,text,text,boolean)') is null then
    raise exception 'price-memo Broadcast requires realtime.send(jsonb,text,text,boolean)';
  end if;

  if pg_catalog.to_regprocedure('realtime.topic()') is null
    or pg_catalog.to_regprocedure('auth.uid()') is null then
    raise exception 'price-memo Broadcast requires realtime.topic() and auth.uid()';
  end if;

  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'postgres') then
    raise exception 'price-memo Broadcast requires the postgres function owner';
  end if;

  if not pg_catalog.has_function_privilege(
    'postgres',
    'realtime.send(jsonb,text,text,boolean)',
    'EXECUTE'
  ) then
    raise exception 'postgres cannot execute realtime.send(jsonb,text,text,boolean)';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'realtime'
      and tablename = 'messages'
  ) then
    raise exception 'price-memo Broadcast requires review of existing realtime.messages policies';
  end if;

  if (
    select count(*)
    from pg_catalog.pg_class as c
    join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = any (array[
        'price_folders', 'price_records', 'price_memo_items', 'price_stores'
      ])
      and c.relkind in ('r', 'p')
  ) <> 4 then
    raise exception 'price-memo Broadcast expected all four public price tables';
  end if;
end
$preflight$;

create policy "price-memo users can receive own private broadcasts"
  on realtime.messages
  for select
  to authenticated
  using (
    extension = 'broadcast'
    and auth.uid() is not null
    and realtime.topic() = 'price-memo:user:' || auth.uid()::text
  );

create or replace function public.broadcast_price_memo_invalidation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_old_user_id uuid;
  v_new_user_id uuid;
  v_topic text;
begin
  if tg_op <> 'INSERT' then
    v_old_user_id := old.user_id;
  end if;

  if tg_op <> 'DELETE' then
    v_new_user_id := new.user_id;
  end if;

  if v_old_user_id is not null then
    v_topic := 'price-memo:user:' || v_old_user_id::text;
    begin
      perform realtime.send(
        pg_catalog.jsonb_build_object(
          'table', tg_table_name,
          'operation', tg_op
        ),
        'price-memo-change',
        v_topic,
        true
      );
    exception when others then
      raise warning 'price-memo Broadcast failed for %.% operation % (SQLSTATE %)',
        tg_table_schema, tg_table_name, tg_op, sqlstate;
    end;
  end if;

  if v_new_user_id is not null
    and v_new_user_id is distinct from v_old_user_id then
    v_topic := 'price-memo:user:' || v_new_user_id::text;
    begin
      perform realtime.send(
        pg_catalog.jsonb_build_object(
          'table', tg_table_name,
          'operation', tg_op
        ),
        'price-memo-change',
        v_topic,
        true
      );
    exception when others then
      raise warning 'price-memo Broadcast failed for %.% operation % (SQLSTATE %)',
        tg_table_schema, tg_table_name, tg_op, sqlstate;
    end;
  end if;

  return null;
end
$function$;

alter function public.broadcast_price_memo_invalidation() owner to postgres;
revoke all on function public.broadcast_price_memo_invalidation()
  from public, anon, authenticated, service_role;

create trigger price_memo_broadcast_invalidation
  after insert or update or delete on public.price_folders
  for each row execute function public.broadcast_price_memo_invalidation();

create trigger price_memo_broadcast_invalidation
  after insert or update or delete on public.price_records
  for each row execute function public.broadcast_price_memo_invalidation();

create trigger price_memo_broadcast_invalidation
  after insert or update or delete on public.price_memo_items
  for each row execute function public.broadcast_price_memo_invalidation();

create trigger price_memo_broadcast_invalidation
  after insert or update or delete on public.price_stores
  for each row execute function public.broadcast_price_memo_invalidation();

commit;

-- Atomic shared-DB operations called by price-memo.
-- Both functions run as the caller so table grants and RLS remain in force.

begin;

create or replace function public.rename_price_store(
  p_store_id uuid,
  p_name text
)
returns public.price_stores
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_store public.price_stores%rowtype;
  v_old_name text;
  v_name text := pg_catalog.btrim(p_name);
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_store_id is null or p_name is null or v_name = '' then
    raise exception using errcode = '22023', message = 'store id and non-empty name are required';
  end if;

  select s.* into v_store
  from public.price_stores as s
  where s.id = p_store_id
    and s.user_id = v_user_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'store not found';
  end if;
  v_old_name := v_store.name;

  update public.price_stores as s
  set name = v_name
  where s.id = v_store.id
    and s.user_id = v_user_id
  returning s.* into v_store;

  if v_old_name is distinct from v_store.name then
    update public.price_records as r
    set store_name = v_store.name,
        updated_at = pg_catalog.now()
    where r.user_id = v_user_id
      and r.store_name = v_old_name;
  end if;

  return v_store;
end
$function$;

create or replace function public.reorder_price_memo_items(
  p_expected_folder_ids uuid[],
  p_folder_ids uuid[]
)
returns void
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_current_ids uuid[];
  v_expected_ids uuid[];
  v_requested_ids uuid[];
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_expected_folder_ids is null or p_folder_ids is null
     or coalesce(pg_catalog.array_ndims(p_expected_folder_ids), 1) <> 1
     or coalesce(pg_catalog.array_ndims(p_folder_ids), 1) <> 1
     or exists (
       select 1 from pg_catalog.unnest(p_expected_folder_ids) as x(id)
       where x.id is null
     )
     or exists (
       select 1 from pg_catalog.unnest(p_folder_ids) as x(id)
       where x.id is null
     ) then
    raise exception using errcode = '22023', message = 'folder id arrays must be one-dimensional and contain no null ids';
  end if;
  if (select pg_catalog.count(*) <> pg_catalog.count(distinct x.id)
      from pg_catalog.unnest(p_expected_folder_ids) as x(id))
     or (select pg_catalog.count(*) <> pg_catalog.count(distinct x.id)
         from pg_catalog.unnest(p_folder_ids) as x(id)) then
    raise exception using errcode = '22023', message = 'folder id arrays must not contain duplicates';
  end if;

  -- Serialize memo writes, including legacy direct add/remove requests, while
  -- the snapshot is checked and the complete order is updated.
  lock table public.price_memo_items in share row exclusive mode;

  -- Lock the caller's rows in a stable order before reading the current list.
  perform m.id
  from public.price_memo_items as m
  where m.user_id = v_user_id
  order by m.id
  for update;

  select coalesce(
           pg_catalog.array_agg(m.folder_id order by m.sort_order, m.created_at, m.id),
           array[]::uuid[]
         )
    into v_current_ids
  from public.price_memo_items as m
  where m.user_id = v_user_id;

  select coalesce(
           pg_catalog.array_agg(x.id order by x.position), array[]::uuid[]
         )
    into v_expected_ids
  from pg_catalog.unnest(p_expected_folder_ids) with ordinality as x(id, position);
  select coalesce(
           pg_catalog.array_agg(x.id order by x.position), array[]::uuid[]
         )
    into v_requested_ids
  from pg_catalog.unnest(p_folder_ids) with ordinality as x(id, position);

  if v_current_ids is distinct from v_expected_ids
     or pg_catalog.cardinality(v_current_ids) <> pg_catalog.cardinality(v_requested_ids)
     or exists (
       select 1
       from pg_catalog.unnest(v_requested_ids) as requested(id)
       where not (requested.id = any(v_current_ids))
     ) then
    raise exception using errcode = 'PM001', message = 'memo list changed; reload before reordering';
  end if;

  update public.price_memo_items as m
  set sort_order = (requested.position - 1)::integer
  from pg_catalog.unnest(v_requested_ids) with ordinality as requested(id, position)
  where m.user_id = v_user_id
    and m.folder_id = requested.id;
end
$function$;

revoke all on function public.rename_price_store(uuid, text) from public, anon;
revoke all on function public.reorder_price_memo_items(uuid[], uuid[]) from public, anon;
grant execute on function public.rename_price_store(uuid, text) to authenticated;
grant execute on function public.reorder_price_memo_items(uuid[], uuid[]) to authenticated;

notify pgrst, 'reload schema';

commit;

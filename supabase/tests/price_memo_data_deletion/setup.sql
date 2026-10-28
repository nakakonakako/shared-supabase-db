\set ON_ERROR_STOP on

create role anon nologin;
create role authenticated nologin;
create role service_role nologin;

create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(pg_catalog.current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

create table public.receipts (
  id uuid primary key,
  user_id uuid not null references auth.users(id)
);
create table public.receipt_items (
  id uuid primary key,
  user_id uuid not null references auth.users(id),
  receipt_id uuid not null references public.receipts(id)
);
create table public.price_folders (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade
);
create table public.price_records (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  folder_id uuid not null references public.price_folders(id) on delete cascade,
  receipt_item_id uuid references public.receipt_items(id) on delete set null
);
create table public.price_memo_items (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  folder_id uuid not null references public.price_folders(id) on delete cascade
);
create table public.price_stores (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade
);

do $rls$
declare
  v_table text;
begin
  foreach v_table in array array[
    'price_folders', 'price_records', 'price_memo_items', 'price_stores'
  ] loop
    execute pg_catalog.format('alter table public.%I enable row level security', v_table);
    execute pg_catalog.format(
      'create policy owner_all on public.%I for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id)',
      v_table
    );
    execute pg_catalog.format('grant select, insert, update, delete on public.%I to authenticated', v_table);
  end loop;
end
$rls$;

grant usage on schema auth, public to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;

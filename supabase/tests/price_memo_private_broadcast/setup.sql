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

create schema realtime;
create table realtime.messages (
  id bigint generated always as identity primary key,
  topic text not null,
  extension text not null,
  event text not null,
  payload jsonb not null,
  is_private boolean not null
);
alter table realtime.messages enable row level security;
create function realtime.topic()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(pg_catalog.current_setting('realtime.topic', true), '')
$$;
create function realtime.send(jsonb, text, text, boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if pg_catalog.current_setting('realtime.test_fail_send', true) = 'on' then
    raise exception 'intentional isolated send failure';
  end if;
  insert into realtime.messages (payload, event, topic, is_private, extension)
  values ($1, $2, $3, $4, 'broadcast');
end
$function$;

create table public.price_folders (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade
);
create table public.price_records (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  folder_id uuid not null references public.price_folders(id) on delete cascade
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

grant usage on schema auth, public, realtime to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
grant execute on function realtime.topic() to anon, authenticated;
grant select, insert on realtime.messages to anon, authenticated;

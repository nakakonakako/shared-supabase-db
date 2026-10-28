-- B: canonical store names per user (picker source for records)

create table "public"."price_stores" (
  "id"         uuid                     not null default gen_random_uuid(),
  "user_id"    uuid                     not null,
  "name"       text                     not null,
  "created_at" timestamp with time zone not null default timezone('utc'::text, now()),
  constraint "price_stores_pkey" primary key (id),
  constraint "price_stores_user_id_name_key" unique (user_id, name),
  constraint "price_stores_name_not_blank" check (char_length(trim(name)) > 0)
);

alter table "public"."price_stores"
  enable row level security;

alter table "public"."price_stores"
  add constraint "price_stores_user_id_fkey"
  foreign key (user_id) references auth.users (id) on delete cascade;

create policy "Enable ALL operations for users based on user_id"
  on "public"."price_stores"
  for all
  to "authenticated"
  using ((auth.uid() = user_id))
  with check ((auth.uid() = user_id));

grant delete, insert, references, select, trigger, truncate, update
  on table "public"."price_stores"
  to "anon", "authenticated", "service_role";

create index "price_stores_user_id_idx" on "public"."price_stores" ("user_id");

-- Backfill from existing records
insert into "public"."price_stores" ("user_id", "name")
select distinct "user_id", trim("store_name")
from "public"."price_records"
where char_length(trim("store_name")) > 0
on conflict ("user_id", "name") do nothing;

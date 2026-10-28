-- Persist display order for folders and records (shared across memo / folders UI)

alter table "public"."price_folders"
  add column if not exists "sort_order" integer not null default 0;

alter table "public"."price_records"
  add column if not exists "sort_order" integer not null default 0;

-- Backfill folders: current name order per user
with ranked as (
  select
    id,
    (row_number() over (partition by user_id order by name asc, created_at asc) - 1)::integer as rn
  from public.price_folders
)
update public.price_folders f
set sort_order = ranked.rn
from ranked
where f.id = ranked.id;

-- Backfill records: recorded_at desc within folder (matches previous list default)
with ranked as (
  select
    id,
    (row_number() over (
      partition by folder_id
      order by recorded_at desc, created_at desc
    ) - 1)::integer as rn
  from public.price_records
)
update public.price_records r
set sort_order = ranked.rn
from ranked
where r.id = ranked.id;

create index if not exists "price_folders_user_id_sort_order_idx"
  on "public"."price_folders" ("user_id", "sort_order");

create index if not exists "price_records_folder_id_sort_order_idx"
  on "public"."price_records" ("folder_id", "sort_order");

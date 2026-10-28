-- B (price-memo): 手動フォルダ + 厳密単価レコード
-- A (receipt-manager) と同一 Supabase に同居。Auth / user_id は共有。

create table "public"."price_folders" (
  "id"         uuid                     not null default gen_random_uuid(),
  "user_id"    uuid                     not null,
  "name"       text                     not null,
  "created_at" timestamp with time zone not null default timezone('utc'::text, now()),
  "updated_at" timestamp with time zone not null default timezone('utc'::text, now()),
  constraint "price_folders_pkey" primary key (id),
  constraint "price_folders_user_id_name_key" unique (user_id, name),
  constraint "price_folders_name_not_blank" check (char_length(trim(name)) > 0)
);

alter table "public"."price_folders"
  enable row level security;

create table "public"."price_records" (
  "id"               uuid                     not null default gen_random_uuid(),
  "user_id"          uuid                     not null,
  "folder_id"        uuid                     not null,
  "recorded_at"      date                     not null,
  "store_name"       text                     not null,
  "price"            integer                  not null,
  "amount"           numeric                  not null,
  "unit"             text                     not null,
  "note"             text,
  "receipt_item_id"  uuid,
  "label_image_path" text,
  "created_at"       timestamp with time zone not null default timezone('utc'::text, now()),
  "updated_at"       timestamp with time zone not null default timezone('utc'::text, now()),
  constraint "price_records_pkey" primary key (id),
  constraint "price_records_price_nonnegative" check (price >= 0),
  constraint "price_records_amount_positive" check (amount > 0),
  constraint "price_records_unit_check" check (unit = any (array['g'::text, 'ml'::text, 'piece'::text])),
  constraint "price_records_store_name_not_blank" check (char_length(trim(store_name)) > 0)
);

alter table "public"."price_records"
  enable row level security;

alter table "public"."price_folders"
  add constraint "price_folders_user_id_fkey"
  foreign key (user_id) references auth.users (id) on delete cascade;

alter table "public"."price_records"
  add constraint "price_records_user_id_fkey"
  foreign key (user_id) references auth.users (id) on delete cascade;

alter table "public"."price_records"
  add constraint "price_records_folder_id_fkey"
  foreign key (folder_id) references public.price_folders (id) on delete cascade;

alter table "public"."price_records"
  add constraint "price_records_receipt_item_id_fkey"
  foreign key (receipt_item_id) references public.receipt_items (id) on delete set null;

create policy "Enable ALL operations for users based on user_id"
  on "public"."price_folders"
  for all
  to "authenticated"
  using ((auth.uid() = user_id))
  with check ((auth.uid() = user_id));

create policy "Enable ALL operations for users based on user_id"
  on "public"."price_records"
  for all
  to "authenticated"
  using ((auth.uid() = user_id))
  with check ((auth.uid() = user_id));

grant delete, insert, references, select, trigger, truncate, update
  on table "public"."price_folders"
  to "anon", "authenticated", "service_role";

grant delete, insert, references, select, trigger, truncate, update
  on table "public"."price_records"
  to "anon", "authenticated", "service_role";

create index "price_folders_user_id_idx" on "public"."price_folders" ("user_id");
create index "price_records_user_id_folder_id_idx" on "public"."price_records" ("user_id", "folder_id");
create index "price_records_recorded_at_idx" on "public"."price_records" ("recorded_at");

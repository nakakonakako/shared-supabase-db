-- B: shopping memo list is independent from folder catalog.
-- Memo rows reference price_folders; removing from memo does not delete the folder.

create table "public"."price_memo_items" (
  "id"         uuid                     not null default gen_random_uuid(),
  "user_id"    uuid                     not null,
  "folder_id"  uuid                     not null,
  "sort_order" integer                  not null default 0,
  "created_at" timestamp with time zone not null default timezone('utc'::text, now()),
  constraint "price_memo_items_pkey" primary key (id),
  constraint "price_memo_items_user_id_folder_id_key" unique (user_id, folder_id)
);

alter table "public"."price_memo_items"
  enable row level security;

alter table "public"."price_memo_items"
  add constraint "price_memo_items_user_id_fkey"
  foreign key (user_id) references auth.users (id) on delete cascade;

alter table "public"."price_memo_items"
  add constraint "price_memo_items_folder_id_fkey"
  foreign key (folder_id) references public.price_folders (id) on delete cascade;

create policy "Enable ALL operations for users based on user_id"
  on "public"."price_memo_items"
  for all
  to "authenticated"
  using ((auth.uid() = user_id))
  with check ((auth.uid() = user_id));

grant delete, insert, references, select, trigger, truncate, update
  on table "public"."price_memo_items"
  to "anon", "authenticated", "service_role";

create index "price_memo_items_user_id_sort_order_idx"
  on "public"."price_memo_items" ("user_id", "sort_order");

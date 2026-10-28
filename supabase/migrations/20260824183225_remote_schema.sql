alter default privileges for role "postgres" in schema "public" revoke all on sequences from "anon";

alter default privileges for role "postgres" in schema "public" revoke all on sequences from "authenticated";

alter default privileges for role "postgres" in schema "public" revoke all on sequences from "service_role";

alter default privileges for role "postgres" in schema "public" revoke all on tables from "anon";

alter default privileges for role "postgres" in schema "public" revoke all on tables from "authenticated";

alter default privileges for role "postgres" in schema "public" revoke all on tables from "service_role";

create table "public"."chat_messages" (
  "id"         uuid                     not null default gen_random_uuid(),
  "user_id"    uuid                     not null,
  "role"       text                     not null,
  "content"    text                     not null,
  "created_at" timestamp with time zone not null default timezone('utc'::text, now()),
  constraint "chat_messages_pkey" primary key (id),
  constraint "chat_messages_role_check" check ((role = ANY (ARRAY['user'::text, 'assistant'::text])))
);

alter table "public"."chat_messages"
  enable row level security;

create table "public"."csv_presets" (
  "id"           uuid                     not null default gen_random_uuid(),
  "user_id"      uuid                     not null,
  "name"         text                     not null,
  "mapping"      jsonb                    not null,
  "created_at"   timestamp with time zone not null default timezone('utc'::text, now()),
  "icon"         text,
  "last_used_at" timestamp with time zone,
  constraint "csv_presets_pkey" primary key (id)
);

alter table "public"."csv_presets"
  enable row level security;

create table "public"."csv_transactions" (
  "id"         uuid                     not null default gen_random_uuid(),
  "user_id"    uuid                     not null,
  "date"       date                     not null,
  "store"      text                     not null,
  "price"      integer                  not null,
  "created_at" timestamp with time zone not null default timezone('utc'::text, now()),
  constraint "csv_transactions_pkey" primary key (id)
);

alter table "public"."csv_transactions"
  enable row level security;

create table "public"."memo_rows" (
  "id"         uuid                     not null default gen_random_uuid(),
  "user_id"    uuid                     not null,
  "query"      text                     not null default ''::text,
  "sort_order" integer                  not null default 0,
  "created_at" timestamp with time zone not null default timezone('utc'::text, now()),
  constraint "memo_rows_pkey" primary key (id)
);

alter table "public"."memo_rows"
  enable row level security;

create table "public"."receipt_items" (
  "id"            uuid                     not null default gen_random_uuid(),
  "receipt_id"    uuid                     not null,
  "user_id"       uuid                     not null,
  "item_name"     text                     not null,
  "price"         integer                  not null,
  "main_category" text,
  "sub_category"  text,
  "search_tags"   text[]                   default '{}'::text[],
  "is_comparable" boolean                  default true,
  "created_at"    timestamp with time zone not null default timezone('utc'::text, now()),
  constraint "receipt_items_pkey" primary key (id)
);

alter table "public"."receipt_items"
  enable row level security;

create table "public"."receipts" (
  "id"             uuid                     not null default gen_random_uuid(),
  "user_id"        uuid                     not null,
  "date"           date                     not null,
  "store_name"     text                     not null,
  "total_amount"   integer                  not null,
  "payment_method" text,
  "created_at"     timestamp with time zone not null default timezone('utc'::text, now()),
  constraint "receipts_pkey" primary key (id)
);

alter table "public"."receipts"
  enable row level security;

alter table "public"."chat_messages"
  add constraint "chat_messages_user_id_fkey" foreign key (user_id) references auth.users(id);

alter table "public"."csv_presets"
  add constraint "csv_presets_user_id_fkey" foreign key (user_id) references auth.users(id);

alter table "public"."csv_transactions"
  add constraint "csv_transactions_user_id_fkey" foreign key (user_id) references auth.users(id);

alter table "public"."memo_rows"
  add constraint "memo_rows_user_id_fkey" foreign key (user_id) references auth.users(id) on delete cascade;

alter table "public"."receipt_items"
  add constraint "receipt_items_user_id_fkey" foreign key (user_id) references auth.users(id);

alter table "public"."receipt_items"
  add constraint "receipt_items_receipt_id_fkey" foreign key (receipt_id) references public.receipts(id) on delete cascade;

alter table "public"."receipts"
  add constraint "receipts_user_id_fkey" foreign key (user_id) references auth.users(id);

create policy "Enable ALL operations for users based on user_id" on "public"."chat_messages"
  for all
  to "authenticated"
  using ((auth.uid() = user_id))
  with check ((auth.uid() = user_id));

create policy "Enable ALL operations for users based on user_id" on "public"."csv_presets"
  for all
  to "authenticated"
  using ((auth.uid() = user_id))
  with check ((auth.uid() = user_id));

create policy "Users can delete own csv_transactions" on "public"."csv_transactions"
  for delete
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can insert own csv_transactions" on "public"."csv_transactions"
  for insert
  to PUBLIC
  with check ((auth.uid() = user_id));

create policy "Users can update own csv_transactions" on "public"."csv_transactions"
  for update
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can view own csv_transactions" on "public"."csv_transactions"
  for select
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can delete own memo_rows" on "public"."memo_rows"
  for delete
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can insert own memo_rows" on "public"."memo_rows"
  for insert
  to PUBLIC
  with check ((auth.uid() = user_id));

create policy "Users can update own memo_rows" on "public"."memo_rows"
  for update
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can view own memo_rows" on "public"."memo_rows"
  for select
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can delete own receipt_items" on "public"."receipt_items"
  for delete
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can insert own receipt_items" on "public"."receipt_items"
  for insert
  to PUBLIC
  with check ((auth.uid() = user_id));

create policy "Users can update own receipt_items" on "public"."receipt_items"
  for update
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can view own receipt_items" on "public"."receipt_items"
  for select
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can delete own receipts" on "public"."receipts"
  for delete
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can insert own receipts" on "public"."receipts"
  for insert
  to PUBLIC
  with check ((auth.uid() = user_id));

create policy "Users can update own receipts" on "public"."receipts"
  for update
  to PUBLIC
  using ((auth.uid() = user_id));

create policy "Users can view own receipts" on "public"."receipts"
  for select
  to PUBLIC
  using ((auth.uid() = user_id));

grant delete, insert, maintain, references, select, trigger, truncate, update on table "public"."chat_messages" to "anon", "authenticated", "postgres", "service_role";

grant delete, insert, maintain, references, select, trigger, truncate, update on table "public"."csv_presets" to "anon", "authenticated", "postgres", "service_role";

grant delete, insert, maintain, references, select, trigger, truncate, update on table "public"."csv_transactions" to "anon", "authenticated", "postgres", "service_role";

grant delete, insert, maintain, references, select, trigger, truncate, update on table "public"."memo_rows" to "anon", "authenticated", "postgres", "service_role";

grant delete, insert, maintain, references, select, trigger, truncate, update on table "public"."receipt_items" to "anon", "authenticated", "postgres", "service_role";

grant delete, insert, maintain, references, select, trigger, truncate, update on table "public"."receipts" to "anon", "authenticated", "postgres", "service_role";

alter default privileges for role "postgres" in schema "public" grant select, update, usage on sequences to "anon";

alter default privileges for role "postgres" in schema "public" grant select, update, usage on sequences to "authenticated";

alter default privileges for role "postgres" in schema "public" grant select, update, usage on sequences to "service_role";

alter default privileges for role "postgres" in schema "public" grant execute on FUNCTIONS to "anon";

alter default privileges for role "postgres" in schema "public" grant execute on FUNCTIONS to "authenticated";

alter default privileges for role "postgres" in schema "public" grant execute on FUNCTIONS to "service_role";

alter default privileges for role "postgres" in schema "public" grant delete, insert, maintain, references, select, trigger, truncate, update on tables to "anon";

alter default privileges for role "postgres" in schema "public" grant delete, insert, maintain, references, select, trigger, truncate, update on tables to "authenticated";

alter default privileges for role "postgres" in schema "public" grant delete, insert, maintain, references, select, trigger, truncate, update on tables to "service_role";


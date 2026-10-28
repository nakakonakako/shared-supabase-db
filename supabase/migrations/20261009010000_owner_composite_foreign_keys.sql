-- Owner-scoped foreign keys for the shared receipt / price tables.
-- Existing primary keys stay in place. Child rows must reference a parent
-- owned by the same user_id. This migration does not update, delete, or
-- reassign any rows. A preflight failure raises counts only and rolls back
-- with the explicit transaction below (Supabase CLI does not wrap migration
-- SQL in BEGIN/COMMIT).

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

lock table
  public.price_folders,
  public.price_memo_items,
  public.price_records,
  public.receipt_items,
  public.receipts
in share row exclusive mode;

do $preflight$
declare
  price_records_folder_owner_mismatch bigint;
  price_records_folder_missing_parent bigint;
  price_memo_items_folder_owner_mismatch bigint;
  price_memo_items_folder_missing_parent bigint;
  price_records_receipt_item_owner_mismatch bigint;
  price_records_receipt_item_missing_parent bigint;
  receipt_items_receipt_owner_mismatch bigint;
  receipt_items_receipt_missing_parent bigint;
begin
  select count(*) into price_records_folder_owner_mismatch
  from public.price_records as child
  join public.price_folders as parent on parent.id = child.folder_id
  where parent.user_id is distinct from child.user_id;

  select count(*) into price_records_folder_missing_parent
  from public.price_records as child
  where not exists (
    select 1
    from public.price_folders as parent
    where parent.id = child.folder_id
  );

  select count(*) into price_memo_items_folder_owner_mismatch
  from public.price_memo_items as child
  join public.price_folders as parent on parent.id = child.folder_id
  where parent.user_id is distinct from child.user_id;

  select count(*) into price_memo_items_folder_missing_parent
  from public.price_memo_items as child
  where not exists (
    select 1
    from public.price_folders as parent
    where parent.id = child.folder_id
  );

  select count(*) into price_records_receipt_item_owner_mismatch
  from public.price_records as child
  join public.receipt_items as parent on parent.id = child.receipt_item_id
  where child.receipt_item_id is not null
    and parent.user_id is distinct from child.user_id;

  select count(*) into price_records_receipt_item_missing_parent
  from public.price_records as child
  where child.receipt_item_id is not null
    and not exists (
      select 1
      from public.receipt_items as parent
      where parent.id = child.receipt_item_id
    );

  select count(*) into receipt_items_receipt_owner_mismatch
  from public.receipt_items as child
  join public.receipts as parent on parent.id = child.receipt_id
  where parent.user_id is distinct from child.user_id;

  select count(*) into receipt_items_receipt_missing_parent
  from public.receipt_items as child
  where not exists (
    select 1
    from public.receipts as parent
    where parent.id = child.receipt_id
  );

  if price_records_folder_owner_mismatch > 0
    or price_records_folder_missing_parent > 0
    or price_memo_items_folder_owner_mismatch > 0
    or price_memo_items_folder_missing_parent > 0
    or price_records_receipt_item_owner_mismatch > 0
    or price_records_receipt_item_missing_parent > 0
    or receipt_items_receipt_owner_mismatch > 0
    or receipt_items_receipt_missing_parent > 0
  then
    raise exception
      'owner integrity preflight failed before constraint changes: price_records_folder owner_mismatch=% missing_parent=%, price_memo_items_folder owner_mismatch=% missing_parent=%, price_records_receipt_item owner_mismatch=% missing_parent=%, receipt_items_receipt owner_mismatch=% missing_parent=%',
      price_records_folder_owner_mismatch,
      price_records_folder_missing_parent,
      price_memo_items_folder_owner_mismatch,
      price_memo_items_folder_missing_parent,
      price_records_receipt_item_owner_mismatch,
      price_records_receipt_item_missing_parent,
      receipt_items_receipt_owner_mismatch,
      receipt_items_receipt_missing_parent;
  end if;
end
$preflight$;

alter table public.price_folders
  add constraint price_folders_user_id_id_key unique (user_id, id);

alter table public.receipt_items
  add constraint receipt_items_user_id_id_key unique (user_id, id);

alter table public.receipts
  add constraint receipts_user_id_id_key unique (user_id, id);

alter table public.price_records
  drop constraint price_records_folder_id_fkey;

alter table public.price_memo_items
  drop constraint price_memo_items_folder_id_fkey;

alter table public.price_records
  drop constraint price_records_receipt_item_id_fkey;

alter table public.receipt_items
  drop constraint receipt_items_receipt_id_fkey;

alter table public.price_records
  add constraint price_records_user_id_folder_id_fkey
  foreign key (user_id, folder_id)
  references public.price_folders (user_id, id)
  on delete cascade;

alter table public.price_memo_items
  add constraint price_memo_items_user_id_folder_id_fkey
  foreign key (user_id, folder_id)
  references public.price_folders (user_id, id)
  on delete cascade;

alter table public.price_records
  add constraint price_records_user_id_receipt_item_id_fkey
  foreign key (user_id, receipt_item_id)
  references public.receipt_items (user_id, id)
  match simple
  on delete set null (receipt_item_id);

alter table public.receipt_items
  add constraint receipt_items_user_id_receipt_id_fkey
  foreign key (user_id, receipt_id)
  references public.receipts (user_id, id)
  on delete cascade;

-- PostgREST schema cache reload. NOTIFY is transactional: PostgreSQL
-- delivers it only after COMMIT below. A preflight failure rolls the
-- transaction back and discards the notification.
notify pgrst, 'reload schema';

commit;

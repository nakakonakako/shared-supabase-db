-- Read-only counts for the four owner-scoped relationships.
-- Reports owner mismatches and missing parents only. Selects no identifiers
-- or row content. Safe to run before or after
-- supabase/migrations/20261009010000_owner_composite_foreign_keys.sql.

begin transaction read only;

select
  relationship,
  owner_mismatch_count,
  missing_parent_count
from (
  select
    'price_records.folder_id -> price_folders'::text as relationship,
    (
      select count(*)
      from public.price_records as child
      join public.price_folders as parent on parent.id = child.folder_id
      where parent.user_id is distinct from child.user_id
    ) as owner_mismatch_count,
    (
      select count(*)
      from public.price_records as child
      where not exists (
        select 1
        from public.price_folders as parent
        where parent.id = child.folder_id
      )
    ) as missing_parent_count
  union all
  select
    'price_memo_items.folder_id -> price_folders'::text,
    (
      select count(*)
      from public.price_memo_items as child
      join public.price_folders as parent on parent.id = child.folder_id
      where parent.user_id is distinct from child.user_id
    ),
    (
      select count(*)
      from public.price_memo_items as child
      where not exists (
        select 1
        from public.price_folders as parent
        where parent.id = child.folder_id
      )
    )
  union all
  select
    'price_records.receipt_item_id -> receipt_items'::text,
    (
      select count(*)
      from public.price_records as child
      join public.receipt_items as parent on parent.id = child.receipt_item_id
      where child.receipt_item_id is not null
        and parent.user_id is distinct from child.user_id
    ),
    (
      select count(*)
      from public.price_records as child
      where child.receipt_item_id is not null
        and not exists (
          select 1
          from public.receipt_items as parent
          where parent.id = child.receipt_item_id
        )
    )
  union all
  select
    'receipt_items.receipt_id -> receipts'::text,
    (
      select count(*)
      from public.receipt_items as child
      join public.receipts as parent on parent.id = child.receipt_id
      where parent.user_id is distinct from child.user_id
    ),
    (
      select count(*)
      from public.receipt_items as child
      where not exists (
        select 1
        from public.receipts as parent
        where parent.id = child.receipt_id
      )
    )
) as counts
order by relationship;

commit;

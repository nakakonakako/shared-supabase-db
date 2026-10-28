-- Remove memo / price-compare artifacts from Project A.
-- memo_rows and is_comparable existed only for the memo price-trend feature.

drop policy if exists "Users can delete own memo_rows" on "public"."memo_rows";
drop policy if exists "Users can insert own memo_rows" on "public"."memo_rows";
drop policy if exists "Users can update own memo_rows" on "public"."memo_rows";
drop policy if exists "Users can view own memo_rows" on "public"."memo_rows";

drop table if exists "public"."memo_rows";

alter table "public"."receipt_items"
  drop column if exists "is_comparable";

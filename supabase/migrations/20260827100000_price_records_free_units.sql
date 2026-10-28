-- Allow free-form units beyond g / ml / piece (e.g. kg, 枚, L).
alter table "public"."price_records"
  drop constraint if exists "price_records_unit_check";

alter table "public"."price_records"
  add constraint "price_records_unit_not_blank"
  check (char_length(trim(unit)) > 0);

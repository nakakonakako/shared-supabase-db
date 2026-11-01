begin;

set local lock_timeout = '5s';
set local statement_timeout = '15s';

alter table public.price_folders
  add column reading text;

notify pgrst, 'reload schema';

commit;

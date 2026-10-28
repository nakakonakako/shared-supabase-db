-- Let an authenticated price-memo user remove only their own B-side data.
-- The invoker role and existing RLS policies remain in force.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

create or replace function public.delete_my_price_memo_data()
returns void
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;

  delete from public.price_memo_items as m
  where m.user_id = v_user_id;

  delete from public.price_records as r
  where r.user_id = v_user_id;

  delete from public.price_folders as f
  where f.user_id = v_user_id;

  delete from public.price_stores as s
  where s.user_id = v_user_id;
end
$function$;

revoke all on function public.delete_my_price_memo_data() from public, anon, service_role;
grant execute on function public.delete_my_price_memo_data() to authenticated;

notify pgrst, 'reload schema';

commit;

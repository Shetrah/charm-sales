begin;

-- Restore the RPC used by the admin Staffs performance view. This is kept
-- idempotent so it can be applied safely to databases that missed migration 064.
create or replace function charm.people_sales_summary(p_from date,p_to date)
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
 a bigint:=charm.require_actor();
 v_from date:=coalesce(p_from,(now() at time zone 'Africa/Nairobi')::date);
 v_to date:=coalesce(p_to,(now() at time zone 'Africa/Nairobi')::date);
 v_start timestamptz;
 v_end timestamptz;
 result jsonb;
begin
 if not charm.is_admin() then raise exception 'forbidden'; end if;
 if v_to<v_from or (v_to-v_from)>730 then raise exception 'invalidRange'; end if;
 v_start:=v_from::timestamp at time zone 'Africa/Nairobi';
 v_end:=(v_to+1)::timestamp at time zone 'Africa/Nairobi';
 select jsonb_build_object(
  'from',v_from,
  'to',v_to,
  'team',coalesce((
   select jsonb_agg(t order by t.sales::numeric desc nulls last,t.name)
   from (
    select u.id,u.name,coalesce(sum(o.total),0)::text as sales
    from charm.users u
    left join charm.orders o on o.salesperson_id=u.id
     and o.status='confirmed' and o.confirmed_at>=v_start and o.confirmed_at<v_end
    where u.active and u.role in ('salesperson','admin')
    group by u.id,u.name
   ) t
  ),'[]'::jsonb)
 ) into result;
 return result;
end $$;

revoke execute on function charm.people_sales_summary(date,date) from public,anon;
grant execute on function charm.people_sales_summary(date,date) to authenticated;

-- Ensure PostgREST refreshes its RPC metadata after the migration transaction.
notify pgrst,'reload schema';
commit;

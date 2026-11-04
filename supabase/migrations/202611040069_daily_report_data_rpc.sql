begin;

-- Keep daily report access in one audited, role-aware database function. This
-- avoids fragile multi-request role and RLS checks in the Edge Function while
-- limiting sales staff to their own submitted visit reports.
create or replace function charm.daily_report_visits(p_date date)
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
 a bigint:=charm.require_actor();
 admin boolean:=charm.is_admin();
 result jsonb;
 start_at timestamptz;
 end_at timestamptz;
begin
 if p_date is null then raise exception 'invalid'; end if;
 start_at:=p_date::timestamp at time zone 'Africa/Nairobi';
 end_at:=(p_date+1)::timestamp at time zone 'Africa/Nairobi';

 select jsonb_build_object(
  'date',p_date,
  'is_admin',admin,
  'visits',coalesce(jsonb_agg(to_jsonb(x) order by x.check_in_at),'[]'::jsonb)
 ) into result
 from (
  select v.id,v.client_id,c.name as client_name,v.salesperson_id,u.name as salesperson_name,
   v.check_in_at,v.check_out_at,v.visit_duration_seconds,v.outcome,v.discussion,
   v.client_feedback,v.sales_opportunities,v.next_action,v.follow_up_date
  from charm.visits v
  join charm.clients c on c.id=v.client_id
  join charm.users u on u.id=v.salesperson_id
  where v.report_submitted_at is not null
   and v.check_in_at>=start_at and v.check_in_at<end_at
   and (admin or v.salesperson_id=a)
  order by v.check_in_at
  limit 500
 ) x;
 return result;
end $$;

revoke execute on function charm.daily_report_visits(date) from public,anon;
grant execute on function charm.daily_report_visits(date) to authenticated;

notify pgrst,'reload schema';
commit;

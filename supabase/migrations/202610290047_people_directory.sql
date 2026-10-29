-- Expose stable staff identity on the team directory and staff profile.
begin;

create or replace view charm.team_directory with(security_invoker=true) as
 select u.id,u.name,u.email,u.role,u.active,u.staff_code,u.phone,u.territory from charm.users u
 where not exists(select 1 from charm.staff_archives a where a.staff_id=u.id);
grant select on charm.team_directory to authenticated;

create or replace function charm.staff_profile(p_id bigint,p_month date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u charm.users; start_at timestamptz; end_at timestamptz; result jsonb;
begin
 perform charm.require_admin();
 select * into u from charm.users where id=p_id;
 if not found then raise exception 'notFound'; end if;
 if p_month is null then raise exception 'invalid'; end if;
 start_at:=date_trunc('month',p_month::timestamp) at time zone 'Africa/Nairobi';
 end_at:=(date_trunc('month',p_month::timestamp)+interval '1 month') at time zone 'Africa/Nairobi';
 select jsonb_build_object(
 'person',jsonb_build_object('id',u.id,'name',u.name,'email',u.email,'phone',u.phone,'territory',u.territory,'role',u.role,'active',u.active,'created_at',u.created_at,'staff_code',u.staff_code,'linked',exists(select 1 from charm.auth_accounts where salesperson_id=u.id)),
 'monthly_sales',coalesce((select sum(total)::text from charm.orders where salesperson_id=p_id and status='confirmed' and confirmed_at>=start_at and confirmed_at<end_at),'0.00'),
 'lifetime_sales',coalesce((select sum(total)::text from charm.orders where salesperson_id=p_id and status='confirmed'),'0.00'),
 'outstanding',coalesce((select sum(o.total-coalesce((select sum(p.amount) from charm.payments p where p.order_id=o.id and p.status='verified'),0))::text from charm.orders o where o.salesperson_id=p_id and o.status='confirmed'),'0.00'),
 'clients',(select count(*) from charm.clients where salesperson_id=p_id),
 'pending_orders',(select count(*) from charm.orders where salesperson_id=p_id and status='pending'),
 'pending_payments',(select count(*) from charm.payments p join charm.orders o on o.id=p.order_id where o.salesperson_id=p_id and p.status='pending'),
 'visits',(select count(*) from charm.visits where salesperson_id=p_id),
 'reports',(select count(*) from charm.reports where salesperson_id=p_id),
 'approved_travel',coalesce((select sum(budget)::text from charm.expenses where salesperson_id=p_id and status='approved'),'0.00'),
 'trend',coalesce((select jsonb_agg(jsonb_build_object('month',to_char(m,'YYYY-MM'),'sales',coalesce((select sum(o.total)::text from charm.orders o where o.salesperson_id=p_id and o.status='confirmed' and o.confirmed_at>=m at time zone 'Africa/Nairobi' and o.confirmed_at<(m+interval '1 month') at time zone 'Africa/Nairobi'),'0.00')) order by m) from generate_series(date_trunc('month',p_month::timestamp)-interval '5 months',date_trunc('month',p_month::timestamp),interval '1 month') m),'[]'),
 'latest_location',(select jsonb_build_object('latitude',p.latitude,'longitude',p.longitude,'accuracy_m',p.accuracy_m,'recorded_at',p.recorded_at,'workday_id',w.id,'ended_at',w.ended_at) from charm.location_points p join charm.workdays w on w.id=p.workday_id where w.salesperson_id=p_id order by p.recorded_at desc,p.id desc limit 1)
 ) into result; return result;
end $$;
revoke execute on function charm.staff_profile(bigint,date) from public,anon;
grant execute on function charm.staff_profile(bigint,date) to authenticated;

commit;
notify pgrst,'reload schema';

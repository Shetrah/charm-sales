begin;

-- Period-aware confirmed sales for the staff performance directory.
create or replace function charm.people_sales_summary(p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); v_from date:=coalesce(p_from,(now() at time zone 'Africa/Nairobi')::date); v_to date:=coalesce(p_to,(now() at time zone 'Africa/Nairobi')::date); v_start timestamptz; v_end timestamptz; result jsonb;
begin
 if v_to<v_from or (v_to-v_from)>730 then raise exception 'invalidRange'; end if;
 v_start:=v_from::timestamp at time zone 'Africa/Nairobi';
 v_end:=(v_to+1)::timestamp at time zone 'Africa/Nairobi';
 select jsonb_build_object('from',v_from,'to',v_to,'team',coalesce((
  select jsonb_agg(t order by t.sales::numeric desc nulls last,t.name) from (
   select u.id,u.name,coalesce(sum(o.total),0)::text as sales
   from charm.users u left join charm.orders o on o.salesperson_id=u.id and o.status='confirmed' and o.confirmed_at>=v_start and o.confirmed_at<v_end
   where charm.can_access(u.id) group by u.id,u.name
  ) t
 ),'[]'::jsonb)) into result;
 return result;
end $$;

-- Commission dates follow the order's local confirmation date, so weekly and custom
-- windows do not silently expand to the full commission month.
create or replace function charm.commission_summary(p_from date,p_to date,p_user bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 a bigint:=charm.require_actor();
 v_from date:=coalesce(p_from,(now() at time zone 'Africa/Nairobi')::date);
 v_to date:=coalesce(p_to,(now() at time zone 'Africa/Nairobi')::date);
 v_start timestamptz; v_end timestamptz; v_rows jsonb; v_totals jsonb; v_staff jsonb;
begin
 if v_to<v_from or (v_to-v_from)>730 then raise exception 'invalidRange'; end if;
 if not charm.is_admin() then
  if p_user is not null and p_user<>a then raise exception 'forbidden'; end if;
  p_user:=a;
 end if;
 v_start:=v_from::timestamp at time zone 'Africa/Nairobi';
 v_end:=(v_to+1)::timestamp at time zone 'Africa/Nairobi';
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',e.id,'order_id',e.order_id,'salesperson_id',e.salesperson_id,'staff_code',u.staff_code,
  'name',u.name,'client',c.name,'basis',e.basis,'basis_amount',e.basis_amount,'rate',e.rate,
  'commission',e.commission_amount,'status',e.status,'period_start',e.period_start,
  'rule',r.name,'order_total',o.total,'confirmed_at',o.confirmed_at
 ) order by o.confirmed_at desc,e.id desc),'[]'::jsonb)
 into v_rows
 from charm.commission_entries e join charm.users u on u.id=e.salesperson_id
 join charm.orders o on o.id=e.order_id left join charm.clients c on c.id=o.client_id
 left join charm.commission_rules r on r.id=e.rule_id
 where o.confirmed_at>=v_start and o.confirmed_at<v_end and (p_user is null or e.salesperson_id=p_user);
 select jsonb_build_object(
  'earned',coalesce(sum(e.commission_amount) filter(where e.status in ('earned','approved','paid','adjusted')),0),
  'pending',coalesce(sum(e.commission_amount) filter(where e.status='earned'),0),
  'approved',coalesce(sum(e.commission_amount) filter(where e.status='approved'),0),
  'paid',coalesce(sum(e.commission_amount) filter(where e.status='paid'),0),
  'reversed',coalesce(sum(e.commission_amount) filter(where e.status='reversed'),0),
  'entries',count(*)::integer
 ) into v_totals
 from charm.commission_entries e join charm.orders o on o.id=e.order_id
 where o.confirmed_at>=v_start and o.confirmed_at<v_end and (p_user is null or e.salesperson_id=p_user);
 select coalesce(jsonb_agg(jsonb_build_object(
  'salesperson_id',s.salesperson_id,'staff_code',s.staff_code,'name',s.name,
  'earned',s.earned,'pending',s.pending,'approved',s.approved,'paid',s.paid,'entries',s.entries
 ) order by s.name),'[]'::jsonb)
 into v_staff
 from (
  select e.salesperson_id,u.staff_code,u.name,
   coalesce(sum(e.commission_amount) filter(where e.status in ('earned','approved','paid','adjusted')),0) earned,
   coalesce(sum(e.commission_amount) filter(where e.status='earned'),0) pending,
   coalesce(sum(e.commission_amount) filter(where e.status='approved'),0) approved,
   coalesce(sum(e.commission_amount) filter(where e.status='paid'),0) paid,count(*)::integer entries
  from charm.commission_entries e join charm.users u on u.id=e.salesperson_id join charm.orders o on o.id=e.order_id
  where o.confirmed_at>=v_start and o.confirmed_at<v_end and (p_user is null or e.salesperson_id=p_user)
  group by e.salesperson_id,u.staff_code,u.name
 ) s;
 return jsonb_build_object('from',v_from,'to',v_to,'rows',v_rows,'totals',v_totals,'staff',v_staff);
end $$;

revoke execute on function charm.people_sales_summary(date,date) from public,anon;
grant execute on function charm.people_sales_summary(date,date) to authenticated;
revoke execute on function charm.commission_summary(date,date,bigint) from public,anon;
grant execute on function charm.commission_summary(date,date,bigint) to authenticated;

commit;

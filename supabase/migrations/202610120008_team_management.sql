-- Additive team management. Apply once after migrations 001–007; no historical IDs change.
begin;
alter table charm.users add column if not exists phone varchar(40);
alter table charm.users add column if not exists territory varchar(200);
grant select(phone,territory) on charm.users to authenticated;
create function charm.update_staff(p_id bigint,p_name text,p_phone text,p_territory text,p_role text,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint; u charm.users; caller charm.users;
begin
 a:=charm.require_admin();
 perform pg_advisory_xact_lock(817201008);
 select * into caller from charm.users where id=a for update;
 if caller.role<>'admin' or not caller.active then raise exception 'forbidden'; end if;
 select * into u from charm.users where id=p_id for update;
 if not found then raise exception 'notFound'; end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(p_phone),0)>40 or coalesce(length(p_territory),0)>200 or p_role is null or p_role not in ('admin','salesperson') or p_active is null then raise exception 'invalid'; end if;
 if p_id=a and (p_role<>u.role or p_active<>u.active) then raise exception 'selfRoleChange'; end if;
 if u.role='admin' and u.active and (p_role<>'admin' or not p_active) and (select count(*) from charm.users where role='admin' and active)<=1 then raise exception 'lastAdmin'; end if;
 update charm.users set name=trim(p_name),phone=nullif(trim(p_phone),''),territory=nullif(trim(p_territory),''),role=p_role,active=p_active,updated_at=now() where id=p_id;
 perform charm.audit('staffUpdated','users',p_id,jsonb_build_object('before',jsonb_build_object('name',u.name,'phone',u.phone,'territory',u.territory,'role',u.role,'active',u.active),'after',jsonb_build_object('name',trim(p_name),'phone',p_phone,'territory',p_territory,'role',p_role,'active',p_active)));
end $$;
create function charm.staff_profile(p_id bigint,p_month date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u charm.users; start_at timestamptz; end_at timestamptz; result jsonb;
begin
 perform charm.require_admin();
 select * into u from charm.users where id=p_id;
 if not found then raise exception 'notFound'; end if;
 if p_month is null then raise exception 'invalid'; end if;
 start_at:=date_trunc('month',p_month::timestamp) at time zone 'Africa/Nairobi';
 end_at:=(date_trunc('month',p_month::timestamp)+interval '1 month') at time zone 'Africa/Nairobi';
 select jsonb_build_object(
 'person',jsonb_build_object('id',u.id,'name',u.name,'email',u.email,'phone',u.phone,'territory',u.territory,'role',u.role,'active',u.active,'created_at',u.created_at,'linked',exists(select 1 from charm.auth_accounts where salesperson_id=u.id)),
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
revoke execute on function charm.update_staff(bigint,text,text,text,text,boolean),charm.staff_profile(bigint,date) from public,anon;
grant execute on function charm.update_staff(bigint,text,text,text,text,boolean),charm.staff_profile(bigint,date) to authenticated;
alter table charm.clients add column if not exists location_accuracy_m numeric(10,2);
alter table charm.clients add column if not exists location_captured_at timestamptz;
create function charm.set_client_location(p_id bigint,p_lat numeric,p_lng numeric,p_accuracy numeric) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); c charm.clients;
begin
 select * into c from charm.clients where id=p_id for update;
 if not found or not charm.can_access(c.salesperson_id) then raise exception 'forbidden'; end if;
 if p_lat is null or p_lng is null or p_accuracy is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy not between 0 and 100000 then raise exception 'invalidLocation'; end if;
 update charm.clients set latitude=p_lat,longitude=p_lng,location_accuracy_m=p_accuracy,location_captured_at=now(),updated_at=now() where id=p_id;
 perform charm.audit('locationUpdated','clients',p_id,jsonb_build_object('accuracy_m',p_accuracy));
end $$;
revoke execute on function charm.set_client_location(bigint,numeric,numeric,numeric) from public,anon;
grant execute on function charm.set_client_location(bigint,numeric,numeric,numeric) to authenticated;
-- Realtime sends changes only to clients authorized by SELECT/RLS.
do $$
declare table_name text;
begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  foreach table_name in array array['clients','products','orders','order_items','payments','visits','plans','expenses','reports','workdays','location_points','audit_logs'] loop
   if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='charm' and tablename=table_name) then
    execute format('alter publication supabase_realtime add table charm.%I',table_name);
   end if;
  end loop;
 end if;
end $$;
commit;
notify pgrst,'reload schema';

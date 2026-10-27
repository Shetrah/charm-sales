-- Daily, weekly and monthly management reports built from canonical visit and
-- order records. AI narrative is stored separately from the factual snapshot so
-- exports remain reproducible when the provider is unavailable.
begin;

create table if not exists charm.management_reports(
  id bigserial primary key,
  period text not null check(period in ('daily','weekly','monthly')),
  period_start date not null,
  period_end date not null,
  salesperson_id bigint references charm.users(id),
  client_id bigint references charm.clients(id),
  snapshot jsonb not null,
  source_hash text not null,
  narrative jsonb,
  ai_status text not null default 'pending' check(ai_status in ('pending','ready','template','failed','unavailable')),
  ai_model text,
  ai_error text,
  narrative_generated_at timestamptz,
  generated_by bigint references charm.users(id),
  generated_at timestamptz not null default now(),
  is_stale boolean not null default false,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists management_reports_key on charm.management_reports(
  period,period_start,period_end,coalesce(salesperson_id,0),coalesce(client_id,0));
alter table charm.management_reports enable row level security;
grant select on charm.management_reports to authenticated;
drop policy if exists management_report_admin on charm.management_reports;
create policy management_report_admin on charm.management_reports for select to authenticated using(charm.is_admin());

create table if not exists charm.management_report_versions(
  id bigserial primary key,
  report_id bigint not null references charm.management_reports(id),
  version integer not null,
  snapshot jsonb not null,
  narrative jsonb,
  ai_status text not null,
  ai_model text,
  generated_by bigint references charm.users(id),
  generated_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique(report_id,version)
);
alter table charm.management_report_versions enable row level security;
grant select on charm.management_report_versions to authenticated;
drop policy if exists management_report_version_admin on charm.management_report_versions;
create policy management_report_version_admin on charm.management_report_versions for select to authenticated using(charm.is_admin());

create or replace function charm.report_totals(p_start date,p_end date,p_salesperson bigint,p_client bigint) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'visits',(select count(*)::int from charm.visits v where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'completed',(select count(*)::int from charm.visits v where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end and v.check_out_at is not null and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'incomplete',(select count(*)::int from charm.visits v where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end and v.check_out_at is null and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'clients',(select count(distinct v.client_id)::int from charm.visits v where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'salespeople',(select count(distinct v.salesperson_id)::int from charm.visits v where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'gpsExceptions',(select count(*)::int from charm.visits v where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end and v.gps_status in ('failed','network_failed') and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'followUpsDue',(select count(*)::int from charm.visits v where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end and v.follow_up_date is not null and v.follow_up_date<=p_end and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'outcomes',(select coalesce(jsonb_object_agg(x.outcome,x.n),'{}'::jsonb) from (select coalesce(v.outcome,'pending') outcome,count(*)::int n from charm.visits v where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client) group by coalesce(v.outcome,'pending')) x),
  'orders',(select jsonb_build_object(
    'created',count(*) filter(where (o.created_at at time zone 'Africa/Nairobi')::date between p_start and p_end),
    'createdValue',coalesce(sum(o.total) filter(where (o.created_at at time zone 'Africa/Nairobi')::date between p_start and p_end),0),
    'drafts',count(*) filter(where o.status='draft' and (o.created_at at time zone 'Africa/Nairobi')::date between p_start and p_end),
    'submitted',count(*) filter(where o.status<>'draft' and o.contract_submitted_at is not null and (o.contract_submitted_at at time zone 'Africa/Nairobi')::date between p_start and p_end),
    'submittedValue',coalesce(sum(o.total) filter(where o.status<>'draft' and o.contract_submitted_at is not null and (o.contract_submitted_at at time zone 'Africa/Nairobi')::date between p_start and p_end),0),
    'pending',count(*) filter(where o.status='pending' and o.contract_submitted_at is not null and (o.contract_submitted_at at time zone 'Africa/Nairobi')::date between p_start and p_end),
    'confirmed',count(*) filter(where o.status='confirmed' and o.confirmed_at is not null and (o.confirmed_at at time zone 'Africa/Nairobi')::date between p_start and p_end),
    'confirmedValue',coalesce(sum(o.total) filter(where o.status='confirmed' and o.confirmed_at is not null and (o.confirmed_at at time zone 'Africa/Nairobi')::date between p_start and p_end),0),
    'rejected',count(*) filter(where o.status in ('rejected','cancelled') and o.contract_submitted_at is not null and (o.contract_submitted_at at time zone 'Africa/Nairobi')::date between p_start and p_end)
  ) from charm.orders o where (p_salesperson is null or o.salesperson_id=p_salesperson) and (p_client is null or o.client_id=p_client))
 );
$$;

create or replace function charm.build_sales_report(p_period text,p_date date,p_salesperson bigint default null,p_client bigint default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); p_start date; p_end date; prev_start date; prev_end date; v jsonb;
begin
 if p_period not in ('daily','weekly','monthly') or p_date is null then raise exception 'invalid'; end if;
 if p_salesperson is not null and not exists(select 1 from charm.users u where u.id=p_salesperson) then raise exception 'notFound'; end if;
 if p_client is not null and not exists(select 1 from charm.clients c where c.id=p_client) then raise exception 'notFound'; end if;
 if p_period='daily' then p_start:=p_date;p_end:=p_date;prev_start:=p_date-1;prev_end:=p_date-1;
 elsif p_period='weekly' then p_start:=date_trunc('week',p_date)::date;p_end:=p_start+6;prev_start:=p_start-7;prev_end:=p_start-1;
 else p_start:=date_trunc('month',p_date)::date;p_end:=(date_trunc('month',p_date)+interval '1 month - 1 day')::date;prev_start:=(p_start-interval '1 month')::date;prev_end:=p_start-1;end if;
 select jsonb_build_object(
  'period',p_period,'periodStart',p_start,'periodEnd',p_end,'timezone','Africa/Nairobi','generatedAt',now(),
  'filters',jsonb_build_object('salespersonId',p_salesperson,'clientId',p_client),
  'totals',charm.report_totals(p_start,p_end,p_salesperson,p_client),
  'previous',jsonb_build_object('periodStart',prev_start,'periodEnd',prev_end,'totals',charm.report_totals(prev_start,prev_end,p_salesperson,p_client)),
  'salespeople',(select coalesce(jsonb_agg(jsonb_build_object(
     'id',q.id,'name',q.name,'visits',q.visits,'completed',q.completed,
     'incomplete',q.incomplete,'clients',q.clients,'followUps',q.followUps,'outcomes',q.outcomes
   ) order by q.name),'[]'::jsonb)
   from (select s.id,s.name,count(v.id)::int visits,count(v.id) filter(where v.check_out_at is not null)::int completed,
     count(v.id) filter(where v.check_out_at is null)::int incomplete,count(distinct v.client_id)::int clients,
     count(v.id) filter(where v.follow_up_date is not null)::int followUps,
     (select coalesce(jsonb_object_agg(x.outcome,x.n),'{}'::jsonb) from (select coalesce(vv.outcome,'pending') outcome,count(*)::int n
       from charm.visits vv where vv.salesperson_id=s.id and (vv.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end
       and (p_client is null or vv.client_id=p_client) group by coalesce(vv.outcome,'pending')) x) outcomes
   from charm.users s join charm.visits v on v.salesperson_id=s.id
   where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)
   group by s.id,s.name) q),
  'visits',(select coalesce(jsonb_agg(jsonb_build_object(
     'id',v.id,'salespersonId',v.salesperson_id,'salesperson',s.name,'clientId',v.client_id,'client',c.name,
     'checkIn',v.check_in_at,'checkOut',v.check_out_at,'durationMinutes',floor(coalesce(v.visit_duration_seconds,0)/60)::int,
     'gpsStatus',v.gps_status,'accuracyM',v.accuracy_m,'outcome',v.outcome,'discussion',v.discussion,
     'feedback',v.client_feedback,'opportunities',v.sales_opportunities,'nextAction',v.next_action,
     'followUpDate',v.follow_up_date,'followUpOwnerId',v.follow_up_owner,'followUpOwner',f.name,
     'completed',v.check_out_at is not null,
     'relatedOrders',(select count(*)::int from charm.orders o where o.client_id=v.client_id and (o.created_at at time zone 'Africa/Nairobi')::date=(v.check_in_at at time zone 'Africa/Nairobi')::date)
   ) order by v.check_in_at desc),'[]'::jsonb)
   from charm.visits v join charm.users s on s.id=v.salesperson_id join charm.clients c on c.id=v.client_id left join charm.users f on f.id=v.follow_up_owner
   where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_start and p_end and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'orders',(select coalesce(jsonb_agg(jsonb_build_object(
     'id',o.id,'client',c.name,'salesperson',s.name,'status',o.status,'contractStatus',o.contract_status,
     'total',o.total,'createdAt',o.created_at,'submittedAt',o.contract_submitted_at,'confirmedAt',o.confirmed_at
   ) order by o.created_at desc),'[]'::jsonb)
   from charm.orders o join charm.clients c on c.id=o.client_id join charm.users s on s.id=o.salesperson_id
   where ((o.created_at at time zone 'Africa/Nairobi')::date between p_start and p_end
      or (o.confirmed_at is not null and (o.confirmed_at at time zone 'Africa/Nairobi')::date between p_start and p_end)
      or (o.contract_submitted_at is not null and (o.contract_submitted_at at time zone 'Africa/Nairobi')::date between p_start and p_end))
     and (p_salesperson is null or o.salesperson_id=p_salesperson) and (p_client is null or o.client_id=p_client))
 ) into v;
 return v;
end $$;

create or replace function charm.refresh_management_report(p_period text,p_date date,p_salesperson bigint default null,p_client bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); snap jsonb; h text; r charm.management_reports; cached boolean:=false; v_start date; v_end date;
begin
 if p_period not in ('daily','weekly','monthly') or p_date is null then raise exception 'invalid'; end if;
 if p_period='daily' then v_start:=p_date;v_end:=p_date;
 elsif p_period='weekly' then v_start:=date_trunc('week',p_date)::date;v_end:=v_start+6;
 else v_start:=date_trunc('month',p_date)::date;v_end:=(date_trunc('month',p_date)+interval '1 month - 1 day')::date;end if;
 perform pg_advisory_xact_lock(hashtextextended('management-report:'||p_period||':'||v_start||':'||coalesce(p_salesperson::text,'0')||':'||coalesce(p_client::text,'0'),0));
 snap:=charm.build_sales_report(p_period,p_date,p_salesperson,p_client);
 h:=md5((snap-'generatedAt')::text);
 select * into r from charm.management_reports where period=p_period and period_start=v_start and period_end=v_end
  and salesperson_id is not distinct from p_salesperson and client_id is not distinct from p_client for update;
 if found then
  if r.source_hash=h then
   update charm.management_reports set is_stale=false,updated_at=now() where id=r.id returning * into r;
   cached:=true;
  else
   insert into charm.management_report_versions(report_id,version,snapshot,narrative,ai_status,ai_model,generated_by,generated_at)
   values(r.id,r.version,r.snapshot,r.narrative,r.ai_status,r.ai_model,r.generated_by,r.generated_at);
   update charm.management_reports set snapshot=snap,source_hash=h,narrative=null,ai_status='pending',ai_model=null,ai_error=null,
    narrative_generated_at=null,generated_by=a,generated_at=now(),is_stale=false,version=r.version+1,updated_at=now() where id=r.id returning * into r;
  end if;
 else
  insert into charm.management_reports(period,period_start,period_end,salesperson_id,client_id,snapshot,source_hash,generated_by)
  values(p_period,v_start,v_end,p_salesperson,p_client,snap,h,a) returning * into r;
 end if;
 return jsonb_build_object('cached',cached,'report',to_jsonb(r));
end $$;

create or replace function charm.store_report_narrative(p_report_id bigint,p_narrative jsonb,p_model text default null,p_status text default 'template',p_error text default null)
returns void language plpgsql security definer set search_path='' as $$
declare r charm.management_reports;
begin
 perform charm.require_admin();
 if p_status not in ('template','failed','unavailable') or p_narrative is null or jsonb_typeof(p_narrative)<>'object'
   or not (p_narrative ? 'executiveSummary' and p_narrative ? 'salespersonActivity' and p_narrative ? 'customerIntelligence'
     and p_narrative ? 'commercialOutcomes' and p_narrative ? 'followUpPlan' and p_narrative ? 'managementInsights')
   or length(p_narrative::text)>200000 then raise exception 'invalid'; end if;
 update charm.management_reports set narrative=p_narrative,ai_status=p_status,ai_model=nullif(trim(p_model),''),ai_error=nullif(trim(p_error),''),narrative_generated_at=now(),updated_at=now()
  where id=p_report_id returning * into r;
 if not found then raise exception 'notFound'; end if;
 perform charm.audit('report_narrative_stored','management_reports',p_report_id,jsonb_build_object('status',p_status));
end $$;

-- Service-role only: used by the report-ai Edge Function after provider validation.
create or replace function charm.store_ai_narrative(p_report_id bigint,p_narrative jsonb,p_model text,p_status text,p_error text default null)
returns void language plpgsql security definer set search_path='' as $$
begin
 if p_status not in ('ready','failed') or p_narrative is null or jsonb_typeof(p_narrative)<>'object'
   or not (p_narrative ? 'executiveSummary' and p_narrative ? 'salespersonActivity' and p_narrative ? 'customerIntelligence'
     and p_narrative ? 'commercialOutcomes' and p_narrative ? 'followUpPlan' and p_narrative ? 'managementInsights')
   or length(p_narrative::text)>200000 then raise exception 'invalid'; end if;
 update charm.management_reports set narrative=p_narrative,ai_status=p_status,ai_model=nullif(trim(p_model),''),ai_error=nullif(trim(p_error),''),narrative_generated_at=now(),updated_at=now()
  where id=p_report_id;
 if not found then raise exception 'notFound'; end if;
end $$;

-- Mark reports stale when their source records change; refresh keeps versions.
create or replace function charm.mark_management_reports_stale() returns trigger language plpgsql security definer set search_path='' as $$
declare d date; d2 date;
begin
 if tg_table_name='visits' then
  d:=(new.check_in_at at time zone 'Africa/Nairobi')::date;
  update charm.management_reports set is_stale=true,updated_at=now()
  where d between period_start and period_end and (salesperson_id is null or salesperson_id=new.salesperson_id) and (client_id is null or client_id=new.client_id);
 elsif tg_table_name='orders' then
  d:=((coalesce(new.created_at,now())) at time zone 'Africa/Nairobi')::date;
  d2:=case when new.confirmed_at is null then null else (new.confirmed_at at time zone 'Africa/Nairobi')::date end;
  update charm.management_reports set is_stale=true,updated_at=now()
  where (d between period_start and period_end or (d2 is not null and d2 between period_start and period_end))
   and (salesperson_id is null or salesperson_id=new.salesperson_id) and (client_id is null or client_id=new.client_id);
 end if;
 return new;
end $$;
drop trigger if exists visits_mark_reports_stale on charm.visits;
create trigger visits_mark_reports_stale after insert or update on charm.visits for each row execute function charm.mark_management_reports_stale();
drop trigger if exists orders_mark_reports_stale on charm.orders;
create trigger orders_mark_reports_stale after insert or update on charm.orders for each row execute function charm.mark_management_reports_stale();

revoke execute on function charm.report_totals(date,date,bigint,bigint),charm.build_sales_report(text,date,bigint,bigint),charm.refresh_management_report(text,date,bigint,bigint),charm.store_report_narrative(bigint,jsonb,text,text,text),charm.store_ai_narrative(bigint,jsonb,text,text,text),charm.mark_management_reports_stale() from public,anon,authenticated;
grant execute on function charm.build_sales_report(text,date,bigint,bigint),charm.refresh_management_report(text,date,bigint,bigint),charm.store_report_narrative(bigint,jsonb,text,text,text) to authenticated;
grant execute on function charm.store_ai_narrative(bigint,jsonb,text,text,text) to service_role;

commit;

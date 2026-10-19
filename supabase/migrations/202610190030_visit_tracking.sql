-- Visit records stay in the existing visits module. Reports are fields on each visit;
-- daily/weekly/monthly reporting is derived from those canonical records.
begin;
alter table charm.visits
  add column if not exists consent_at timestamptz,
  add column if not exists gps_status text not null default 'captured' check(gps_status in ('captured','failed','network_failed','override')),
  add column if not exists report_submitted_at timestamptz,
  add column if not exists discussion text,
  add column if not exists client_feedback text,
  add column if not exists sales_opportunities text,
  add column if not exists follow_up_owner bigint references charm.users(id),
  add column if not exists follow_up_reminded_at timestamptz,
  add column if not exists visit_duration_seconds bigint generated always as
    (case when check_out_at is null then null else greatest(0,floor(extract(epoch from (check_out_at-check_in_at)))::bigint) end) stored;
alter table charm.visits alter column latitude drop not null;
alter table charm.visits alter column longitude drop not null;
alter table charm.visits alter column accuracy_m drop not null;
alter table charm.visits alter column outcome drop not null;
alter table charm.visits alter column notes drop not null;
alter table charm.visits add constraint visit_complete_gps check(
 (gps_status in ('captured','override') and latitude is not null and longitude is not null and accuracy_m is not null)
 or gps_status in ('failed','network_failed'));

create table charm.visit_exceptions(id bigserial primary key,visit_id bigint not null references charm.visits(id),
 actor_id bigint not null references charm.users(id),kind text not null check(kind in ('gps_failure','network_failure','admin_override')),
 details text not null,created_at timestamptz not null default now());
alter table charm.visit_exceptions enable row level security;
grant select on charm.visit_exceptions to authenticated;
create policy visit_exception_scope on charm.visit_exceptions for select to authenticated
 using(charm.is_admin() or exists(select 1 from charm.visits v where v.id=visit_id and v.salesperson_id=charm.actor()));
create index visits_active on charm.visits(salesperson_id,check_in_at) where check_out_at is null;
create index visits_followup on charm.visits(follow_up_date) where follow_up_date is not null and check_out_at is not null;

-- Keep the legacy manual route logger from collecting points outside visit windows.
create or replace function charm.guard_location_point_to_visit() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from charm.workdays w join charm.visits v on v.salesperson_id=w.salesperson_id
   where w.id=new.workday_id and w.salesperson_id=charm.actor() and v.check_in_at<=new.recorded_at
   and new.recorded_at<=coalesce(v.check_out_at,now())) then raise exception 'activeVisitRequired'; end if;
 return new;
end $$;
create trigger location_requires_active_visit before insert on charm.location_points
for each row execute function charm.guard_location_point_to_visit();
revoke execute on function charm.guard_location_point_to_visit() from public,anon,authenticated;

create or replace function charm.start_visit(p_key uuid,p_client bigint,p_consent boolean,p_lat numeric,p_lng numeric,p_accuracy numeric,p_gps_status text default 'captured',p_failure text default null)
returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); id bigint; old bigint; kind text;
begin
 if not exists(select 1 from charm.users u where u.id=a and u.role='salesperson' and u.active) then raise exception 'forbidden'; end if;
 if p_consent is distinct from true then raise exception 'consentRequired'; end if;
 if not exists(select 1 from charm.clients c where c.id=p_client and charm.can_access(c.salesperson_id)) then raise exception 'forbidden'; end if;
 if p_gps_status not in ('captured','failed','network_failed') then raise exception 'invalid'; end if;
 if p_gps_status='captured' and (p_lat is null or p_lng is null or p_accuracy is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy not between 0 and 100000) then raise exception 'invalidLocation'; end if;
 if p_gps_status<>'captured' and coalesce(length(trim(p_failure)),0) not between 1 and 1000 then raise exception 'exceptionReasonRequired'; end if;
 old:=charm.claim(p_key,'start_visit',jsonb_build_array(p_client,p_consent,p_lat,p_lng,p_accuracy,p_gps_status,p_failure)); if old is not null then return old; end if;
 perform 1 from charm.users where users.id=a for update;
 if exists(select 1 from charm.visits where salesperson_id=a and check_out_at is null) then raise exception 'activeVisitExists'; end if;
 insert into charm.visits(submission_key,salesperson_id,client_id,check_in_at,consent_at,latitude,longitude,accuracy_m,gps_status,created_at,updated_at)
 values(p_key,a,p_client,clock_timestamp(),clock_timestamp(),p_lat,p_lng,p_accuracy,p_gps_status,now(),now()) returning visits.id into id;
 if p_gps_status<>'captured' then kind:=case when p_gps_status='failed' then 'gps_failure' else 'network_failure' end; insert into charm.visit_exceptions(visit_id,actor_id,kind,details) values(id,a,kind,p_failure); end if;
 perform charm.audit('checkedIn','visits',id,jsonb_build_object('gps_status',p_gps_status)); return charm.finish(p_key,id);
end $$;

create or replace function charm.submit_visit_report(p_key uuid,p_id bigint,p_discussion text,p_outcome text,p_feedback text,p_opportunities text,p_next text,p_follow_up date,p_owner bigint default null)
returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); v charm.visits; old bigint;
begin
 if not exists(select 1 from charm.users u where u.id=a and u.role='salesperson' and u.active) then raise exception 'forbidden'; end if;
 if coalesce(length(trim(p_discussion)),0) not between 1 and 10000 or coalesce(length(trim(p_feedback)),0) not between 1 and 5000 or coalesce(length(trim(p_opportunities)),0) not between 1 and 5000 or coalesce(length(trim(p_next)),0) not between 1 and 5000 or p_outcome not in ('order','follow-up','no-sale','payment-follow-up') or p_follow_up is null then raise exception 'reportIncomplete'; end if;
 select * into v from charm.visits where id=p_id for update;
 if not found or v.salesperson_id<>a then raise exception 'forbidden'; end if;
 if p_owner is not null and not exists(select 1 from charm.users u where u.id=p_owner and u.active and (u.role='salesperson' or u.role='admin')) then raise exception 'invalid'; end if;
 old:=charm.claim(p_key,'visit_report',jsonb_build_array(p_id,p_discussion,p_outcome,p_feedback,p_opportunities,p_next,p_follow_up,p_owner)); if old is not null then return; end if;
 if v.check_out_at is not null or v.report_submitted_at is not null then raise exception 'visitAlreadyClosed'; end if;
 update charm.visits set discussion=p_discussion,outcome=p_outcome,client_feedback=p_feedback,sales_opportunities=p_opportunities,notes=p_discussion,next_action=p_next,follow_up_date=p_follow_up,follow_up_owner=coalesce(p_owner,a),report_submitted_at=clock_timestamp(),check_out_at=clock_timestamp(),updated_at=now() where id=p_id;
 perform charm.finish(p_key,p_id); perform charm.audit('reportSubmitted','visits',p_id); perform charm.audit('checkedOut','visits',p_id);
end $$;

create or replace function charm.visit_gps_exception(p_id bigint,p_kind text,p_details text) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();
begin
 if not exists(select 1 from charm.users u where u.id=a and u.role='salesperson' and u.active) then raise exception 'forbidden'; end if;
 if p_kind not in ('gps_failure','network_failure') or coalesce(length(trim(p_details)),0) not between 1 and 1000 then raise exception 'invalid'; end if;
 if not exists(select 1 from charm.visits where id=p_id and salesperson_id=a and check_out_at is null) then raise exception 'forbidden'; end if;
 insert into charm.visit_exceptions(visit_id,actor_id,kind,details) values(p_id,a,p_kind,p_details);
 update charm.visits set gps_status=case when p_kind='gps_failure' then 'failed' else 'network_failed' end where id=p_id;
 perform charm.audit('visitException','visits',p_id,jsonb_build_object('kind',p_kind));
end $$;

create or replace function charm.override_visit_gps(p_id bigint,p_lat numeric,p_lng numeric,p_accuracy numeric,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin();
begin
 if p_lat is null or p_lng is null or p_accuracy is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy not between 0 and 100000 or coalesce(length(trim(p_reason)),0) not between 1 and 1000 then raise exception 'invalidLocation'; end if;
 update charm.visits set latitude=p_lat,longitude=p_lng,accuracy_m=p_accuracy,gps_status='override',updated_at=now() where id=p_id and check_out_at is null;
 if not found then raise exception 'notFound'; end if;
 insert into charm.visit_exceptions(visit_id,actor_id,kind,details) values(p_id,a,'admin_override',p_reason);
 perform charm.audit('gpsOverride','visits',p_id,jsonb_build_object('reason',p_reason));
end $$;

create or replace function charm.visit_report_summary(p_from date,p_to date,p_salesperson bigint default null,p_client bigint default null,p_status text default null,p_period text default 'daily') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 or p_period not in ('daily','weekly','monthly') or (p_status is not null and p_status not in ('active','completed','pending_report')) then raise exception 'invalid'; end if;
 if not charm.is_admin() then
  if p_salesperson is not null and p_salesperson<>charm.actor() then raise exception 'forbidden'; end if;
  p_salesperson:=charm.actor();
 end if;
 with filtered as (
  select v.*,case p_period when 'monthly' then date_trunc('month',((v.check_in_at at time zone 'Africa/Nairobi')::date)::timestamp)::date when 'weekly' then date_trunc('week',((v.check_in_at at time zone 'Africa/Nairobi')::date)::timestamp)::date else (v.check_in_at at time zone 'Africa/Nairobi')::date end bucket
  from charm.visits v
  where (v.check_in_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)
  and (p_status is null or p_status='active' and v.check_out_at is null or p_status='completed' and v.check_out_at is not null or p_status='pending_report' and v.check_out_at is null and v.report_submitted_at is null)
 ), outcome_counts as (
  select bucket,coalesce(outcome,'pending') outcome,count(*)::int n from filtered group by bucket,coalesce(outcome,'pending')
 ), totals as (
  select bucket,count(*)::int visits,count(*) filter(where check_out_at is not null)::int completed,count(*) filter(where check_out_at is null)::int active,count(*) filter(where check_out_at is null and report_submitted_at is null)::int pending_reports from filtered group by bucket
 )
 select coalesce(jsonb_agg(jsonb_build_object('period',t.bucket,'visits',t.visits,'completed',t.completed,'active',t.active,'pending_reports',t.pending_reports,'outcomes',o.outcomes) order by t.bucket),'[]'::jsonb) into result
 from totals t join lateral (select jsonb_object_agg(outcome,n) outcomes from outcome_counts where bucket=t.bucket) o on true;
 return result;
end $$;

-- Daily reminders reuse the notification inbox. A daily key makes retries idempotent.
create or replace function charm.dispatch_visit_followup_reminders() returns integer
language plpgsql security definer set search_path='' as $$
declare v record; recipient bigint; total integer:=0; today date:=(now() at time zone 'Africa/Nairobi')::date;
begin
 for v in select id,follow_up_owner,follow_up_date from charm.visits where check_out_at is not null and follow_up_date<=today and follow_up_date is not null loop
  for recipient in select u.id from charm.users u where u.active and (u.id=v.follow_up_owner or (today-v.follow_up_date)>=3 and u.role='admin') loop
   insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
   values(recipient,null,case when recipient=v.follow_up_owner then 'visit_followup_due' else 'visit_followup_escalated' end,
    'visit-followup:'||v.id||':'||recipient||':'||today::text,'visits',v.id) on conflict do nothing;
   if found then total:=total+1; end if;
  end loop;
 end loop;
 return total;
end $$;
revoke execute on function charm.dispatch_visit_followup_reminders() from public,anon,authenticated;
do $$ begin
 if exists(select 1 from pg_catalog.pg_extension where extname='pg_cron') then
  execute $schedule$select cron.schedule('charm-visit-followups','5 6 * * *','select charm.dispatch_visit_followup_reminders()')$schedule$;
 end if;
exception when others then null; end $$;

-- Disable the legacy APIs that could create an unreported visit or close one without a report.
revoke execute on function charm.submit_visit(uuid,bigint,numeric,numeric,numeric,text,text,text,text,date),charm.checkout_visit(bigint) from public,anon,authenticated;

revoke execute on function charm.start_visit(uuid,bigint,boolean,numeric,numeric,numeric,text,text),charm.submit_visit_report(uuid,bigint,text,text,text,text,text,date,bigint),charm.visit_gps_exception(bigint,text,text),charm.override_visit_gps(bigint,numeric,numeric,numeric,text),charm.visit_report_summary(date,date,bigint,bigint,text,text) from public,anon;
grant execute on function charm.start_visit(uuid,bigint,boolean,numeric,numeric,numeric,text,text),charm.submit_visit_report(uuid,bigint,text,text,text,text,text,date,bigint),charm.visit_gps_exception(bigint,text,text),charm.override_visit_gps(bigint,numeric,numeric,numeric,text),charm.visit_report_summary(date,date,bigint,bigint,text,text) to authenticated;
commit;

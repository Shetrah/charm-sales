-- Africa/Nairobi business time, Field Travel & Planning, and travel-aware reports.
-- Event instants stay absolute (timestamptz). Business dates stay date columns.
begin;

-- 1. Legacy naive timestamps become timezone-aware without changing the instant.
-- Existing values are interpreted as UTC, the Laravel/Supabase default.
alter table charm.users alter column created_at type timestamptz using created_at at time zone 'UTC';
alter table charm.users alter column updated_at type timestamptz using updated_at at time zone 'UTC';
alter table charm.products alter column created_at type timestamptz using created_at at time zone 'UTC';
alter table charm.products alter column updated_at type timestamptz using updated_at at time zone 'UTC';
alter table charm.clients alter column created_at type timestamptz using created_at at time zone 'UTC';
alter table charm.clients alter column updated_at type timestamptz using updated_at at time zone 'UTC';

-- 2. One explicit definition of a Kenyan business day (half-open intervals).
create or replace function charm.business_day_start(p_day date) returns timestamptz
language sql immutable set search_path='' as $$
 select (p_day::timestamp at time zone 'Africa/Nairobi')
$$;
create or replace function charm.business_day_end(p_day date) returns timestamptz
language sql immutable set search_path='' as $$
 select ((p_day+1)::timestamp at time zone 'Africa/Nairobi')
$$;

-- 3. Itineraries extend the existing plans table; travel requests extend expenses.
alter table charm.plans
  add column if not exists title text,
  add column if not exists start_location text,
  add column if not exists transport_mode text,
  add column if not exists expected_duration_minutes integer,
  add column if not exists travel_request_id bigint,
  add column if not exists submitted_at timestamptz,
  add column if not exists decided_at timestamptz,
  add column if not exists decided_by bigint references charm.users(id),
  add column if not exists decision_reason text,
  add column if not exists completed_at timestamptz,
  add column if not exists cancelled_at timestamptz;
alter table charm.expenses
  add column if not exists purpose text,
  add column if not exists origin text,
  add column if not exists destination text,
  add column if not exists depart_at timestamptz,
  add column if not exists return_at timestamptz,
  add column if not exists advance_required boolean not null default false,
  add column if not exists total_estimated numeric(14,2) not null default 0,
  add column if not exists submitted_at timestamptz,
  add column if not exists decided_at timestamptz,
  add column if not exists decided_by bigint references charm.users(id),
  add column if not exists decision_reason text,
  add column if not exists finance_review_required boolean not null default false,
  add column if not exists completed_at timestamptz;

do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid='charm.plans'::regclass and contype='c' and pg_get_constraintdef(oid) like '%status%' loop
    execute format('alter table charm.plans drop constraint %I',c.conname);
  end loop;
  for c in select conname from pg_constraint where conrelid='charm.expenses'::regclass and contype='c' and pg_get_constraintdef(oid) like '%status%' loop
    execute format('alter table charm.expenses drop constraint %I',c.conname);
  end loop;
end $$;
alter table charm.plans add constraint plans_travel_status check(status in (
  'draft','planned','in_progress','completed','partially_completed','cancelled','pending','approved','rejected'));
alter table charm.expenses add constraint expenses_travel_status check(status in (
  'draft','submitted','pending_approval','approved','rejected','returned','finance_review','in_progress','completed','cancelled','pending'));
alter table charm.plans add constraint plans_travel_request_fk foreign key(travel_request_id) references charm.expenses(id);
alter table charm.plans add constraint plans_transport_check check(transport_mode is null or transport_mode in ('walk','public','boda','car','company_vehicle','air','other'));
alter table charm.plans add constraint plans_duration_check check(expected_duration_minutes is null or expected_duration_minutes between 1 and 1440);
alter table charm.expenses add constraint expenses_total_check check(total_estimated>=0);

create table if not exists charm.plan_stops(
  id bigserial primary key,
  plan_id bigint not null references charm.plans(id) on delete cascade,
  sequence integer not null check(sequence<>0),
  client_id bigint not null references charm.clients(id),
  appointment_at timestamptz,
  objective text,
  expected_duration_minutes integer check(expected_duration_minutes is null or expected_duration_minutes between 1 and 1440),
  notes text,
  status text not null default 'planned' check(status in ('planned','completed','missed','rescheduled','cancelled')),
  visit_id bigint references charm.visits(id),
  rescheduled_to date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists plan_stops_plan on charm.plan_stops(plan_id,sequence);
create index if not exists plan_stops_client on charm.plan_stops(client_id,appointment_at);

create table if not exists charm.travel_request_items(
  id bigserial primary key,
  request_id bigint not null references charm.expenses(id) on delete cascade,
  kind text not null check(kind in ('transport','accommodation','other')),
  label text not null check(length(trim(label)) between 1 and 200),
  amount numeric(14,2) not null check(amount>=0 and amount<=100000000),
  created_at timestamptz not null default now()
);
create index if not exists travel_request_items_request on charm.travel_request_items(request_id,id);

create table if not exists charm.travel_request_documents(
  id bigserial primary key,
  request_id bigint not null references charm.expenses(id) on delete cascade,
  path text unique not null,
  file_name text not null,
  content_type text,
  uploaded_by bigint not null references charm.users(id),
  created_at timestamptz not null default now()
);
create index if not exists travel_request_documents_request on charm.travel_request_documents(request_id,id);

-- Policy is explicit and configurable. NULL threshold disables finance review;
-- every submitted request still requires an administrator decision.
create table if not exists charm.travel_policy(
  id smallint primary key default 1 check(id=1),
  finance_review_threshold numeric(14,2) check(finance_review_threshold is null or finance_review_threshold>=0),
  updated_by bigint references charm.users(id),
  updated_at timestamptz not null default now()
);
insert into charm.travel_policy(id,finance_review_threshold) values(1,null) on conflict(id) do nothing;

alter table charm.plan_stops enable row level security;
alter table charm.travel_request_items enable row level security;
alter table charm.travel_request_documents enable row level security;
alter table charm.travel_policy enable row level security;
revoke all on charm.plan_stops,charm.travel_request_items,charm.travel_request_documents,charm.travel_policy from public,anon,authenticated;
grant select on charm.plan_stops,charm.travel_request_items,charm.travel_request_documents,charm.travel_policy to authenticated;
create policy plan_stop_scope on charm.plan_stops for select to authenticated
  using(exists(select 1 from charm.plans p where p.id=plan_id and charm.can_access(p.salesperson_id)));
create policy travel_item_scope on charm.travel_request_items for select to authenticated
  using(exists(select 1 from charm.expenses e where e.id=request_id and (charm.can_access(e.salesperson_id) or charm.finance_reader())));
create policy travel_document_scope on charm.travel_request_documents for select to authenticated
  using(exists(select 1 from charm.expenses e where e.id=request_id and (charm.can_access(e.salesperson_id) or charm.finance_reader())));
create policy travel_policy_read on charm.travel_policy for select to authenticated using(charm.actor() is not null);
-- Finance sees travel records only once they are approved for money handling.
create policy travel_finance_request_scope on charm.expenses for select to authenticated
  using(charm.finance_reader() and purpose is not null
    and status in ('approved','finance_review','in_progress','completed'));
create policy travel_finance_itinerary_scope on charm.plans for select to authenticated
  using(charm.finance_reader() and exists(select 1 from charm.expenses e where e.id=plans.travel_request_id
    and e.status in ('approved','finance_review','in_progress','completed')));

-- Travel documents live under travel/{request_id}/ in the private bucket.
create or replace function charm.file_access(path text,writing boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare kind text:=split_part(path,'/',1); record_id bigint; owner bigint; status text; contract text;
begin
 if charm.actor() is null or split_part(path,'/',2) !~ '^\d+$' then return false; end if;
 record_id:=split_part(path,'/',2)::bigint;
 if kind='visits' then select salesperson_id into owner from charm.visits where visits.id=record_id;
 elsif kind='payments' then select o.salesperson_id,p.status into owner,status from charm.payments p join charm.orders o on o.id=p.order_id where p.id=record_id;
 elsif kind='orders' then select salesperson_id,orders.status,orders.contract_path into owner,status,contract from charm.orders where orders.id=record_id;
 elsif kind='travel' then select salesperson_id,status into owner,status from charm.expenses where expenses.id=record_id;
 else return false;end if;
 if kind='orders' then
  if writing then return status='draft' and owner is not null and coalesce(charm.can_access(owner),false); end if;
  return owner is not null and coalesce(charm.can_access(owner),false)
   and (contract=path or exists(select 1 from charm.order_documents d where d.order_id=record_id and d.storage_path=path));
 end if;
 if kind='travel' then
  if writing then return status in ('draft','returned') and owner is not null and coalesce(charm.can_access(owner),false); end if;
  return owner is not null and (coalesce(charm.can_access(owner),false)
   or (charm.finance_reader() and status in ('approved','finance_review','in_progress','completed')));
 end if;
 if writing and kind='payments' and status<>'pending' then return false; end if;
 return owner is not null and coalesce(charm.can_access(owner),false);
end $$;

-- 4. Itinerary API -----------------------------------------------------------
create or replace function charm.save_itinerary(
  p_key uuid,p_id bigint,p_title text,p_salesperson bigint,p_date date,p_start text,
  p_transport text,p_duration integer,p_notes text,p_stops jsonb,p_request bigint,p_submit boolean default false
) returns bigint language plpgsql security definer set search_path='' as $$
declare
  a bigint:=charm.require_actor(); v_id bigint; old bigint; owner bigint; current charm.plans;
  st jsonb; seq int:=0; appointment timestamptz; stop_id bigint; visit bigint; previous_appointment timestamptz;
  previous_status text; previous_client bigint; signature_old text; signature_new text; request_status text;
  linked int; requires_reapproval boolean:=false;
begin
  owner:=coalesce(p_salesperson,a);
  if not charm.is_admin() then owner:=a; end if;
  if not charm.can_access(owner) then raise exception 'forbidden'; end if;
  if p_title is null or length(trim(p_title)) not between 3 and 200 then raise exception 'invalid'; end if;
  if p_date is null then raise exception 'invalid'; end if;
  if p_transport is not null and p_transport not in ('walk','public','boda','car','company_vehicle','air','other') then raise exception 'invalid'; end if;
  if p_duration is not null and p_duration not between 1 and 1440 then raise exception 'invalid'; end if;
  if p_stops is null or jsonb_typeof(p_stops)<>'array' or jsonb_array_length(p_stops)>50 then raise exception 'invalid'; end if;
  if p_request is not null then
    if not exists(select 1 from charm.expenses e where e.id=p_request and charm.can_access(e.salesperson_id)) then raise exception 'forbidden'; end if;
    if exists(select 1 from charm.expenses e where e.id=p_request and e.status in ('rejected','cancelled','completed','returned')) then raise exception 'requestLocked'; end if;
  end if;
  old:=charm.claim(p_key,'itinerary',jsonb_build_array(p_id,p_title,owner,p_date,p_start,p_transport,p_duration,p_notes,p_stops,p_request,p_submit));
  if old is not null then return old; end if;

  if p_id is null then
    insert into charm.plans(submission_key,salesperson_id,date,client_id,budget,notes,status,title,start_location,transport_mode,
      expected_duration_minutes,travel_request_id,submitted_at,created_at,updated_at)
    values(p_key,owner,p_date,null,null,coalesce(p_notes,''),case when p_submit then 'planned' else 'draft' end,p_title,p_start,p_transport,
      p_duration,p_request,case when p_submit then now() else null end,now(),now()) returning id into v_id;
    perform charm.audit('itinerary_created','plans',v_id,jsonb_build_object('submitted',p_submit));
    requires_reapproval:=p_request is not null;
  else
    select * into current from charm.plans where plans.id=p_id for update;
    if not found then raise exception 'notFound'; end if;
    if not charm.can_access(current.salesperson_id) then raise exception 'forbidden'; end if;
    if current.status not in ('draft','planned','partially_completed') then raise exception 'requestLocked'; end if;
    if current.salesperson_id<>owner and not charm.is_admin() then raise exception 'forbidden'; end if;
    if current.travel_request_id is not null and p_request is distinct from current.travel_request_id then
      select status into request_status from charm.expenses where expenses.id=current.travel_request_id;
      if request_status in ('approved','finance_review','in_progress') then raise exception 'requestLocked'; end if;
    end if;
    select coalesce(string_agg(s.client_id::text||'@'||coalesce(to_char(s.appointment_at at time zone 'Africa/Nairobi','YYYY-MM-DD"T"HH24:MI'),'')||'#'||s.sequence::text,',' order by s.sequence),'')
      into signature_old from charm.plan_stops s where s.plan_id=p_id and s.status<>'cancelled';
    signature_old:=coalesce(current.date::text,'')||'|'||coalesce(current.start_location,'')||'|'||
      coalesce(current.transport_mode,'')||'|'||coalesce(current.expected_duration_minutes::text,'')||'|'||signature_old;
    v_id:=p_id;
    update charm.plans set title=p_title,salesperson_id=owner,date=p_date,notes=coalesce(p_notes,''),start_location=p_start,
      transport_mode=p_transport,expected_duration_minutes=p_duration,travel_request_id=p_request,
      status=case when p_submit and plans.status='draft' then 'planned' else plans.status end,
      submitted_at=case when p_submit then coalesce(submitted_at,now()) else submitted_at end,updated_at=now()
    where plans.id=v_id;
    perform charm.audit(case when p_submit and current.status='draft' then 'itinerary_submitted' else 'itinerary_updated' end,'plans',v_id);
  end if;

  -- Mark current rows so explicit edits can be matched by id without sequence clashes.
  update charm.plan_stops set sequence=-sequence where plan_stops.plan_id=v_id;
  for st in select value from jsonb_array_elements(p_stops) loop
    seq:=seq+1;
    if coalesce(st->>'client_id','') !~ '^\d+$' then raise exception 'invalid'; end if;
    if not exists(select 1 from charm.clients c where c.id=(st->>'client_id')::bigint and charm.can_access(c.salesperson_id)) then raise exception 'forbidden'; end if;
    appointment:=nullif(st->>'appointment_at','')::timestamptz;
    if appointment is not null and (appointment at time zone 'Africa/Nairobi')::date<>p_date then raise exception 'invalid'; end if;
    if st ? 'id' and coalesce(st->>'id','') ~ '^\d+$' then
      stop_id:=(st->>'id')::bigint;
      select appointment_at,status,client_id into previous_appointment,previous_status,previous_client
        from charm.plan_stops where id=stop_id and plan_id=v_id for update;
      if not found then raise exception 'notFound'; end if;
      visit:=(select visit_id from charm.plan_stops where id=stop_id);
      if visit is not null and previous_client<>(st->>'client_id')::bigint then raise exception 'requestLocked'; end if;
      update charm.plan_stops set sequence=seq,client_id=(st->>'client_id')::bigint,appointment_at=appointment,
        objective=nullif(st->>'objective',''),expected_duration_minutes=nullif(st->>'expected_duration_minutes','')::int,
        notes=nullif(st->>'notes',''),
        status=case
          when visit is not null then 'completed'
          when appointment is distinct from previous_appointment and appointment is not null then 'rescheduled'
          when previous_status='rescheduled' and appointment is not distinct from previous_appointment then 'planned'
          else plan_stops.status end,
        rescheduled_to=case when visit is null and appointment is distinct from previous_appointment and appointment is not null
          then (appointment at time zone 'Africa/Nairobi')::date else rescheduled_to end,
        updated_at=now()
      where id=stop_id;
    else
      insert into charm.plan_stops(plan_id,sequence,client_id,appointment_at,objective,expected_duration_minutes,notes,status)
      values(v_id,seq,(st->>'client_id')::bigint,appointment,nullif(st->>'objective',''),
        nullif(st->>'expected_duration_minutes','')::int,nullif(st->>'notes',''),'planned');
    end if;
  end loop;
  delete from charm.plan_stops where plan_stops.plan_id=v_id and sequence<0 and visit_id is null;
  update charm.plan_stops set status='cancelled',sequence=1000+plan_stops.id
    where plan_stops.plan_id=v_id and sequence<0 and visit_id is not null;
  select count(*) into linked from charm.plan_stops where plan_stops.plan_id=v_id and status<>'cancelled';
  if linked=0 and p_submit then raise exception 'destinationRequired'; end if;

  -- Material itinerary edits after travel approval require a fresh decision.
  if p_id is not null then
    select coalesce(string_agg(s.client_id::text||'@'||coalesce(to_char(s.appointment_at at time zone 'Africa/Nairobi','YYYY-MM-DD"T"HH24:MI'),'')||'#'||s.sequence::text,',' order by s.sequence),'')
      into signature_new from charm.plan_stops s where s.plan_id=v_id and s.status<>'cancelled';
    signature_new:=p_date::text||'|'||coalesce(p_start,'')||'|'||coalesce(p_transport,'')||'|'||
      coalesce(p_duration::text,'')||'|'||signature_new;
    requires_reapproval:=p_request is not null and (p_request is distinct from current.travel_request_id or signature_new is distinct from signature_old);
  end if;
  if requires_reapproval then
    select status into request_status from charm.expenses where expenses.id=p_request for update;
    if request_status in ('approved','finance_review','in_progress') then
      update charm.expenses set status='pending_approval',decided_by=null,decided_at=null,
        decision_reason='Itinerary changed after approval; reapproval required',finance_review_required=false,
        submitted_at=now(),updated_at=now() where expenses.id=p_request;
      perform charm.audit('travel_request_reapproval_required','expenses',p_request,jsonb_build_object('itinerary',v_id));
    end if;
  end if;
  return charm.finish(p_key,v_id);
end $$;

create or replace function charm.submit_itinerary(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); p charm.plans;
begin
  select * into p from charm.plans where id=p_id for update;
  if not found then raise exception 'notFound'; end if;
  if not charm.can_access(p.salesperson_id) then raise exception 'forbidden'; end if;
  if p.status<>'draft' then raise exception 'requestLocked'; end if;
  if not exists(select 1 from charm.plan_stops where plan_id=p_id and status<>'cancelled') then raise exception 'destinationRequired'; end if;
  update charm.plans set status='planned',submitted_at=now(),updated_at=now() where id=p_id;
  perform charm.audit('itinerary_submitted','plans',p_id);
end $$;

create or replace function charm.start_itinerary(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); p charm.plans;
begin
  select * into p from charm.plans where id=p_id for update;
  if not found then raise exception 'notFound'; end if;
  if not charm.can_access(p.salesperson_id) then raise exception 'forbidden'; end if;
  if p.status not in ('planned','partially_completed') then raise exception 'requestLocked'; end if;
  update charm.plans set status='in_progress',updated_at=now() where id=p_id;
  perform charm.audit('itinerary_started','plans',p_id);
end $$;

create or replace function charm.finish_itinerary(p_id bigint,p_cancel boolean default false) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); p charm.plans; total int; completed int;
begin
  if p_cancel is null then raise exception 'invalid'; end if;
  select * into p from charm.plans where id=p_id for update;
  if not found then raise exception 'notFound'; end if;
  if not charm.can_access(p.salesperson_id) then raise exception 'forbidden'; end if;
  if p.status in ('completed','partially_completed','cancelled') then raise exception 'alreadyReviewed'; end if;
  if p_cancel then
    update charm.plans set status='cancelled',cancelled_at=now(),completed_at=now(),updated_at=now() where id=p_id;
    perform charm.audit('itinerary_cancelled','plans',p_id);
    return;
  end if;
  select count(*),count(*) filter(where visit_id is not null) into total,completed
    from charm.plan_stops where plan_id=p_id and status<>'cancelled';
  update charm.plans set status=case when total=0 then 'completed' when completed=total then 'completed' else 'partially_completed' end,
    completed_at=now(),updated_at=now() where id=p_id;
  perform charm.audit('itinerary_closed','plans',p_id,jsonb_build_object('planned',total,'completed',completed));
end $$;

-- 5. Travel request API ------------------------------------------------------
create or replace function charm.save_travel_request(
  p_key uuid,p_id bigint,p_purpose text,p_origin text,p_destination text,p_depart text,p_return text,
  p_client bigint,p_advance boolean,p_notes text,p_items jsonb,p_itineraries jsonb,p_submit boolean default false
) returns bigint language plpgsql security definer set search_path='' as $$
declare
  a bigint:=charm.require_actor(); v_id bigint; old bigint; current charm.expenses; item jsonb;
  depart timestamptz; back timestamptz; total numeric:=0; link text; plan_id bigint;
  material boolean:=false; snapshot jsonb; links_old text; links_new text;
begin
  if p_purpose is null or length(trim(p_purpose)) not between 3 and 10000 then raise exception 'invalid'; end if;
  if p_origin is null or length(trim(p_origin)) not between 2 and 200 then raise exception 'invalid'; end if;
  if p_destination is null or length(trim(p_destination)) not between 2 and 200 then raise exception 'invalid'; end if;
  if p_depart is null or p_return is null then raise exception 'invalid'; end if;
  depart:=p_depart::timestamptz; back:=p_return::timestamptz;
  if depart is null or back is null or back<=depart then raise exception 'invalid'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>50 then raise exception 'invalid'; end if;
  if p_itineraries is not null and (jsonb_typeof(p_itineraries)<>'array' or jsonb_array_length(p_itineraries)>50) then raise exception 'invalid'; end if;
  for item in select value from jsonb_array_elements(p_items) loop
    if coalesce(item->>'kind','') not in ('transport','accommodation','other') or coalesce(item->>'label','')='' or coalesce(item->>'amount','') !~ '^\d{1,8}(\.\d{1,2})?$' then raise exception 'invalid'; end if;
    total:=total+(item->>'amount')::numeric;
  end loop;
  if total>100000000 then raise exception 'invalid'; end if;
  if p_client is not null and not exists(select 1 from charm.clients c where c.id=p_client and charm.can_access(c.salesperson_id)) then raise exception 'forbidden'; end if;
  if p_itineraries is not null then
    for link in select jsonb_array_elements_text(p_itineraries) loop
      if link !~ '^\d+$' or not exists(select 1 from charm.plans p where p.id=link::bigint and p.salesperson_id=a) then raise exception 'forbidden'; end if;
    end loop;
  end if;
  if p_submit and total<=0 then raise exception 'invalidMoney'; end if;
  old:=charm.claim(p_key,'travel_request',jsonb_build_array(p_id,p_purpose,p_origin,p_destination,p_depart,p_return,p_client,p_advance,p_notes,p_items,p_itineraries,p_submit));
  if old is not null then return old; end if;

  if p_id is not null then
    select coalesce(string_agg(plans.id::text,',' order by plans.id),'') into links_old
      from charm.plans where plans.travel_request_id=p_id;
  end if;
  links_new:=case when p_itineraries is null then links_old else
    (select coalesce(string_agg(value,',' order by value),'') from jsonb_array_elements_text(p_itineraries)) end;

  if p_id is null then
    insert into charm.expenses(submission_key,salesperson_id,date,client_id,budget,notes,status,purpose,origin,destination,depart_at,return_at,
      advance_required,total_estimated,submitted_at,created_at,updated_at)
    values(p_key,a,(depart at time zone 'Africa/Nairobi')::date,p_client,null,coalesce(p_notes,''),
      case when p_submit then 'pending_approval' else 'draft' end,p_purpose,p_origin,p_destination,depart,back,p_advance,total,
      case when p_submit then now() else null end,now(),now()) returning id into v_id;
    perform charm.audit(case when p_submit then 'travel_request_submitted' else 'travel_request_created' end,'expenses',v_id);
  else
    select * into current from charm.expenses where expenses.id=p_id for update;
    if not found then raise exception 'notFound'; end if;
    if not charm.can_access(current.salesperson_id) then raise exception 'forbidden'; end if;
    if current.status in ('draft','returned','pending') then
      v_id:=p_id;
      update charm.expenses set date=(depart at time zone 'Africa/Nairobi')::date,client_id=p_client,notes=coalesce(p_notes,''),
        purpose=p_purpose,origin=p_origin,destination=p_destination,depart_at=depart,return_at=back,advance_required=p_advance,
        total_estimated=total,status=case when p_submit then 'pending_approval' else current.status end,
        submitted_at=case when p_submit then now() else submitted_at end,updated_at=now()
      where expenses.id=v_id;
      perform charm.audit(case when p_submit then 'travel_request_submitted' else 'travel_request_updated' end,'expenses',v_id);
    elsif current.status in ('approved','finance_review','in_progress') then
      material:=current.destination is distinct from p_destination or current.origin is distinct from p_origin
        or current.depart_at is distinct from depart or current.return_at is distinct from back
        or current.total_estimated is distinct from total or current.purpose is distinct from p_purpose
        or current.advance_required is distinct from p_advance or current.client_id is distinct from p_client
        or (p_itineraries is not null and links_old is distinct from links_new);
      if not material then
        update charm.expenses set notes=coalesce(p_notes,''),updated_at=now() where expenses.id=p_id;
        perform charm.audit('travel_request_notes_updated','expenses',p_id);
        return charm.finish(p_key,p_id);
      end if;
      snapshot:=jsonb_build_object('status',current.status,'purpose',current.purpose,'origin',current.origin,'destination',current.destination,
        'departAt',current.depart_at,'returnAt',current.return_at,'total',current.total_estimated,'advance',current.advance_required);
      v_id:=p_id;
      update charm.expenses set date=(depart at time zone 'Africa/Nairobi')::date,client_id=p_client,notes=coalesce(p_notes,''),
        purpose=p_purpose,origin=p_origin,destination=p_destination,depart_at=depart,return_at=back,advance_required=p_advance,
        total_estimated=total,status='pending_approval',decided_by=null,decided_at=null,decision_reason=null,
        finance_review_required=false,submitted_at=now(),updated_at=now()
      where expenses.id=v_id;
      perform charm.audit('travel_request_amended','expenses',v_id,jsonb_build_object('previous',snapshot,'requiresApproval',true));
    else
      raise exception 'requestLocked';
    end if;
  end if;

  delete from charm.travel_request_items where travel_request_items.request_id=v_id;
  for item in select value from jsonb_array_elements(p_items) loop
    insert into charm.travel_request_items(request_id,kind,label,amount)
    values(v_id,item->>'kind',trim(item->>'label'),(item->>'amount')::numeric);
  end loop;

  if p_itineraries is not null then
    update charm.plans set travel_request_id=null,updated_at=now()
      where plans.travel_request_id=v_id and plans.salesperson_id=a;
    for link in select jsonb_array_elements_text(p_itineraries) loop
      plan_id:=link::bigint;
      update charm.plans set travel_request_id=v_id,updated_at=now()
        where plans.id=plan_id and plans.salesperson_id=a;
    end loop;
  end if;
  return charm.finish(p_key,v_id);
end $$;

create or replace function charm.submit_travel_request(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); e charm.expenses;
begin
  select * into e from charm.expenses where id=p_id for update;
  if not found then raise exception 'notFound'; end if;
  if not charm.can_access(e.salesperson_id) then raise exception 'forbidden'; end if;
  if e.status not in ('draft','returned','pending') then raise exception 'requestLocked'; end if;
  if coalesce(e.total_estimated,0)<=0 or e.purpose is null or e.origin is null or e.destination is null or e.depart_at is null or e.return_at is null then raise exception 'invalid'; end if;
  if e.return_at<=e.depart_at then raise exception 'invalid'; end if;
  update charm.expenses set status='pending_approval',submitted_at=now(),updated_at=now() where id=p_id;
  perform charm.audit('travel_request_submitted','expenses',p_id);
end $$;

-- A cash advance is handed to Finance only after the business approval.
create or replace function charm.travel_finance_request(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare e charm.expenses; cid bigint;
begin
  select * into e from charm.expenses where expenses.id=p_id;
  if not found or not e.advance_required or coalesce(e.total_estimated,0)<=0 then return; end if;
  select id into cid from charm.finance_categories where name='Travel' limit 1;
  if cid is null then select id into cid from charm.finance_categories order by id limit 1; end if;
  if cid is null then return; end if;
  insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,status,source_expense_id,created_at,updated_at)
  values(e.salesperson_id,'staff',cid,e.total_estimated,coalesce(e.purpose,'Travel advance'),
    coalesce((e.depart_at at time zone 'Africa/Nairobi')::date,current_date),
    coalesce((e.return_at at time zone 'Africa/Nairobi')::date,current_date)+7,'pending',e.id,now(),now())
  on conflict(source_expense_id) do nothing;
end $$;

create or replace function charm.decide_travel_request(p_id bigint,p_decision text,p_reason text default null) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); e charm.expenses; threshold numeric; next_status text;
begin
  if p_decision not in ('approve','reject','return') then raise exception 'invalid'; end if;
  select * into e from charm.expenses where id=p_id for update;
  if not found then raise exception 'notFound'; end if;
  if e.salesperson_id=a then raise exception 'selfApproval'; end if;
  if e.status not in ('pending_approval','pending') then raise exception 'alreadyReviewed'; end if;
  if p_decision='reject' and coalesce(length(trim(p_reason)),0)<1 then raise exception 'reasonRequired'; end if;
  if p_decision in ('reject','return') and coalesce(length(trim(p_reason)),0)<3 then raise exception 'reasonRequired'; end if;
  if p_decision='approve' then
    select finance_review_threshold into threshold from charm.travel_policy where id=1;
    if threshold is not null and e.total_estimated>=threshold then next_status:='finance_review'; else next_status:='approved'; end if;
  elsif p_decision='reject' then next_status:='rejected';
  else next_status:='returned'; end if;
  update charm.expenses set status=next_status,decided_by=a,decided_at=now(),decision_reason=nullif(trim(p_reason),''),
    finance_review_required=(next_status='finance_review'),updated_at=now() where id=p_id;
  if next_status='approved' then perform charm.travel_finance_request(p_id); end if;
  perform charm.audit('travel_request_'||next_status,'expenses',p_id,jsonb_build_object('reason',p_reason));
end $$;

create or replace function charm.finance_decide_travel_request(p_id bigint,p_decision text,p_reason text default null) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); e charm.expenses;
begin
  if not (charm.finance_operator() or charm.is_admin()) then raise exception 'forbidden'; end if;
  if p_decision not in ('approve','reject') then raise exception 'invalid'; end if;
  if p_decision='reject' and coalesce(length(trim(p_reason)),0)<3 then raise exception 'reasonRequired'; end if;
  select * into e from charm.expenses where id=p_id for update;
  if not found then raise exception 'notFound'; end if;
  if e.status<>'finance_review' then raise exception 'alreadyReviewed'; end if;
  update charm.expenses set status=case when p_decision='approve' then 'approved' else 'rejected' end,
    decided_by=a,decided_at=now(),decision_reason=nullif(trim(p_reason),''),finance_review_required=false,updated_at=now()
  where id=p_id;
  if p_decision='approve' then perform charm.travel_finance_request(p_id); end if;
  perform charm.audit('travel_request_finance_'||case when p_decision='approve' then 'approved' else 'rejected' end,'expenses',p_id,jsonb_build_object('reason',p_reason));
end $$;

create or replace function charm.advance_travel_request(p_id bigint,p_status text) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); e charm.expenses;
begin
  if p_status not in ('in_progress','completed','cancelled') then raise exception 'invalid'; end if;
  select * into e from charm.expenses where id=p_id for update;
  if not found then raise exception 'notFound'; end if;
  if not charm.can_access(e.salesperson_id) then raise exception 'forbidden'; end if;
  if p_status='in_progress' and e.status<>'approved' then raise exception 'requestLocked'; end if;
  if p_status='completed' and e.status not in ('approved','in_progress') then raise exception 'requestLocked'; end if;
  if p_status='cancelled' and e.status in ('completed','cancelled') then raise exception 'requestLocked'; end if;
  update charm.expenses set status=p_status,completed_at=case when p_status in ('completed','cancelled') then now() else completed_at end,
    updated_at=now() where id=p_id;
  perform charm.audit('travel_request_'||p_status,'expenses',p_id);
end $$;

create or replace function charm.save_travel_policy(p_threshold numeric) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin();
begin
  if p_threshold is not null and (p_threshold<0 or p_threshold>100000000) then raise exception 'invalid'; end if;
  insert into charm.travel_policy(id,finance_review_threshold,updated_by,updated_at) values(1,p_threshold,a,now())
  on conflict(id) do update set finance_review_threshold=excluded.finance_review_threshold,updated_by=excluded.updated_by,updated_at=now();
  perform charm.audit('travel_policy_updated','travel_policy',1,jsonb_build_object('threshold',p_threshold));
end $$;

create or replace function charm.attach_travel_document(p_id bigint,p_path text,p_name text,p_type text default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); e charm.expenses; id bigint;
begin
  select * into e from charm.expenses where id=p_id for update;
  if not found or not charm.can_access(e.salesperson_id) then raise exception 'forbidden'; end if;
  if e.status not in ('draft','returned') then raise exception 'requestLocked'; end if;
  if p_path not like 'travel/'||p_id||'/%' or coalesce(length(p_name),0) not between 1 and 200 then raise exception 'invalid'; end if;
  if p_type is not null and p_type not in ('image/jpeg','image/png','image/webp','application/pdf') then raise exception 'fileInvalid'; end if;
  if not exists(select 1 from storage.objects where bucket_id='charm-private' and name=p_path) then raise exception 'forbidden'; end if;
  insert into charm.travel_request_documents(request_id,path,file_name,content_type,uploaded_by)
  values(p_id,p_path,p_name,p_type,a) on conflict(path) do nothing returning id into id;
  perform charm.audit('travel_document_attached','expenses',p_id,jsonb_build_object('path',p_path));
  return id;
end $$;

create or replace function charm.remove_travel_document(p_id bigint,p_document bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); d charm.travel_request_documents; e charm.expenses;
begin
  select * into e from charm.expenses where id=p_id for update;
  if not found or not charm.can_access(e.salesperson_id) then raise exception 'forbidden'; end if;
  if e.status not in ('draft','returned') then raise exception 'requestLocked'; end if;
  select * into d from charm.travel_request_documents where id=p_document and request_id=p_id;
  if not found then raise exception 'notFound'; end if;
  delete from charm.travel_request_documents where id=p_document;
  delete from storage.objects where bucket_id='charm-private' and name=d.path;
  perform charm.audit('travel_document_removed','expenses',p_id,jsonb_build_object('path',d.path));
end $$;

-- 6. Planned visits link to real visit records instead of duplicating them.
create or replace function charm.link_visit_to_itinerary() returns trigger language plpgsql security definer set search_path='' as $$
declare stop_id bigint; plan_id bigint;
begin
  select s.id,s.plan_id into stop_id,plan_id
  from charm.plan_stops s join charm.plans p on p.id=s.plan_id
  where s.client_id=new.client_id and s.visit_id is null and s.status<>'cancelled'
    and p.salesperson_id=new.salesperson_id and p.status in ('planned','in_progress','partially_completed','completed')
    and (new.check_in_at at time zone 'Africa/Nairobi')::date=p.date
  order by s.sequence limit 1;
  if stop_id is not null then
    update charm.plan_stops set visit_id=new.id,status='completed',updated_at=now() where id=stop_id;
    update charm.plans set status=case when status in ('planned','partially_completed') then 'in_progress' else status end,updated_at=now() where id=plan_id;
  end if;
  return new;
end $$;
drop trigger if exists visits_link_itinerary on charm.visits;
create trigger visits_link_itinerary after insert on charm.visits for each row execute function charm.link_visit_to_itinerary();

-- 7. Targeted travel notifications: owner, approver and finance only when required.
create or replace function charm.notify_travel_event() returns trigger language plpgsql security definer set search_path='' as $$
declare actor bigint:=charm.actor(); owner bigint; record_id bigint; next_status text; previous_status text; event_name text; token text; rec record;
begin
  record_id:=new.id; owner:=new.salesperson_id; next_status:=coalesce(new.status,'');
  previous_status:=case when tg_op='UPDATE' then coalesce(old.status,'') else '' end;
  if tg_op='UPDATE' and next_status=previous_status and (to_jsonb(new)-'updated_at')=(to_jsonb(old)-'updated_at') then return new; end if;
  event_name:=case
    when tg_table_name='plans' and next_status in ('planned','in_progress','completed','partially_completed','cancelled') then 'itinerary_'||next_status
    when tg_table_name='plans' then 'itinerary_updated'
    else 'travel_request_'||coalesce(nullif(next_status,''),'updated') end;
  token:=tg_table_name||':'||record_id||':'||next_status||':'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS');
  for rec in
    select id,role::text as role from charm.users u where u.active and id<>coalesce(actor,-1) and (
      (tg_table_name='plans' and next_status in ('planned','pending') and role='admin')
      or (tg_table_name='plans' and next_status in ('approved','rejected') and (id=owner or role='admin'))
      or (tg_table_name='expenses' and (
        (next_status in ('pending_approval') and role='admin')
        or (next_status in ('approved','rejected','returned','finance_review') and (id=owner or role='admin'))
        or (next_status='finance_review' and role in ('finance_officer','finance_manager'))
        or (next_status='approved' and coalesce((to_jsonb(new)->>'advance_required')::boolean,false) and role in ('finance_officer','finance_manager'))
      ))
    )
  loop
    insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
    values(rec.id,null,event_name,token||':'||rec.id,tg_table_name,record_id) on conflict do nothing;
  end loop;
  return new;
end $$;
drop trigger if exists workspace_activity_notify on charm.plans;
drop trigger if exists workspace_activity_notify on charm.expenses;
drop trigger if exists travel_event_notify on charm.plans;
create trigger travel_event_notify after insert or update on charm.plans for each row execute function charm.notify_travel_event();
drop trigger if exists travel_event_notify on charm.expenses;
create trigger travel_event_notify after insert or update on charm.expenses for each row execute function charm.notify_travel_event();

-- 8. Reporting: half-open Kenyan day windows and distinct travel amounts.
create or replace function charm.report_totals(p_start date,p_end date,p_salesperson bigint,p_client bigint) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'visits',(select count(*)::int from charm.visits v where v.check_in_at>=charm.business_day_start(p_start) and v.check_in_at<charm.business_day_end(p_end) and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'completed',(select count(*)::int from charm.visits v where v.check_in_at>=charm.business_day_start(p_start) and v.check_in_at<charm.business_day_end(p_end) and v.check_out_at is not null and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'incomplete',(select count(*)::int from charm.visits v where v.check_in_at>=charm.business_day_start(p_start) and v.check_in_at<charm.business_day_end(p_end) and v.check_out_at is null and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'clients',(select count(distinct v.client_id)::int from charm.visits v where v.check_in_at>=charm.business_day_start(p_start) and v.check_in_at<charm.business_day_end(p_end) and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'salespeople',(select count(distinct v.salesperson_id)::int from charm.visits v where v.check_in_at>=charm.business_day_start(p_start) and v.check_in_at<charm.business_day_end(p_end) and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'gpsExceptions',(select count(*)::int from charm.visits v where v.check_in_at>=charm.business_day_start(p_start) and v.check_in_at<charm.business_day_end(p_end) and v.gps_status in ('failed','network_failed') and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'followUpsDue',(select count(*)::int from charm.visits v where v.check_in_at>=charm.business_day_start(p_start) and v.check_in_at<charm.business_day_end(p_end) and v.follow_up_date is not null and v.follow_up_date<=p_end and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'outcomes',(select coalesce(jsonb_object_agg(x.outcome,x.n),'{}'::jsonb) from (select coalesce(v.outcome,'pending') outcome,count(*)::int n from charm.visits v where v.check_in_at>=charm.business_day_start(p_start) and v.check_in_at<charm.business_day_end(p_end) and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client) group by coalesce(v.outcome,'pending')) x),
  'orders',(select jsonb_build_object(
    'created',count(*) filter(where o.created_at>=charm.business_day_start(p_start) and o.created_at<charm.business_day_end(p_end)),
    'createdValue',coalesce(sum(o.total) filter(where o.created_at>=charm.business_day_start(p_start) and o.created_at<charm.business_day_end(p_end)),0),
    'drafts',count(*) filter(where o.status='draft' and o.created_at>=charm.business_day_start(p_start) and o.created_at<charm.business_day_end(p_end)),
    'submitted',count(*) filter(where o.status<>'draft' and o.contract_submitted_at>=charm.business_day_start(p_start) and o.contract_submitted_at<charm.business_day_end(p_end)),
    'submittedValue',coalesce(sum(o.total) filter(where o.status<>'draft' and o.contract_submitted_at>=charm.business_day_start(p_start) and o.contract_submitted_at<charm.business_day_end(p_end)),0),
    'pending',count(*) filter(where o.status='pending' and o.contract_submitted_at>=charm.business_day_start(p_start) and o.contract_submitted_at<charm.business_day_end(p_end)),
    'confirmed',count(*) filter(where o.status='confirmed' and o.confirmed_at>=charm.business_day_start(p_start) and o.confirmed_at<charm.business_day_end(p_end)),
    'confirmedValue',coalesce(sum(o.total) filter(where o.status='confirmed' and o.confirmed_at>=charm.business_day_start(p_start) and o.confirmed_at<charm.business_day_end(p_end)),0),
    'rejected',count(*) filter(where o.status in ('rejected','cancelled') and o.contract_submitted_at>=charm.business_day_start(p_start) and o.contract_submitted_at<charm.business_day_end(p_end))
  ) from charm.orders o where (p_salesperson is null or o.salesperson_id=p_salesperson) and (p_client is null or o.client_id=p_client)),
  'travel',(select jsonb_build_object(
    'itineraries',(select count(*)::int from charm.plans p where p.date between p_start and p_end and (p_salesperson is null or p.salesperson_id=p_salesperson) and p.status<>'draft'),
    'plannedStops',(select count(*)::int from charm.plan_stops s join charm.plans p on p.id=s.plan_id where p.date between p_start and p_end and s.status<>'cancelled' and (p_salesperson is null or p.salesperson_id=p_salesperson) and (p_client is null or s.client_id=p_client)),
    'completedStops',(select count(*)::int from charm.plan_stops s join charm.plans p on p.id=s.plan_id where p.date between p_start and p_end and s.visit_id is not null and (p_salesperson is null or p.salesperson_id=p_salesperson) and (p_client is null or s.client_id=p_client)),
    'missedStops',(select count(*)::int from charm.plan_stops s join charm.plans p on p.id=s.plan_id where p.date between p_start and p_end and s.visit_id is null and s.status<>'cancelled' and coalesce(s.appointment_at,charm.business_day_end(p.date))<now() and (p_salesperson is null or p.salesperson_id=p_salesperson) and (p_client is null or s.client_id=p_client)),
    'rescheduledStops',(select count(*)::int from charm.plan_stops s join charm.plans p on p.id=s.plan_id where p.date between p_start and p_end and s.rescheduled_to is not null and (p_salesperson is null or p.salesperson_id=p_salesperson) and (p_client is null or s.client_id=p_client)),
    'outstandingStops',(select count(*)::int from charm.plan_stops s join charm.plans p on p.id=s.plan_id where p.date between p_start and p_end and s.visit_id is null and s.status<>'cancelled' and coalesce(s.appointment_at,charm.business_day_end(p.date))>=now() and (p_salesperson is null or p.salesperson_id=p_salesperson) and (p_client is null or s.client_id=p_client)),
    'requestsSubmitted',(select count(*)::int from charm.expenses e where e.submitted_at>=charm.business_day_start(p_start) and e.submitted_at<charm.business_day_end(p_end) and e.status<>'draft' and (p_salesperson is null or e.salesperson_id=p_salesperson) and (p_client is null or e.client_id=p_client)),
    'requestsAwaitingApproval',(select count(*)::int from charm.expenses e where e.status in ('pending','pending_approval','finance_review') and (p_salesperson is null or e.salesperson_id=p_salesperson) and (p_client is null or e.client_id=p_client)),
    'requestsReturned',(select count(*)::int from charm.expenses e where e.status in ('returned','rejected') and (p_salesperson is null or e.salesperson_id=p_salesperson) and (p_client is null or e.client_id=p_client)),
    'requestsApproved',(select count(*)::int from charm.expenses e where e.decided_at>=charm.business_day_start(p_start) and e.decided_at<charm.business_day_end(p_end) and e.status in ('approved','in_progress','completed') and (p_salesperson is null or e.salesperson_id=p_salesperson) and (p_client is null or e.client_id=p_client)),
    'estimatedCost',(select coalesce(sum(e.total_estimated),0) from charm.expenses e where e.submitted_at>=charm.business_day_start(p_start) and e.submitted_at<charm.business_day_end(p_end) and e.status<>'draft' and (p_salesperson is null or e.salesperson_id=p_salesperson) and (p_client is null or e.client_id=p_client)),
    'approvedCost',(select coalesce(sum(e.total_estimated),0) from charm.expenses e where e.decided_at>=charm.business_day_start(p_start) and e.decided_at<charm.business_day_end(p_end) and e.status in ('approved','in_progress','completed') and (p_salesperson is null or e.salesperson_id=p_salesperson) and (p_client is null or e.client_id=p_client)),
    'actualCost',(select coalesce(sum(d.amount),0) from charm.finance_disbursements d join charm.finance_requests fr on fr.id=d.request_id join charm.expenses e on e.id=fr.source_expense_id where e.decided_at>=charm.business_day_start(p_start) and e.decided_at<charm.business_day_end(p_end) and (p_salesperson is null or e.salesperson_id=p_salesperson) and (p_client is null or e.client_id=p_client))
  ))
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
  'period',p_period,'periodStart',p_start,'periodEnd',p_end,'timezone','Africa/Nairobi','weekStartsOn','Monday','generatedAt',now(),
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
       from charm.visits vv where vv.salesperson_id=s.id and vv.check_in_at>=charm.business_day_start(p_start) and vv.check_in_at<charm.business_day_end(p_end)
       and (p_client is null or vv.client_id=p_client) group by coalesce(vv.outcome,'pending')) x) outcomes
   from charm.users s join charm.visits v on v.salesperson_id=s.id
   where v.check_in_at>=charm.business_day_start(p_start) and v.check_in_at<charm.business_day_end(p_end) and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)
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
   where v.check_in_at>=charm.business_day_start(p_start) and v.check_in_at<charm.business_day_end(p_end) and (p_salesperson is null or v.salesperson_id=p_salesperson) and (p_client is null or v.client_id=p_client)),
  'orders',(select coalesce(jsonb_agg(jsonb_build_object(
     'id',o.id,'client',c.name,'salesperson',s.name,'status',o.status,'contractStatus',o.contract_status,
     'total',o.total,'createdAt',o.created_at,'submittedAt',o.contract_submitted_at,'confirmedAt',o.confirmed_at
   ) order by o.created_at desc),'[]'::jsonb)
   from charm.orders o join charm.clients c on c.id=o.client_id join charm.users s on s.id=o.salesperson_id
   where ((o.created_at>=charm.business_day_start(p_start) and o.created_at<charm.business_day_end(p_end))
      or (o.confirmed_at is not null and o.confirmed_at>=charm.business_day_start(p_start) and o.confirmed_at<charm.business_day_end(p_end))
      or (o.contract_submitted_at is not null and o.contract_submitted_at>=charm.business_day_start(p_start) and o.contract_submitted_at<charm.business_day_end(p_end)))
     and (p_salesperson is null or o.salesperson_id=p_salesperson) and (p_client is null or o.client_id=p_client)),
  'travelRequests',(select coalesce(jsonb_agg(jsonb_build_object(
     'id',e.id,'salesperson',u.name,'purpose',e.purpose,'origin',e.origin,'destination',e.destination,
     'departAt',e.depart_at,'returnAt',e.return_at,'status',e.status,'total',e.total_estimated,
     'submittedAt',e.submitted_at,'decidedAt',e.decided_at,'decisionReason',e.decision_reason,
     'advanceRequired',e.advance_required,
     'actualPaid',(select coalesce(sum(d.amount),0) from charm.finance_disbursements d join charm.finance_requests fr on fr.id=d.request_id where fr.source_expense_id=e.id)
   ) order by e.id desc),'[]'::jsonb)
   from charm.expenses e join charm.users u on u.id=e.salesperson_id
   where e.status<>'draft'
     and ((e.submitted_at>=charm.business_day_start(p_start) and e.submitted_at<charm.business_day_end(p_end))
       or (e.decided_at is not null and e.decided_at>=charm.business_day_start(p_start) and e.decided_at<charm.business_day_end(p_end))
       or (e.depart_at>=charm.business_day_start(p_start) and e.depart_at<charm.business_day_end(p_end)))
     and (p_salesperson is null or e.salesperson_id=p_salesperson) and (p_client is null or e.client_id=p_client)),
  'itineraries',(select coalesce(jsonb_agg(jsonb_build_object(
     'id',p.id,'title',coalesce(p.title,'Untitled itinerary'),'salesperson',u.name,'date',p.date,'status',p.status,
     'startLocation',p.start_location,'transportMode',p.transport_mode,
     'plannedStops',(select count(*)::int from charm.plan_stops s where s.plan_id=p.id and s.status<>'cancelled'),
     'completedStops',(select count(*)::int from charm.plan_stops s where s.plan_id=p.id and s.visit_id is not null),
     'rescheduledStops',(select count(*)::int from charm.plan_stops s where s.plan_id=p.id and s.rescheduled_to is not null)
   ) order by p.date,p.id),'[]'::jsonb)
   from charm.plans p join charm.users u on u.id=p.salesperson_id
   where p.date between p_start and p_end and p.status<>'draft'
     and (p_salesperson is null or p.salesperson_id=p_salesperson)
     and (p_client is null or exists(select 1 from charm.plan_stops s where s.plan_id=p.id and s.client_id=p_client)))
 ) into v;
 return v;
end $$;

create or replace function charm.mark_management_reports_stale() returns trigger language plpgsql security definer set search_path='' as $$
declare d date; d2 date; owner bigint;
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
 elsif tg_table_name='plans' then
  d:=new.date;
  update charm.management_reports set is_stale=true,updated_at=now()
  where d between period_start and period_end and (salesperson_id is null or salesperson_id=new.salesperson_id);
 elsif tg_table_name='expenses' then
  d:=((coalesce(new.submitted_at,new.created_at,now())) at time zone 'Africa/Nairobi')::date;
  d2:=case when new.decided_at is null then null else (new.decided_at at time zone 'Africa/Nairobi')::date end;
  update charm.management_reports set is_stale=true,updated_at=now()
  where (d between period_start and period_end or (d2 is not null and d2 between period_start and period_end))
   and (salesperson_id is null or salesperson_id=new.salesperson_id) and (client_id is null or client_id=new.client_id);
 elsif tg_table_name='plan_stops' then
  if tg_op='DELETE' then
    select salesperson_id,date into owner,d from charm.plans where plans.id=old.plan_id;
  else
    select salesperson_id,date into owner,d from charm.plans where plans.id=new.plan_id;
  end if;
  if d is not null then
    update charm.management_reports set is_stale=true,updated_at=now()
    where d between period_start and period_end and (salesperson_id is null or salesperson_id=owner);
  end if;
  if tg_op='DELETE' then return old; end if;
 end if;
 return new;
end $$;
drop trigger if exists plan_stops_mark_reports_stale on charm.plan_stops;
create trigger plan_stops_mark_reports_stale after insert or update or delete on charm.plan_stops for each row execute function charm.mark_management_reports_stale();
drop trigger if exists plans_mark_reports_stale on charm.plans;
create trigger plans_mark_reports_stale after insert or update on charm.plans for each row execute function charm.mark_management_reports_stale();
drop trigger if exists expenses_mark_reports_stale on charm.expenses;
create trigger expenses_mark_reports_stale after insert or update on charm.expenses for each row execute function charm.mark_management_reports_stale();

create index if not exists plans_travel_request on charm.plans(travel_request_id);
create index if not exists plans_date_owner on charm.plans(date,salesperson_id);
create index if not exists expenses_status_depart on charm.expenses(status,depart_at);
create index if not exists expenses_owner_submitted on charm.expenses(salesperson_id,submitted_at desc);

revoke execute on function charm.business_day_start(date),charm.business_day_end(date),charm.save_itinerary(uuid,bigint,text,bigint,date,text,text,integer,text,jsonb,bigint,boolean),
  charm.submit_itinerary(bigint),charm.start_itinerary(bigint),charm.finish_itinerary(bigint,boolean),
  charm.save_travel_request(uuid,bigint,text,text,text,text,text,bigint,boolean,text,jsonb,jsonb,boolean),
  charm.submit_travel_request(bigint),charm.decide_travel_request(bigint,text,text),charm.finance_decide_travel_request(bigint,text,text),
  charm.advance_travel_request(bigint,text),charm.save_travel_policy(numeric),charm.attach_travel_document(bigint,text,text,text),
  charm.remove_travel_document(bigint,bigint),charm.link_visit_to_itinerary(),charm.notify_travel_event(),
  charm.travel_finance_request(bigint),
  charm.report_totals(date,date,bigint,bigint),charm.build_sales_report(text,date,bigint,bigint),charm.mark_management_reports_stale()
  from public,anon,authenticated;
grant execute on function charm.save_itinerary(uuid,bigint,text,bigint,date,text,text,integer,text,jsonb,bigint,boolean),
  charm.submit_itinerary(bigint),charm.start_itinerary(bigint),charm.finish_itinerary(bigint,boolean),
  charm.save_travel_request(uuid,bigint,text,text,text,text,text,bigint,boolean,text,jsonb,jsonb,boolean),
  charm.submit_travel_request(bigint),charm.decide_travel_request(bigint,text,text),charm.finance_decide_travel_request(bigint,text,text),
  charm.advance_travel_request(bigint,text),charm.save_travel_policy(numeric),charm.attach_travel_document(bigint,text,text,text),
  charm.remove_travel_document(bigint,bigint),charm.build_sales_report(text,date,bigint,bigint),
  charm.report_totals(date,date,bigint,bigint) to authenticated;
grant execute on function charm.business_day_start(date),charm.business_day_end(date) to authenticated;

commit;

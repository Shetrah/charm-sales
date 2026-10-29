-- People, customers, attendance, leave, and commissions.
-- Additive: existing staff, clients, orders, visits and financial records are preserved.
begin;

-- 1. Stable public staff identity. The numeric id remains the internal key.
alter table charm.users add column if not exists staff_code varchar(20);
update charm.users set staff_code='CK-'||lpad(id::text,4,'0');
alter table charm.users alter column staff_code set not null;
create unique index if not exists users_staff_code_key on charm.users(staff_code);
grant select(staff_code) on charm.users to authenticated;

create or replace function charm.assign_staff_code() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.staff_code is null or btrim(new.staff_code)='' then
    new.staff_code:='CK-'||lpad(new.id::text,4,'0');
  end if;
  return new;
end $$;
drop trigger if exists assign_staff_code on charm.users;
create trigger assign_staff_code before insert on charm.users
for each row execute function charm.assign_staff_code();

-- 2. Customer lifecycle and dated ownership history.
alter table charm.clients add column if not exists lifecycle_status text not null default 'active';
alter table charm.clients add column if not exists lifecycle_reason text;
alter table charm.clients add column if not exists lifecycle_changed_at timestamptz;
alter table charm.clients add column if not exists lifecycle_changed_by bigint references charm.users(id);
alter table charm.clients drop constraint if exists clients_lifecycle_status_check;
alter table charm.clients add constraint clients_lifecycle_status_check
  check(lifecycle_status in ('active','prospective','declined'));

create table if not exists charm.client_assignments(
  id bigserial primary key,
  client_id bigint not null references charm.clients(id),
  salesperson_id bigint not null references charm.users(id),
  assigned_by bigint references charm.users(id),
  assigned_at timestamptz not null default now(),
  effective_from date not null default ((now() at time zone 'Africa/Nairobi')::date),
  effective_to date,
  reason text,
  active boolean not null default true,
  check(effective_to is null or effective_to>=effective_from)
);
create index if not exists client_assignments_client on charm.client_assignments(client_id,effective_from desc);
create unique index if not exists client_assignments_one_active on charm.client_assignments(client_id) where active;
insert into charm.client_assignments(client_id,salesperson_id,assigned_at,effective_from,reason)
select c.id,c.salesperson_id,coalesce(c.created_at,now()),
       coalesce((c.created_at at time zone 'Africa/Nairobi')::date,(now() at time zone 'Africa/Nairobi')::date),
       'Initial assignment'
from charm.clients c
where not exists(select 1 from charm.client_assignments a where a.client_id=c.id and a.active);

create or replace function charm.record_client_assignment() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from charm.client_assignments a where a.client_id=new.id and a.active) then
    insert into charm.client_assignments(client_id,salesperson_id,assigned_by,effective_from,reason)
      values(new.id,new.salesperson_id,charm.actor(),(now() at time zone 'Africa/Nairobi')::date,'Initial assignment');
  end if;
  return new;
end $$;
drop trigger if exists record_client_assignment on charm.clients;
create trigger record_client_assignment after insert on charm.clients
for each row execute function charm.record_client_assignment();

create or replace function charm.assign_client(p_key uuid,p_client bigint,p_salesperson bigint,p_reason text)
returns bigint language plpgsql security definer set search_path='' as $$
declare
  a bigint:=charm.require_admin();
  c charm.clients;
  target charm.users;
  previous_owner bigint;
  previous_id bigint;
begin
  if p_client is null or p_salesperson is null or p_key is null then raise exception 'invalid'; end if;
  previous_id:=charm.claim(p_key,'client_assignment',
    jsonb_build_object('client',p_client,'salesperson',p_salesperson,'reason',coalesce(trim(p_reason),'')));
  if previous_id is not null then return previous_id; end if;
  select * into c from charm.clients where id=p_client for update;
  if not found then raise exception 'notFound'; end if;
  select * into target from charm.users where id=p_salesperson;
  if not found or not target.active or target.role not in ('salesperson','admin') then
    raise exception 'invalidSalesperson';
  end if;
  previous_owner:=c.salesperson_id;
  if previous_owner=p_salesperson then
    perform charm.finish(p_key,p_client);
    return p_client;
  end if;
  update charm.client_assignments
    set effective_to=(now() at time zone 'Africa/Nairobi')::date,active=false
    where client_id=p_client and active;
  insert into charm.client_assignments(client_id,salesperson_id,assigned_by,effective_from,reason)
    values(p_client,p_salesperson,a,(now() at time zone 'Africa/Nairobi')::date,nullif(trim(p_reason),''));
  update charm.clients set salesperson_id=p_salesperson,updated_at=now() where id=p_client;
  perform charm.audit('clientAssigned','clients',p_client,
    jsonb_build_object('from',previous_owner,'to',p_salesperson,'reason',nullif(trim(p_reason),'')));
  insert into charm.finance_notifications(recipient_id,event,event_key,entity,entity_id)
    select u.id,'clientAssigned','client-assigned:'||p_client||':'||p_salesperson||':'||u.id,'clients',p_client
    from charm.users u
    where u.active and u.id in (p_salesperson,previous_owner) and u.id<>a
    on conflict do nothing;
  perform charm.finish(p_key,p_client);
  return p_client;
end $$;

create or replace function charm.set_client_lifecycle(p_client bigint,p_status text,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); c charm.clients;
begin
  select * into c from charm.clients where id=p_client for update;
  if not found then raise exception 'notFound'; end if;
  if not charm.can_access(c.salesperson_id) then raise exception 'forbidden'; end if;
  if p_status not in ('active','prospective','declined') then raise exception 'invalid'; end if;
  if p_status=c.lifecycle_status then return; end if;
  if p_status='declined' and coalesce(length(trim(p_reason)),0)<3 then raise exception 'reasonRequired'; end if;
  update charm.clients
    set lifecycle_status=p_status,lifecycle_reason=nullif(trim(p_reason),''),
        lifecycle_changed_at=now(),lifecycle_changed_by=a,updated_at=now()
    where id=p_client;
  perform charm.audit('clientLifecycleChanged','clients',p_client,
    jsonb_build_object('from',c.lifecycle_status,'to',p_status,'reason',nullif(trim(p_reason),'')));
end $$;

-- 3. Attendance derived from verified customer visits.
create table if not exists charm.attendance_policy(
  id smallint primary key default 1 check(id=1),
  full_day_hours numeric(4,1) not null default 8 check(full_day_hours>0 and full_day_hours<=24),
  min_hours numeric(4,1) not null default 4 check(min_hours>0 and min_hours<=24),
  start_time time not null default '08:00',
  end_time time not null default '17:00',
  late_grace_minutes integer not null default 15 check(late_grace_minutes between 0 and 240),
  working_days integer[] not null default '{1,2,3,4,5}',
  updated_by bigint references charm.users(id),
  updated_at timestamptz not null default now(),
  check(min_hours<=full_day_hours)
);
insert into charm.attendance_policy(id) values(1) on conflict(id) do nothing;

create table if not exists charm.attendance_days(
  id bigserial primary key,
  salesperson_id bigint not null references charm.users(id),
  day date not null,
  first_visit_at timestamptz,
  last_visit_at timestamptz,
  visit_count integer not null default 0 check(visit_count>=0),
  hours numeric(6,2) not null default 0 check(hours>=0),
  status text not null default 'incomplete' check(status in ('full','partial','incomplete','absent','leave')),
  note text,
  corrected_by bigint references charm.users(id),
  corrected_at timestamptz,
  correction_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(salesperson_id,day)
);
create index if not exists attendance_days_scope on charm.attendance_days(salesperson_id,day desc);

create table if not exists charm.leave_types(
  id bigserial primary key,
  name text unique not null,
  paid boolean not null default true,
  annual_days numeric(5,1) not null default 0 check(annual_days>=0),
  requires_document boolean not null default false,
  active boolean not null default true
);
insert into charm.leave_types(name,paid,annual_days,requires_document) values
  ('Annual leave',true,21,false),
  ('Sick leave',true,10,true),
  ('Maternity leave',true,90,true),
  ('Paternity leave',true,14,false),
  ('Compassionate leave',true,5,false),
  ('Unpaid leave',false,0,false)
on conflict(name) do nothing;

create table if not exists charm.leave_requests(
  id bigserial primary key,
  submission_key uuid unique,
  salesperson_id bigint not null references charm.users(id),
  leave_type_id bigint not null references charm.leave_types(id),
  start_date date not null,
  end_date date not null,
  days numeric(5,1) not null default 0 check(days>=0),
  reason text not null,
  document_path text,
  status text not null default 'draft' check(status in ('draft','pending','approved','rejected','cancelled')),
  decided_by bigint references charm.users(id),
  decided_at timestamptz,
  decision_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(end_date>=start_date)
);
create index if not exists leave_requests_owner on charm.leave_requests(salesperson_id,id desc);
create index if not exists leave_requests_queue on charm.leave_requests(status,start_date);

create or replace function charm.business_days_between(p_start date,p_end date) returns numeric
language sql stable security definer set search_path='' as $$
  select count(*)::numeric
  from generate_series(p_start,p_end,'1 day') d
  where extract(isodow from d)::integer = any(
    coalesce((select working_days from charm.attendance_policy where id=1),'{1,2,3,4,5}'::integer[])
  )
$$;

create or replace function charm.refresh_attendance_day(p_user bigint,p_day date) returns void
language plpgsql security definer set search_path='' as $$
declare
  pp charm.attendance_policy;
  v_first timestamptz;
  v_last timestamptz;
  v_count integer;
  v_hours numeric;
  v_status text;
  v_leave boolean;
  v_today date:=(now() at time zone 'Africa/Nairobi')::date;
begin
  select * into pp from charm.attendance_policy where id=1;
  select count(*),min(v.check_in_at),max(coalesce(v.check_out_at,v.check_in_at))
    into v_count,v_first,v_last
    from charm.visits v
    where v.salesperson_id=p_user
      and v.check_in_at>=charm.business_day_start(p_day)
      and v.check_in_at<charm.business_day_end(p_day);
  select exists(
    select 1 from charm.leave_requests l
    where l.salesperson_id=p_user and l.status='approved'
      and p_day between l.start_date and l.end_date
  ) into v_leave;
  if v_count=0 and not v_leave then
    if p_day>=v_today then return; end if;
    v_status:='absent';v_hours:=0;
  elsif v_count=0 then
    v_status:='leave';v_hours:=0;
  else
    v_hours:=round(extract(epoch from (v_last-v_first))/3600.0,2);
    v_status:=case
      when v_hours>=pp.full_day_hours then 'full'
      when v_hours>=pp.min_hours then 'partial'
      else 'incomplete' end;
  end if;
  insert into charm.attendance_days(salesperson_id,day,first_visit_at,last_visit_at,visit_count,hours,status,updated_at)
    values(p_user,p_day,v_first,v_last,v_count,v_hours,v_status,now())
    on conflict (salesperson_id,day) do update set
      first_visit_at=excluded.first_visit_at,
      last_visit_at=excluded.last_visit_at,
      visit_count=excluded.visit_count,
      hours=excluded.hours,
      status=excluded.status,
      updated_at=now()
    where charm.attendance_days.corrected_by is null;
end $$;

create or replace function charm.attendance_from_visit() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.check_in_at is not null then
    perform charm.refresh_attendance_day(new.salesperson_id,(new.check_in_at at time zone 'Africa/Nairobi')::date);
  end if;
  return new;
end $$;
drop trigger if exists visit_attendance_sync on charm.visits;
create trigger visit_attendance_sync after insert or update of check_in_at,check_out_at,salesperson_id on charm.visits
for each row execute function charm.attendance_from_visit();

create or replace function charm.save_attendance_policy(
  p_full numeric,p_min numeric,p_start time,p_end time,p_grace integer,p_days jsonb
) returns void language plpgsql security definer set search_path='' as $$
declare
  a bigint:=charm.require_admin();
  v_days integer[];
begin
  if p_full is null or p_min is null or p_full<=0 or p_full>24 or p_min<=0 or p_min>p_full then raise exception 'invalid'; end if;
  if p_start is null or p_end is null or p_start>=p_end then raise exception 'invalid'; end if;
  if p_grace is null or p_grace not between 0 and 240 then raise exception 'invalid'; end if;
  if p_days is null or jsonb_typeof(p_days)<>'array' or jsonb_array_length(p_days)=0 then raise exception 'invalid'; end if;
  select array_agg(x::integer) into v_days from jsonb_array_elements_text(p_days) x;
  if v_days is null or exists(select 1 from unnest(v_days) d where d not between 1 and 7) then raise exception 'invalid'; end if;
  update charm.attendance_policy
    set full_day_hours=p_full,min_hours=p_min,start_time=p_start,end_time=p_end,
        late_grace_minutes=p_grace,working_days=v_days,updated_by=a,updated_at=now()
    where id=1;
  perform charm.audit('attendancePolicyUpdated','attendance_policy',1,
    jsonb_build_object('full_day_hours',p_full,'min_hours',p_min,'start',p_start,'end',p_end,'grace',p_grace,'working_days',v_days));
end $$;

create or replace function charm.correct_attendance(p_user bigint,p_day date,p_status text,p_reason text,p_note text)
returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); previous charm.attendance_days;
begin
  if p_user is null or p_day is null then raise exception 'invalid'; end if;
  if p_day>(now() at time zone 'Africa/Nairobi')::date then raise exception 'futureDate'; end if;
  if coalesce(length(trim(p_reason)),0) not between 3 and 500 then raise exception 'reasonRequired'; end if;
  select * into previous from charm.attendance_days where salesperson_id=p_user and day=p_day for update;
  if p_status='auto' then
    update charm.attendance_days set corrected_by=null,corrected_at=null,correction_reason=null,note=null,updated_at=now()
      where salesperson_id=p_user and day=p_day;
    perform charm.refresh_attendance_day(p_user,p_day);
  else
    if p_status not in ('full','partial','incomplete','absent','leave') then raise exception 'invalid'; end if;
    insert into charm.attendance_days(salesperson_id,day,status,corrected_by,corrected_at,correction_reason,note,updated_at)
      values(p_user,p_day,p_status,a,now(),trim(p_reason),nullif(trim(p_note),''),now())
      on conflict (salesperson_id,day) do update set
        status=excluded.status,corrected_by=a,corrected_at=now(),
        correction_reason=trim(p_reason),note=nullif(trim(p_note),''),updated_at=now();
  end if;
  perform charm.audit('attendanceCorrected','attendance_days',coalesce(previous.id,0),
    jsonb_build_object('salesperson_id',p_user,'day',p_day,'from',previous.status,'to',p_status,'reason',trim(p_reason),'note',nullif(trim(p_note),'')));
end $$;

create or replace function charm.attendance_report(p_from date,p_to date,p_user bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  a bigint:=charm.require_actor();
  pp charm.attendance_policy;
  target record;
  d date;
  ad charm.attendance_days;
  v_rows jsonb:='[]'::jsonb;
  v_totals jsonb:='[]'::jsonb;
  v_full integer;v_partial integer;v_incomplete integer;v_absent integer;v_leave integer;
  v_hours numeric;v_day_hours numeric;v_visits integer;v_present integer;v_days integer;
  v_status text;v_first timestamptz;v_last timestamptz;v_count integer;v_note text;v_corrected boolean;
  v_today date:=(now() at time zone 'Africa/Nairobi')::date;
begin
  if p_from is null or p_to is null or p_to<p_from or (p_to-p_from)>370 then raise exception 'invalidRange'; end if;
  if not charm.is_admin() then
    if p_user is not null and p_user<>a then raise exception 'forbidden'; end if;
    p_user:=a;
  end if;
  select * into pp from charm.attendance_policy where id=1;
  for target in
    select u.id,u.name,u.staff_code from charm.users u
    where u.active and u.role in ('salesperson','admin') and (p_user is null or u.id=p_user)
    order by u.name
  loop
    v_full:=0;v_partial:=0;v_incomplete:=0;v_absent:=0;v_leave:=0;v_hours:=0;v_visits:=0;v_present:=0;v_days:=0;
    for d in select generate_series(p_from,p_to,'1 day')::date loop
      if extract(isodow from d)::integer<>all(pp.working_days) then continue; end if;
      if d<=v_today then perform charm.refresh_attendance_day(target.id,d); end if;
      select * into ad from charm.attendance_days where salesperson_id=target.id and day=d;
      if not found then
        if d<v_today then
          v_status:='absent';
        else
          continue;
        end if;
        v_first:=null;v_last:=null;v_count:=0;v_hours:=0;v_note:=null;v_corrected:=false;
      else
        v_status:=ad.status;v_first:=ad.first_visit_at;v_last:=ad.last_visit_at;
        v_count:=ad.visit_count;v_hours:=coalesce(ad.hours,0);v_note:=ad.note;v_corrected:=ad.corrected_by is not null;
      end if;
      v_days:=v_days+1;
      if v_status='full' then v_full:=v_full+1;v_present:=v_present+1;
      elsif v_status='partial' then v_partial:=v_partial+1;v_present:=v_present+1;
      elsif v_status='incomplete' then v_incomplete:=v_incomplete+1;v_present:=v_present+1;
      elsif v_status='leave' then v_leave:=v_leave+1;
      else v_absent:=v_absent+1; end if;
      v_day_hours:=coalesce(v_hours,0);
      v_hours:=v_hours+v_day_hours;
      v_visits:=v_visits+coalesce(v_count,0);
      v_rows:=v_rows||jsonb_build_array(jsonb_build_object(
        'salesperson_id',target.id,'staff_code',target.staff_code,'name',target.name,'day',d,
        'first_visit_at',v_first,'last_visit_at',v_last,'visit_count',v_count,'hours',v_day_hours,
        'status',v_status,'note',v_note,'corrected',v_corrected
      ));
    end loop;
    v_totals:=v_totals||jsonb_build_array(jsonb_build_object(
      'salesperson_id',target.id,'staff_code',target.staff_code,'name',target.name,
      'days',v_days,'present',v_present,'full',v_full,'partial',v_partial,'incomplete',v_incomplete,
      'absent',v_absent,'leave',v_leave,'hours',round(v_hours,2),'visits',v_visits
    ));
  end loop;
  return jsonb_build_object('policy',to_jsonb(pp),'from',p_from,'to',p_to,'rows',v_rows,'totals',v_totals);
end $$;

-- 4. Leave requests, decisions and balances.
create or replace function charm.save_leave_request(
  p_key uuid,p_id bigint,p_type bigint,p_start date,p_end date,p_reason text,p_document text,p_user bigint default null
) returns bigint language plpgsql security definer set search_path='' as $$
declare
  a bigint:=charm.require_actor();
  owner bigint:=coalesce(p_user,a);
  lt charm.leave_types;
  lr charm.leave_requests;
  v_id bigint;
  v_days numeric;
  previous_id bigint;
begin
  if p_user is not null and p_user<>a and not charm.is_admin() then raise exception 'forbidden'; end if;
  if p_type is null or p_start is null or p_end is null or p_start>p_end or (p_end-p_start)>366 then raise exception 'invalid'; end if;
  if coalesce(length(trim(p_reason)),0) not between 3 and 2000 then raise exception 'reasonRequired'; end if;
  select * into lt from charm.leave_types where id=p_type and active;
  if not found then raise exception 'invalidLeaveType'; end if;
  v_days:=charm.business_days_between(p_start,p_end);
  if v_days<=0 then raise exception 'noWorkingDays'; end if;
  if p_document is not null and length(p_document)>500 then raise exception 'invalidDocument'; end if;
  if p_id is null then
    if p_key is null then raise exception 'invalid'; end if;
    if p_document is not null and p_document not like 'leave/'||owner::text||'/%' then raise exception 'invalidDocument'; end if;
    previous_id:=charm.claim(p_key,'leave_request',
      jsonb_build_object('type',p_type,'start',p_start,'end',p_end,'reason',trim(p_reason),'document',coalesce(p_document,''),'owner',owner));
    if previous_id is not null then return previous_id; end if;
    insert into charm.leave_requests(submission_key,salesperson_id,leave_type_id,start_date,end_date,days,reason,document_path)
      values(p_key,owner,p_type,p_start,p_end,v_days,trim(p_reason),nullif(p_document,''))
      returning id into v_id;
    perform charm.finish(p_key,v_id);
  else
    select * into lr from charm.leave_requests where id=p_id for update;
    if not found then raise exception 'notFound'; end if;
    if lr.salesperson_id<>a and not charm.is_admin() then raise exception 'forbidden'; end if;
    if lr.status not in ('draft','rejected') then raise exception 'locked'; end if;
    owner:=lr.salesperson_id;
    if p_document is not null and p_document not like 'leave/'||owner::text||'/%' then raise exception 'invalidDocument'; end if;
    update charm.leave_requests set
      leave_type_id=p_type,start_date=p_start,end_date=p_end,days=v_days,reason=trim(p_reason),
      document_path=nullif(p_document,''),status='draft',decided_by=null,decided_at=null,decision_reason=null,updated_at=now()
      where id=p_id returning id into v_id;
  end if;
  perform charm.audit('leaveSaved','leave_requests',v_id,
    jsonb_build_object('salesperson_id',owner,'type',p_type,'start',p_start,'end',p_end,'days',v_days));
  return v_id;
end $$;

create or replace function charm.submit_leave_request(p_id bigint) returns void
language plpgsql security definer set search_path='' as $$
declare
  a bigint:=charm.require_actor();
  lr charm.leave_requests;
  lt charm.leave_types;
  remaining numeric;
begin
  select * into lr from charm.leave_requests where id=p_id for update;
  if not found then raise exception 'notFound'; end if;
  if lr.salesperson_id<>a and not charm.is_admin() then raise exception 'forbidden'; end if;
  if lr.status<>'draft' then raise exception 'locked'; end if;
  select * into lt from charm.leave_types where id=lr.leave_type_id;
  if lt.requires_document and lr.document_path is null then raise exception 'documentRequired'; end if;
  if lr.days<=0 then raise exception 'noWorkingDays'; end if;
  if lt.paid and lt.annual_days>0 then
    select lt.annual_days-coalesce(sum(x.days),0) into remaining
    from charm.leave_requests x
    where x.salesperson_id=lr.salesperson_id and x.leave_type_id=lt.id and x.status='approved'
      and extract(year from x.start_date)=extract(year from lr.start_date);
    if lr.days>remaining then raise exception 'insufficientLeaveBalance'; end if;
  end if;
  update charm.leave_requests set status='pending',updated_at=now() where id=p_id;
  perform charm.audit('leaveSubmitted','leave_requests',p_id,
    jsonb_build_object('days',lr.days,'type',lt.name));
  insert into charm.finance_notifications(recipient_id,event,event_key,entity,entity_id)
    select u.id,'leaveSubmitted','leave-submitted:'||p_id||':'||u.id,'leave_requests',p_id
    from charm.users u where u.active and u.role='admin' and u.id<>a on conflict do nothing;
end $$;

create or replace function charm.cancel_leave_request(p_id bigint) returns void
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); lr charm.leave_requests;
begin
  select * into lr from charm.leave_requests where id=p_id for update;
  if not found then raise exception 'notFound'; end if;
  if lr.salesperson_id<>a and not charm.is_admin() then raise exception 'forbidden'; end if;
  if lr.status not in ('draft','pending') then raise exception 'locked'; end if;
  update charm.leave_requests set status='cancelled',updated_at=now() where id=p_id;
  perform charm.audit('leaveCancelled','leave_requests',p_id,jsonb_build_object('previous',lr.status));
end $$;

create or replace function charm.decide_leave_request(p_id bigint,p_decision text,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare
  a bigint:=charm.require_admin();
  lr charm.leave_requests;
  lt charm.leave_types;
  d date;
  pp charm.attendance_policy;
  remaining numeric;
begin
  if p_decision not in ('approve','reject') then raise exception 'invalid'; end if;
  select * into lr from charm.leave_requests where id=p_id for update;
  if not found then raise exception 'notFound'; end if;
  if lr.status<>'pending' then raise exception 'locked'; end if;
  if lr.salesperson_id=a then raise exception 'selfApproval'; end if;
  if p_decision='reject' and coalesce(length(trim(p_reason)),0)<3 then raise exception 'reasonRequired'; end if;
  select * into lt from charm.leave_types where id=lr.leave_type_id;
  if p_decision='approve' and lt.paid and lt.annual_days>0 then
    select lt.annual_days-coalesce(sum(x.days),0) into remaining
    from charm.leave_requests x
    where x.salesperson_id=lr.salesperson_id and x.leave_type_id=lt.id and x.status='approved' and x.id<>p_id
      and extract(year from x.start_date)=extract(year from lr.start_date);
    if lr.days>remaining then raise exception 'insufficientLeaveBalance'; end if;
  end if;
  update charm.leave_requests set
    status=case when p_decision='approve' then 'approved' else 'rejected' end,
    decided_by=a,decided_at=now(),decision_reason=nullif(trim(p_reason),''),updated_at=now()
    where id=p_id;
  if p_decision='approve' then
    select * into pp from charm.attendance_policy where id=1;
    for d in select generate_series(lr.start_date,lr.end_date,'1 day')::date loop
      if extract(isodow from d)::integer=any(pp.working_days) then
        perform charm.refresh_attendance_day(lr.salesperson_id,d);
      end if;
    end loop;
  end if;
  perform charm.audit(case when p_decision='approve' then 'leaveApproved' else 'leaveRejected' end,
    'leave_requests',p_id,jsonb_build_object('days',lr.days,'reason',nullif(trim(p_reason),'')));
  insert into charm.finance_notifications(recipient_id,event,event_key,entity,entity_id)
    values(lr.salesperson_id,case when p_decision='approve' then 'leaveApproved' else 'leaveRejected' end,
      'leave-decision:'||p_id||':'||lr.salesperson_id,'leave_requests',p_id)
    on conflict do nothing;
end $$;

create or replace function charm.leave_balances(p_year integer,p_user bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); owner bigint:=coalesce(p_user,a);
begin
  if not charm.is_admin() and owner<>a then raise exception 'forbidden'; end if;
  if p_year not between 2000 and 2100 then raise exception 'invalid'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'leave_type_id',lt.id,'name',lt.name,'paid',lt.paid,'entitled',lt.annual_days,
      'approved',coalesce(ap.days,0),'pending',coalesce(pe.days,0),
      'remaining',greatest(lt.annual_days-coalesce(ap.days,0),0)
    ) order by lt.id)
    from charm.leave_types lt
    left join lateral(
      select sum(x.days) days from charm.leave_requests x
      where x.salesperson_id=owner and x.leave_type_id=lt.id and x.status='approved'
        and extract(year from x.start_date)=p_year
    ) ap on true
    left join lateral(
      select sum(x.days) days from charm.leave_requests x
      where x.salesperson_id=owner and x.leave_type_id=lt.id and x.status='pending'
        and extract(year from x.start_date)=p_year
    ) pe on true
    where lt.active
  ),'[]'::jsonb);
end $$;

-- 5. Commission rules, historical snapshots and monthly summaries.
create table if not exists charm.commission_rules(
  id bigserial primary key,
  name text not null check(length(name) between 1 and 120),
  basis text not null default 'gross' check(basis in ('gross','net','paid','delivered')),
  method text not null default 'percentage' check(method in ('percentage','fixed','tiered')),
  rate numeric(6,3),
  fixed_amount numeric(14,2),
  effective_from date not null,
  effective_to date,
  active boolean not null default true,
  notes text,
  created_by bigint references charm.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(effective_to is null or effective_to>=effective_from),
  check(method<>'percentage' or (rate is not null and rate between 0 and 100)),
  check(method<>'fixed' or (fixed_amount is not null and fixed_amount>0))
);
create table if not exists charm.commission_tiers(
  id bigserial primary key,
  rule_id bigint not null references charm.commission_rules(id) on delete cascade,
  min_amount numeric(14,2) not null check(min_amount>=0),
  max_amount numeric(14,2),
  rate numeric(6,3) not null check(rate between 0 and 100),
  check(max_amount is null or max_amount>min_amount),
  unique(rule_id,min_amount)
);
create table if not exists charm.commission_entries(
  id bigserial primary key,
  order_id bigint not null unique references charm.orders(id),
  salesperson_id bigint not null references charm.users(id),
  rule_id bigint references charm.commission_rules(id),
  basis text not null check(basis in ('gross','net','paid','delivered')),
  basis_amount numeric(14,2) not null default 0 check(basis_amount>=0),
  rate numeric(6,3),
  commission_amount numeric(14,2) not null default 0 check(commission_amount>=0),
  status text not null default 'earned' check(status in ('earned','approved','paid','reversed','adjusted')),
  period_start date not null,
  snapshot jsonb not null default '{}'::jsonb,
  computed_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists commission_entries_scope on charm.commission_entries(salesperson_id,period_start desc);
create index if not exists commission_entries_period on charm.commission_entries(period_start,status);

create or replace function charm.refresh_commission(p_order bigint) returns void
language plpgsql security definer set search_path='' as $$
declare
  e charm.commission_entries;
  o charm.orders;
  snap jsonb;
  v_basis text;
  v_method text;
  v_rate numeric;
  v_fixed numeric;
  v_amount numeric:=0;
  v_tier_rate numeric;
begin
  select * into e from charm.commission_entries where order_id=p_order for update;
  if not found then return; end if;
  if e.status not in ('earned','approved','adjusted') then return; end if;
  select * into o from charm.orders where id=p_order;
  if not found then return; end if;
  if o.status<>'confirmed' then
    update charm.commission_entries set status='reversed',commission_amount=0,basis_amount=0,updated_at=now() where id=e.id;
    return;
  end if;
  snap:=coalesce(e.snapshot->'rule','{}'::jsonb);
  v_basis:=coalesce(e.basis,snap->>'basis','gross');
  v_method:=coalesce(snap->>'method','percentage');
  v_rate:=nullif(snap->>'rate','')::numeric;
  v_fixed:=nullif(snap->>'fixed_amount','')::numeric;
  if v_basis='net' then
    v_amount:=greatest(o.total-coalesce((select sum(r.credit_amount) from charm.sales_returns r where r.order_id=o.id and r.status='credited'),0),0);
  elsif v_basis='paid' then
    v_amount:=coalesce((select sum(p.amount) from charm.payments p where p.order_id=o.id and p.status='verified'),0);
  elsif v_basis='delivered' then
    v_amount:=case when o.receipt_status='received' then o.total else 0 end;
  else
    v_amount:=o.total;
  end if;
  v_amount:=greatest(coalesce(v_amount,0),0);
  if v_method='fixed' then
    update charm.commission_entries set
      basis_amount=v_amount,rate=null,
      commission_amount=case when v_amount>0 then coalesce(v_fixed,0) else 0 end,updated_at=now()
      where id=e.id;
  elsif v_method='tiered' then
    select (t->>'rate')::numeric into v_tier_rate
      from jsonb_array_elements(coalesce(e.snapshot->'tiers','[]'::jsonb)) t
      where v_amount>=coalesce((t->>'min')::numeric,(t->>'min_amount')::numeric,0)
        and ((t->>'max') is null or (t->>'max')='' or v_amount<(t->>'max')::numeric)
      order by coalesce((t->>'min')::numeric,(t->>'min_amount')::numeric,0) desc limit 1;
    v_tier_rate:=coalesce(v_tier_rate,0);
    update charm.commission_entries set
      basis_amount=v_amount,rate=v_tier_rate,commission_amount=round(v_amount*v_tier_rate/100,2),updated_at=now()
      where id=e.id;
  else
    v_rate:=coalesce(v_rate,0);
    update charm.commission_entries set
      basis_amount=v_amount,rate=v_rate,commission_amount=round(v_amount*v_rate/100,2),updated_at=now()
      where id=e.id;
  end if;
end $$;

create or replace function charm.commission_on_order() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  e charm.commission_entries;
  r charm.commission_rules;
  v_day date;
  v_basis numeric:=0;
  v_rate numeric;
  v_tiers jsonb:='[]'::jsonb;
  v_amount numeric:=0;
  v_entry bigint;
begin
  if new.status<>'confirmed' or new.confirmed_at is null then
    perform charm.refresh_commission(new.id);
    return new;
  end if;
  select * into e from charm.commission_entries where order_id=new.id;
  if found then
    perform charm.refresh_commission(new.id);
    return new;
  end if;
  v_day:=(new.confirmed_at at time zone 'Africa/Nairobi')::date;
  select * into r from charm.commission_rules
    where active and effective_from<=v_day and (effective_to is null or effective_to>=v_day)
    order by effective_from desc,id desc limit 1;
  if not found then return new; end if;
  if r.basis='net' then
    v_basis:=greatest(new.total-coalesce((select sum(s.credit_amount) from charm.sales_returns s where s.order_id=new.id and s.status='credited'),0),0);
  elsif r.basis='paid' then
    v_basis:=coalesce((select sum(p.amount) from charm.payments p where p.order_id=new.id and p.status='verified'),0);
  elsif r.basis='delivered' then
    v_basis:=case when new.receipt_status='received' then new.total else 0 end;
  else
    v_basis:=new.total;
  end if;
  v_basis:=greatest(coalesce(v_basis,0),0);
  if r.method='fixed' then
    v_amount:=case when v_basis>0 then coalesce(r.fixed_amount,0) else 0 end;
  elsif r.method='tiered' then
    select coalesce(jsonb_agg(jsonb_build_object('min',t.min_amount,'max',t.max_amount,'rate',t.rate) order by t.min_amount),'[]'::jsonb)
      into v_tiers from charm.commission_tiers t where t.rule_id=r.id;
    select t.rate into v_rate from charm.commission_tiers t
      where t.rule_id=r.id and v_basis>=t.min_amount and (t.max_amount is null or v_basis<t.max_amount)
      order by t.min_amount desc limit 1;
    v_rate:=coalesce(v_rate,0);
    v_amount:=round(v_basis*v_rate/100,2);
  else
    v_rate:=coalesce(r.rate,0);
    v_amount:=round(v_basis*v_rate/100,2);
  end if;
  insert into charm.commission_entries(order_id,salesperson_id,rule_id,basis,basis_amount,rate,commission_amount,status,period_start,snapshot,computed_at,updated_at)
    values(new.id,new.salesperson_id,r.id,r.basis,v_basis,v_rate,v_amount,'earned',date_trunc('month',v_day)::date,
      jsonb_build_object('rule',to_jsonb(r),'tiers',v_tiers),now(),now())
    returning id into v_entry;
  insert into charm.finance_notifications(recipient_id,event,event_key,entity,entity_id)
    values(new.salesperson_id,'commissionEarned','commission-earned:'||new.id,'commission_entries',v_entry)
    on conflict do nothing;
  return new;
end $$;
drop trigger if exists commission_confirmed_order on charm.orders;
create trigger commission_confirmed_order after insert or update of status,confirmed_at,total on charm.orders
for each row execute function charm.commission_on_order();

create or replace function charm.commission_payment_sync() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  perform charm.refresh_commission(new.order_id);
  return new;
end $$;
drop trigger if exists commission_payment_sync on charm.payments;
create trigger commission_payment_sync after insert or update of status,amount on charm.payments
for each row execute function charm.commission_payment_sync();

create or replace function charm.commission_return_sync() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  perform charm.refresh_commission(new.order_id);
  return new;
end $$;
drop trigger if exists commission_return_sync on charm.sales_returns;
create trigger commission_return_sync after insert or update of status,credit_amount on charm.sales_returns
for each row execute function charm.commission_return_sync();

create or replace function charm.save_commission_rule(
  p_key uuid,p_id bigint,p_name text,p_basis text,p_method text,p_rate numeric,p_fixed numeric,
  p_from date,p_to date,p_active boolean,p_tiers jsonb default '[]'::jsonb,p_notes text default ''
) returns bigint language plpgsql security definer set search_path='' as $$
declare
  a bigint:=charm.require_admin();
  v_id bigint;
  previous_id bigint;
  tier jsonb;
  v_min numeric;
  v_max numeric;
  v_tier_rate numeric;
  v_count integer:=0;
begin
  if coalesce(length(trim(p_name)),0) not between 1 and 120 then raise exception 'invalid'; end if;
  if p_basis not in ('gross','net','paid','delivered') or p_method not in ('percentage','fixed','tiered') then raise exception 'invalid'; end if;
  if p_from is null or (p_to is not null and p_to<p_from) then raise exception 'invalid'; end if;
  if p_method='percentage' and (p_rate is null or p_rate<0 or p_rate>100) then raise exception 'invalid'; end if;
  if p_method='fixed' and (p_fixed is null or p_fixed<=0) then raise exception 'invalid'; end if;
  if p_method='tiered' then
    if p_tiers is null or jsonb_typeof(p_tiers)<>'array' or jsonb_array_length(p_tiers)=0 then raise exception 'tiersRequired'; end if;
    for tier in select * from jsonb_array_elements(p_tiers) loop
      v_min:=coalesce((tier->>'min')::numeric,(tier->>'min_amount')::numeric);
      v_max:=nullif(coalesce(tier->>'max',tier->>'max_amount'),'')::numeric;
      v_tier_rate:=(tier->>'rate')::numeric;
      if v_min is null or v_min<0 or v_tier_rate is null or v_tier_rate<0 or v_tier_rate>100 or (v_max is not null and v_max<=v_min) then raise exception 'invalidTier'; end if;
      v_count:=v_count+1;
    end loop;
    if not exists(select 1 from jsonb_array_elements(p_tiers) t where coalesce((t->>'min')::numeric,(t->>'min_amount')::numeric)=0) then raise exception 'firstTierRequired'; end if;
  end if;
  if p_id is null then
    if p_key is null then raise exception 'invalid'; end if;
    previous_id:=charm.claim(p_key,'commission_rule',
      jsonb_build_object('name',trim(p_name),'basis',p_basis,'method',p_method,'rate',p_rate,
        'fixed',p_fixed,'from',p_from,'to',p_to,'active',p_active,'tiers',p_tiers,'notes',trim(p_notes)));
    if previous_id is not null then return previous_id; end if;
  end if;
  if p_active and exists(
    select 1 from charm.commission_rules r
    where r.active and r.basis=p_basis and r.id<>coalesce(p_id,0)
      and r.effective_from<=coalesce(p_to,'infinity'::date)
      and (r.effective_to is null or r.effective_to>=p_from)
  ) then raise exception 'overlappingRule'; end if;
  if p_id is null then
    insert into charm.commission_rules(name,basis,method,rate,fixed_amount,effective_from,effective_to,active,notes,created_by)
      values(trim(p_name),p_basis,p_method,case when p_method='percentage' then p_rate end,case when p_method='fixed' then p_fixed end,p_from,p_to,p_active,nullif(trim(p_notes),''),a)
      returning id into v_id;
  else
    update charm.commission_rules set
      name=trim(p_name),basis=p_basis,method=p_method,
      rate=case when p_method='percentage' then p_rate end,
      fixed_amount=case when p_method='fixed' then p_fixed end,
      effective_from=p_from,effective_to=p_to,active=p_active,notes=nullif(trim(p_notes),''),updated_at=now()
      where id=p_id returning id into v_id;
    if not found then raise exception 'notFound'; end if;
    delete from charm.commission_tiers where rule_id=v_id;
  end if;
  if p_method='tiered' then
    for tier in select * from jsonb_array_elements(p_tiers) loop
      insert into charm.commission_tiers(rule_id,min_amount,max_amount,rate)
        values(v_id,coalesce((tier->>'min')::numeric,(tier->>'min_amount')::numeric),
          nullif(coalesce(tier->>'max',tier->>'max_amount'),'')::numeric,(tier->>'rate')::numeric);
    end loop;
  end if;
  perform charm.audit(case when p_id is null then 'commissionRuleCreated' else 'commissionRuleUpdated' end,
    'commission_rules',v_id,jsonb_build_object('name',trim(p_name),'basis',p_basis,'method',p_method,
      'rate',p_rate,'fixed',p_fixed,'from',p_from,'to',p_to,'active',p_active,'tiers',v_count));
  if p_id is null then perform charm.finish(p_key,v_id); end if;
  return v_id;
end $$;

create or replace function charm.commission_decide(p_entry bigint,p_status text,p_amount numeric default null,p_reason text default '')
returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); e charm.commission_entries;
begin
  if p_status not in ('approved','paid','reversed','adjusted') then raise exception 'invalid'; end if;
  if p_status in ('reversed','adjusted') and coalesce(length(trim(p_reason)),0)<3 then raise exception 'reasonRequired'; end if;
  select * into e from charm.commission_entries where id=p_entry for update;
  if not found then raise exception 'notFound'; end if;
  if p_status='adjusted' and (p_amount is null or p_amount<0) then raise exception 'invalid'; end if;
  update charm.commission_entries set
    status=p_status,
    commission_amount=case when p_status='adjusted' then p_amount when p_status='reversed' then 0 else commission_amount end,
    updated_at=now()
    where id=p_entry;
  perform charm.audit('commission'||initcap(p_status),'commission_entries',p_entry,
    jsonb_build_object('from',e.status,'to',p_status,'amount',p_amount,'reason',nullif(trim(p_reason),'')));
  if p_status in ('approved','paid','reversed') then
    insert into charm.finance_notifications(recipient_id,event,event_key,entity,entity_id)
      values(e.salesperson_id,'commission'||initcap(p_status),'commission-'||p_status||':'||p_entry,'commission_entries',p_entry)
      on conflict do nothing;
  end if;
end $$;

create or replace function charm.commission_summary(p_from date,p_to date,p_user bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  a bigint:=charm.require_actor();
  v_from date:=date_trunc('month',coalesce(p_from,(now() at time zone 'Africa/Nairobi')::date))::date;
  v_to date:=coalesce(p_to,(now() at time zone 'Africa/Nairobi')::date);
  v_rows jsonb;
  v_totals jsonb;
  v_staff jsonb;
begin
  if v_to<v_from or (v_to-v_from)>730 then raise exception 'invalidRange'; end if;
  if not charm.is_admin() then
    if p_user is not null and p_user<>a then raise exception 'forbidden'; end if;
    p_user:=a;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',e.id,'order_id',e.order_id,'salesperson_id',e.salesperson_id,'staff_code',u.staff_code,
    'name',u.name,'client',c.name,'basis',e.basis,'basis_amount',e.basis_amount,'rate',e.rate,
    'commission',e.commission_amount,'status',e.status,'period_start',e.period_start,
    'rule',r.name,'order_total',o.total,'confirmed_at',o.confirmed_at
  ) order by e.period_start desc,e.id desc),'[]'::jsonb)
  into v_rows
  from charm.commission_entries e
  join charm.users u on u.id=e.salesperson_id
  left join charm.orders o on o.id=e.order_id
  left join charm.clients c on c.id=o.client_id
  left join charm.commission_rules r on r.id=e.rule_id
  where e.period_start>=v_from and e.period_start<=date_trunc('month',v_to)::date
    and (p_user is null or e.salesperson_id=p_user);
  select jsonb_build_object(
    'earned',coalesce(sum(e.commission_amount) filter(where e.status in ('earned','approved','paid','adjusted')),0),
    'pending',coalesce(sum(e.commission_amount) filter(where e.status='earned'),0),
    'approved',coalesce(sum(e.commission_amount) filter(where e.status='approved'),0),
    'paid',coalesce(sum(e.commission_amount) filter(where e.status='paid'),0),
    'reversed',coalesce(sum(e.commission_amount) filter(where e.status='reversed'),0),
    'entries',count(*)::integer
  ) into v_totals
  from charm.commission_entries e
  where e.period_start>=v_from and e.period_start<=date_trunc('month',v_to)::date
    and (p_user is null or e.salesperson_id=p_user);
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
      coalesce(sum(e.commission_amount) filter(where e.status='paid'),0) paid,
      count(*)::integer entries
    from charm.commission_entries e join charm.users u on u.id=e.salesperson_id
    where e.period_start>=v_from and e.period_start<=date_trunc('month',v_to)::date
      and (p_user is null or e.salesperson_id=p_user)
    group by e.salesperson_id,u.staff_code,u.name
  ) s;
  return jsonb_build_object('from',v_from,'to',v_to,'rows',v_rows,'totals',v_totals,'staff',v_staff);
end $$;

-- 6. RLS, grants and private leave documents.
do $$ declare t text; begin
  foreach t in array array['client_assignments','attendance_policy','attendance_days','leave_types','leave_requests','commission_rules','commission_tiers','commission_entries'] loop
    execute format('alter table charm.%I enable row level security',t);
    execute format('revoke all on charm.%I from public,anon,authenticated',t);
    execute format('grant select on charm.%I to authenticated',t);
  end loop;
end $$;
create policy client_assignment_read on charm.client_assignments for select to authenticated
  using(charm.is_admin() or exists(select 1 from charm.clients c where c.id=client_id and c.salesperson_id=charm.actor()));
create policy attendance_policy_read on charm.attendance_policy for select to authenticated using(charm.actor() is not null);
create policy attendance_day_read on charm.attendance_days for select to authenticated
  using(charm.is_admin() or salesperson_id=charm.actor());
create policy leave_type_read on charm.leave_types for select to authenticated using(charm.actor() is not null);
create policy leave_request_read on charm.leave_requests for select to authenticated
  using(charm.is_admin() or salesperson_id=charm.actor());
create policy commission_rule_read on charm.commission_rules for select to authenticated using(charm.actor() is not null);
create policy commission_tier_read on charm.commission_tiers for select to authenticated using(charm.actor() is not null);
create policy commission_entry_read on charm.commission_entries for select to authenticated
  using(charm.is_admin() or salesperson_id=charm.actor());

revoke execute on function charm.assign_staff_code(),charm.record_client_assignment(),
  charm.assign_client(uuid,bigint,bigint,text),
  charm.set_client_lifecycle(bigint,text,text),charm.business_days_between(date,date),
  charm.refresh_attendance_day(bigint,date),charm.attendance_from_visit(),charm.save_attendance_policy(numeric,numeric,time,time,integer,jsonb),
  charm.correct_attendance(bigint,date,text,text,text),charm.attendance_report(date,date,bigint),
  charm.save_leave_request(uuid,bigint,bigint,date,date,text,text,bigint),charm.submit_leave_request(bigint),
  charm.cancel_leave_request(bigint),charm.decide_leave_request(bigint,text,text),charm.leave_balances(integer,bigint),
  charm.refresh_commission(bigint),charm.commission_on_order(),charm.commission_payment_sync(),charm.commission_return_sync(),
  charm.save_commission_rule(uuid,bigint,text,text,text,numeric,numeric,date,date,boolean,jsonb,text),
  charm.commission_decide(bigint,text,numeric,text),charm.commission_summary(date,date,bigint)
  from public,anon,authenticated;
grant execute on function charm.assign_client(uuid,bigint,bigint,text),charm.set_client_lifecycle(bigint,text,text),
  charm.save_attendance_policy(numeric,numeric,time,time,integer,jsonb),charm.correct_attendance(bigint,date,text,text,text),
  charm.attendance_report(date,date,bigint),charm.save_leave_request(uuid,bigint,bigint,date,date,text,text,bigint),
  charm.submit_leave_request(bigint),charm.cancel_leave_request(bigint),charm.decide_leave_request(bigint,text,text),
  charm.leave_balances(integer,bigint),charm.save_commission_rule(uuid,bigint,text,text,text,numeric,numeric,date,date,boolean,jsonb,text),
  charm.commission_decide(bigint,text,numeric,text),charm.commission_summary(date,date,bigint)
  to authenticated;

create or replace function charm.file_access(path text,writing boolean default false) returns boolean
language plpgsql stable security definer set search_path='' as $$
declare kind text:=split_part(path,'/',1); record_id bigint; owner bigint; status text;
begin
  if charm.actor() is null or split_part(path,'/',2) !~ '^\d+$' then return false; end if;
  record_id:=split_part(path,'/',2)::bigint;
  if kind='visits' then select salesperson_id into owner from charm.visits where visits.id=record_id;
  elsif kind='payments' then select o.salesperson_id,p.status into owner,status from charm.payments p join charm.orders o on o.id=p.order_id where p.id=record_id;
  elsif kind='leave' then
    owner:=record_id;
    if writing and owner<>charm.actor() and not charm.is_admin() then return false; end if;
    return owner=charm.actor() or charm.is_admin();
  else return false; end if;
  if writing and kind='payments' and status<>'pending' then return false; end if;
  return owner is not null and coalesce(charm.can_access(owner),false);
end $$;
update storage.buckets set file_size_limit=20971520,
  allowed_mime_types=array['image/jpeg','image/png','image/webp','application/pdf']
  where id='charm-private';
commit;
notify pgrst,'reload schema';

-- Reviewed finance install/upgrade after baseline 001-009.
-- Handles partial installations; preserves financial records and IDs.
-- Review and test in staging before applying to production.
begin;
drop function if exists charm.finance_submit_accountability(uuid,bigint,text,text,text,bigint,text,bigint);

-- 202610130010_finance_schema.sql
-- Additive finance foundation. Review/apply after 009. No financial records are deleted.

do $$ declare c record; begin
 for c in select conname from pg_constraint where conrelid='charm.users'::regclass and contype='c' and pg_get_constraintdef(oid) like '%role%' loop
  execute format('alter table charm.users drop constraint %I',c.conname);
 end loop;
end $$;
alter table charm.users add constraint users_finance_roles check(role in ('salesperson','admin','finance_officer','finance_manager','management','auditor'));
create or replace function charm.finance_role() returns text language sql stable security definer set search_path='' as $$select role::text from charm.users where id=charm.actor()$$;
create or replace function charm.finance_reader() returns boolean language sql stable security definer set search_path='' as $$select coalesce(charm.finance_role() in ('admin','finance_officer','finance_manager','management','auditor'),false)$$;
create or replace function charm.finance_operator() returns boolean language sql stable security definer set search_path='' as $$select coalesce(charm.finance_role() in ('finance_officer','finance_manager'),false)$$;
create or replace function charm.require_finance(p_manager boolean default false) returns bigint language plpgsql stable security definer set search_path='' as $$begin
 if not charm.finance_operator() or (p_manager and charm.finance_role()<>'finance_manager') then raise exception 'forbidden'; end if; return charm.require_actor(); end$$;

create table if not exists charm.finance_categories(id bigserial primary key,name text unique not null check(length(name) between 1 and 120),active boolean not null default true);
-- Configuration labels, never sample transactions or balances.
insert into charm.finance_categories(name) values('Travel'),('Accommodation'),('Meals'),('Marketing'),('Office'),('Suppliers'),('Other') on conflict(name) do nothing;
create table if not exists charm.finance_accounts(id bigserial primary key,name text unique not null,method text not null check(method in ('Cash','Bank','M-Pesa','Other')),active boolean not null default true);
create table if not exists charm.finance_payees(id bigserial primary key,staff_id bigint unique references charm.users(id),name text not null,details text not null,verified_by bigint not null references charm.users(id),verified_at timestamptz not null default now());
create table if not exists charm.finance_budgets(id bigserial primary key,category_id bigint not null references charm.finance_categories(id),month date not null check(extract(day from month)=1),amount numeric(14,2) not null check(amount>=0),updated_by bigint not null references charm.users(id),updated_at timestamptz not null default now(),unique(category_id,month));
create table if not exists charm.finance_requests(
 id bigserial primary key,owner_id bigint not null references charm.users(id),kind text not null check(kind in ('staff','supplier')),
 payee_id bigint references charm.finance_payees(id),category_id bigint not null references charm.finance_categories(id),
 amount numeric(14,2) not null check(amount>0),approved_amount numeric(14,2) check(approved_amount>0 and approved_amount<=amount),
 purpose text not null check(length(purpose) between 1 and 10000),required_date date not null,accountability_due date not null,
 status text not null default 'draft' check(status in ('draft','pending','returned','rejected','approved','part_paid','paid','closed')),
 reason text,approved_by bigint references charm.users(id),approved_at timestamptz,budget_id bigint references charm.finance_budgets(id),
 source_expense_id bigint unique references charm.expenses(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists charm.finance_documents(id bigserial primary key,request_id bigint not null references charm.finance_requests(id),kind text not null check(kind in ('support','payment','receipt','refund')),path text unique not null,uploaded_by bigint not null references charm.users(id),created_at timestamptz not null default now());
create table if not exists charm.finance_disbursements(id bigserial primary key,request_id bigint not null references charm.finance_requests(id),account_id bigint not null references charm.finance_accounts(id),amount numeric(14,2) not null check(amount>0),reference text not null,paid_at timestamptz not null,payee_snapshot jsonb not null,proof_id bigint not null unique references charm.finance_documents(id),recorded_by bigint not null references charm.users(id),created_at timestamptz not null default now(),unique(account_id,reference));
create table if not exists charm.finance_accountability(id bigserial primary key,request_id bigint not null references charm.finance_requests(id),kind text not null check(kind in ('expense','refund')),amount numeric(14,2) not null check(amount>0),description text not null,expense_date date not null default ((now() at time zone 'Africa/Nairobi')::date),reference text,account_id bigint references charm.finance_accounts(id),proof_id bigint not null unique references charm.finance_documents(id),status text not null default 'pending' check(status in ('pending','accepted','returned')),submitted_by bigint not null references charm.users(id),reviewed_by bigint references charm.users(id),reason text,created_at timestamptz not null default now(),reviewed_at timestamptz);
create unique index if not exists finance_refund_reference on charm.finance_accountability(account_id,reference) where kind='refund' and status='accepted';
-- Append-only cash movements. Staff spending is recognized only after accountability review.
create table if not exists charm.finance_ledger(id bigserial primary key,request_id bigint references charm.finance_requests(id),account_id bigint references charm.finance_accounts(id),direction text not null check(direction in ('in','out')),amount numeric(14,2) not null check(amount>0),kind text not null check(kind in ('advance','supplier','refund','customer_receipt','opening')),reference text not null,occurred_at timestamptz not null,recorded_by bigint not null references charm.users(id),disbursement_id bigint unique references charm.finance_disbursements(id),accountability_id bigint unique references charm.finance_accountability(id),customer_payment_id bigint unique references charm.payments(id),created_at timestamptz not null default now());
create table if not exists charm.finance_receipt_allocations(payment_id bigint primary key references charm.payments(id),ledger_id bigint unique not null references charm.finance_ledger(id),account_id bigint not null references charm.finance_accounts(id),reference text not null,confirmed_by bigint not null references charm.users(id),confirmed_at timestamptz not null default now(),unique(account_id,reference));
create table if not exists charm.finance_statement_lines(id bigserial primary key,account_id bigint not null references charm.finance_accounts(id),reference text not null,direction text not null check(direction in ('in','out')),amount numeric(14,2) not null check(amount>0),occurred_at date not null,ledger_id bigint unique references charm.finance_ledger(id),imported_by bigint not null references charm.users(id),matched_by bigint references charm.users(id),matched_at timestamptz,unique(account_id,reference,direction));
create table if not exists charm.finance_notifications(id bigserial primary key,recipient_id bigint not null references charm.users(id),request_id bigint references charm.finance_requests(id),event text not null,event_key text not null,read_at timestamptz,created_at timestamptz not null default now(),unique(recipient_id,event_key));
create index if not exists finance_requests_owner on charm.finance_requests(owner_id,id desc);
create index if not exists finance_requests_queue on charm.finance_requests(status,required_date);
create index if not exists finance_ledger_date on charm.finance_ledger(occurred_at,id);
create index if not exists finance_disbursements_request on charm.finance_disbursements(request_id);
create index if not exists finance_accountability_request on charm.finance_accountability(request_id,status);
create index if not exists finance_notifications_recipient on charm.finance_notifications(recipient_id,id desc);
create or replace function charm.finance_access(p_id bigint) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from charm.finance_requests where id=p_id and (owner_id=charm.actor() or (charm.finance_reader() and (charm.finance_role()<>'finance_officer' or status in ('approved','part_paid','paid','closed')))))$$;
do $$ declare t text; begin
 foreach t in array array['finance_categories','finance_accounts','finance_payees','finance_budgets','finance_requests','finance_documents','finance_disbursements','finance_accountability','finance_ledger','finance_receipt_allocations','finance_statement_lines','finance_notifications'] loop
  execute format('alter table charm.%I enable row level security',t);
  execute format('revoke all on charm.%I from public,anon,authenticated',t);
  execute format('grant select on charm.%I to authenticated',t);
 end loop;
end $$;
drop policy if exists finance_category_read on charm.finance_categories;
create policy finance_category_read on charm.finance_categories for select to authenticated using(charm.actor() is not null);
drop policy if exists finance_account_read on charm.finance_accounts;
create policy finance_account_read on charm.finance_accounts for select to authenticated using(charm.actor() is not null);
drop policy if exists finance_payee_read on charm.finance_payees;
create policy finance_payee_read on charm.finance_payees for select to authenticated using(staff_id=charm.actor() or charm.finance_reader());
drop policy if exists finance_budget_read on charm.finance_budgets;
create policy finance_budget_read on charm.finance_budgets for select to authenticated using(charm.finance_reader());
drop policy if exists finance_request_read on charm.finance_requests;
create policy finance_request_read on charm.finance_requests for select to authenticated using(charm.finance_access(id));
drop policy if exists finance_document_read on charm.finance_documents;
create policy finance_document_read on charm.finance_documents for select to authenticated using(charm.finance_access(request_id));
drop policy if exists finance_disbursement_read on charm.finance_disbursements;
create policy finance_disbursement_read on charm.finance_disbursements for select to authenticated using(charm.finance_access(request_id));
drop policy if exists finance_accountability_read on charm.finance_accountability;
create policy finance_accountability_read on charm.finance_accountability for select to authenticated using(charm.finance_access(request_id));
drop policy if exists finance_ledger_read on charm.finance_ledger;
create policy finance_ledger_read on charm.finance_ledger for select to authenticated using(charm.finance_reader() or (request_id is not null and charm.finance_access(request_id)));
drop policy if exists finance_allocation_read on charm.finance_receipt_allocations;
create policy finance_allocation_read on charm.finance_receipt_allocations for select to authenticated using(charm.finance_reader());
drop policy if exists finance_statement_read on charm.finance_statement_lines;
create policy finance_statement_read on charm.finance_statement_lines for select to authenticated using(charm.finance_reader());
drop policy if exists finance_notification_read on charm.finance_notifications;
create policy finance_notification_read on charm.finance_notifications for select to authenticated using(recipient_id=charm.actor());
-- Finance can read customer collections but receives no direct write privileges.
drop policy if exists finance_user_read on charm.users;
create policy finance_user_read on charm.users for select to authenticated using(charm.finance_reader());
drop policy if exists finance_client_read on charm.clients;
create policy finance_client_read on charm.clients for select to authenticated using(charm.finance_reader());
drop policy if exists finance_order_read on charm.orders;
create policy finance_order_read on charm.orders for select to authenticated using(charm.finance_reader());
drop policy if exists finance_payment_read on charm.payments;
create policy finance_payment_read on charm.payments for select to authenticated using(charm.finance_reader());
drop policy if exists finance_audit_read on charm.audit_logs;
create policy finance_audit_read on charm.audit_logs for select to authenticated using(charm.finance_role() in ('finance_manager','management','auditor') and (entity like 'finance_%' or entity='payments'));
create or replace function charm.finance_notify(p_request bigint,p_event text,p_key text,p_roles text[] default '{}',p_owner boolean default true) returns void language sql security definer set search_path='' as $$
 insert into charm.finance_notifications(recipient_id,request_id,event,event_key)
 select u.id,p_request,p_event,p_key from charm.users u where u.active and (u.role=any(p_roles) or (p_owner and u.id=(select owner_id from charm.finance_requests where id=p_request))) on conflict do nothing
$$;
-- Fresh role check on every write; role changes serialize with staff management.
create or replace function charm.finance_lock_actor() returns bigint language plpgsql security definer set search_path='' as $$declare a bigint:=charm.require_actor();begin
 perform pg_advisory_xact_lock(817201008);perform 1 from charm.users where id=a for update;
 if charm.actor() is null then raise exception 'unauthorized'; end if;return a;end$$;
revoke execute on function charm.finance_role(),charm.finance_reader(),charm.finance_operator(),charm.require_finance(boolean),charm.finance_access(bigint),charm.finance_notify(bigint,text,text,text[],boolean),charm.finance_lock_actor() from public,anon,authenticated;
grant execute on function charm.finance_role(),charm.finance_reader(),charm.finance_operator(),charm.finance_access(bigint) to authenticated;

-- 202610130011_finance_api.sql

alter table charm.finance_accountability add column if not exists expense_date date not null default ((now() at time zone 'Africa/Nairobi')::date);
create or replace function charm.finance_money(p_value text) returns numeric language plpgsql immutable set search_path='' as $$begin
 if p_value is null or p_value !~ '^\d{1,10}(\.\d{1,2})?$' or p_value::numeric<=0 then raise exception 'invalidMoney';end if;return p_value::numeric;end$$;
create or replace function charm.finance_budget_committed(p_id bigint) returns numeric language sql stable security definer set search_path='' as $$
 select coalesce(sum(case when r.status='closed' then case when r.kind='staff' then (select coalesce(sum(amount),0) from charm.finance_accountability where request_id=r.id and kind='expense' and status='accepted') else (select coalesce(sum(amount),0) from charm.finance_disbursements where request_id=r.id) end else r.approved_amount end),0)
 from charm.finance_requests r where r.budget_id=p_id and r.status in ('approved','part_paid','paid','closed')
$$;
revoke execute on function charm.finance_budget_committed(bigint) from public,anon,authenticated;
create or replace function charm.finance_save_request(p_key uuid,p_id bigint,p_category bigint,p_amount text,p_purpose text,p_date date,p_due date,p_payee bigint default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;old bigint;v numeric:=charm.finance_money(p_amount);request_kind text;
begin
 if charm.finance_role() not in ('salesperson','admin','finance_officer','finance_manager') then raise exception 'forbidden';end if;
 old:=charm.claim(p_key,'finance_save_request',jsonb_build_array(p_id,p_category,p_amount,p_purpose,p_date,p_due,p_payee));if old is not null then return old;end if;
 if not exists(select 1 from charm.finance_categories where id=p_category and active) or coalesce(length(trim(p_purpose)),0) not between 1 and 10000 or p_date is null or p_due is null or p_date<(now() at time zone 'Africa/Nairobi')::date or p_due<p_date then raise exception 'invalid';end if;
 request_kind:=case when p_payee is null then 'staff' else 'supplier' end;
 if request_kind='staff' and charm.finance_role() not in ('salesperson','admin') then raise exception 'forbidden';end if;
 if request_kind='supplier' and (not charm.finance_operator() or not exists(select 1 from charm.finance_payees where id=p_payee and staff_id is null)) then raise exception 'forbidden';end if;
 if p_id is null then
  insert into charm.finance_requests(owner_id,kind,payee_id,category_id,amount,purpose,required_date,accountability_due) values(a,request_kind,p_payee,p_category,v,trim(p_purpose),p_date,p_due) returning * into r;
 else
  select * into r from charm.finance_requests where id=p_id for update;
  if r.owner_id is distinct from a or r.status not in ('draft','returned')  then raise exception 'financeLocked';end if;
  update charm.finance_requests set category_id=p_category,amount=v,purpose=trim(p_purpose),required_date=p_date,accountability_due=p_due,kind=request_kind,payee_id=p_payee,updated_at=now() where id=p_id;
 end if;
 perform charm.audit('financeDraft','finance_requests',r.id,jsonb_build_object('before',case when p_id is null then null else to_jsonb(r) end,'amount',v,'purpose',p_purpose,'category_id',p_category,'required_date',p_date,'accountability_due',p_due,'payee_id',p_payee));return charm.finish(p_key,r.id);
end$$;
create or replace function charm.finance_submit_request(p_id bigint) returns void language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;begin
 select * into r from charm.finance_requests where id=p_id for update;
 if r.owner_id is distinct from a or charm.finance_role() in ('management','auditor') then raise exception 'forbidden';end if;
 if r.status='pending' then return;end if;
 if r.status not in ('draft','returned') then raise exception 'financeLocked';end if;
 update charm.finance_requests set status='pending',reason=null,updated_at=now() where id=p_id;
 perform charm.audit('financeSubmitted','finance_requests',p_id);
 perform charm.finance_notify(p_id,'financeSubmitted','submitted:'||p_id||':'||now(),case when r.kind='supplier' then array['finance_manager'] else array['admin'] end);
end$$;
create or replace function charm.finance_review_request(p_id bigint,p_decision text,p_reason text,p_amount text default null) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;b charm.finance_budgets;v numeric;used numeric;begin
 select * into r from charm.finance_requests where id=p_id for update;
 if r.id is null then raise exception 'notFound';end if;
 if (r.kind='staff' and not charm.is_admin()) or (r.kind='supplier' and charm.finance_role()<>'finance_manager') then raise exception 'forbidden';end if;
 if r.owner_id=a then raise exception 'selfApproval';end if;
 if r.status<>'pending' or p_decision is null or p_decision not in ('approved','returned','rejected') then raise exception 'financeLocked';end if;
 if p_decision<>'approved' and coalesce(length(trim(p_reason)),0) not between 1 and 2000 then raise exception 'reasonRequired';end if;
 if p_decision='approved' then
  v:=charm.finance_money(p_amount);if v>r.amount then raise exception 'overpayment';end if;
  select * into b from charm.finance_budgets where category_id=r.category_id and month=date_trunc('month',r.required_date)::date for update;
  if b.id is null then raise exception 'budgetMissing';end if;
  used:=charm.finance_budget_committed(b.id);
  if used+v>b.amount then raise exception 'budgetExceeded';end if;
 end if;
 update charm.finance_requests set status=p_decision,reason=nullif(trim(p_reason),''),approved_amount=v,approved_by=a,approved_at=now(),budget_id=b.id,updated_at=now() where id=p_id;
 if r.source_expense_id is not null and p_decision in ('approved','rejected') then
  update charm.expenses set status=p_decision,reviewed_by=a,reviewed_at=now(),updated_at=now() where id=r.source_expense_id and status='pending';
 end if;
 perform charm.audit('financeDecision','finance_requests',p_id,jsonb_build_object('decision',p_decision,'reason',p_reason,'approved_amount',v,'before_status',r.status));
 perform charm.finance_notify(p_id,p_decision,'decision:'||p_id||':'||now(),case when p_decision='approved' then array['finance_officer','finance_manager'] else '{}'::text[] end);
end$$;
create or replace function charm.finance_disburse(p_key uuid,p_id bigint,p_account bigint,p_amount text,p_reference text,p_date timestamptz,p_proof bigint,p_confirmed boolean) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;payee charm.finance_payees;v numeric:=charm.finance_money(p_amount);paid numeric;outstanding numeric;old bigint;id bigint;balance numeric;
begin
 perform charm.require_finance();old:=charm.claim(p_key,'finance_disburse',jsonb_build_array(p_id,p_account,p_amount,p_reference,p_date,p_proof,p_confirmed));if old is not null then return old;end if;
 select * into r from charm.finance_requests where finance_requests.id=p_id for update;
 if r.status is null or r.status not in ('approved','part_paid') or r.approved_amount is null or r.approved_at is null or r.approved_by is null or r.approved_by=r.owner_id or r.budget_id is null then raise exception 'financeLocked';end if;
 if a=r.owner_id then raise exception 'selfApproval';end if;
 if p_confirmed is distinct from true or coalesce(length(trim(p_reference)),0) not between 1 and 200 or p_date is null or p_date>now() or p_date<date_trunc('minute',r.approved_at) then raise exception 'paymentConfirmationRequired';end if;
 if not exists(select 1 from charm.finance_accounts where finance_accounts.id=p_account and active) then raise exception 'invalid';end if;
 if not exists(select 1 from charm.finance_documents where finance_documents.id=p_proof and request_id=p_id and kind='payment' and uploaded_by=a) then raise exception 'proofRequired';end if;
 select * into payee from charm.finance_payees where (r.kind='staff' and staff_id=r.owner_id) or (r.kind='supplier' and finance_payees.id=r.payee_id);
 if payee.id is null then raise exception 'payeeMissing';end if;
 if r.kind='staff' and not exists(select 1 from charm.users where users.id=r.owner_id and active) then raise exception 'staffInactive';end if;
 select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=p_id;
 if paid+v>r.approved_amount then raise exception 'overpayment';end if;
 -- Block a new advance if another disbursed advance for this person remains unsettled.
 if r.kind='staff' then
  select coalesce(sum(d.paid-coalesce(e.settled,0)),0) into outstanding from charm.finance_requests x
  join lateral(select coalesce(sum(amount),0) paid from charm.finance_disbursements where request_id=x.id)d on true
  join lateral(select coalesce(sum(amount),0) settled from charm.finance_accountability where request_id=x.id and status='accepted')e on true
  where x.owner_id=r.owner_id and x.kind='staff' and x.id<>p_id and x.status<>'closed';
  if outstanding>0 then raise exception 'advanceOutstanding';end if;
 end if;
 perform 1 from charm.finance_accounts where finance_accounts.id=p_account for update;
 select coalesce(sum(case when direction='in' then amount else -amount end),0) into balance from charm.finance_cashbook where account_id=p_account;
 if balance<v then raise exception 'insufficientFunds';end if;
 insert into charm.finance_disbursements(request_id,account_id,amount,reference,paid_at,payee_snapshot,proof_id,recorded_by) values(p_id,p_account,v,trim(p_reference),p_date,to_jsonb(payee),p_proof,a) returning finance_disbursements.id into id;
 insert into charm.finance_ledger(request_id,account_id,direction,amount,kind,reference,occurred_at,recorded_by,disbursement_id) values(p_id,p_account,'out',v,case when r.kind='staff' then 'advance' else 'supplier' end,trim(p_reference),p_date,a,id);
 update charm.finance_requests set status=case when paid+v=approved_amount then 'paid' else 'part_paid' end,updated_at=now() where finance_requests.id=p_id;
 perform charm.audit('financeDisbursed','finance_requests',p_id,jsonb_build_object('disbursement_id',id,'amount',v,'account_id',p_account,'reference',trim(p_reference),'payee_id',payee.id,'proof_id',p_proof));
 perform charm.finance_notify(p_id,'financeDisbursed','disbursement:'||id,array['admin','finance_manager']);return charm.finish(p_key,id);
end$$;
create or replace function charm.finance_submit_accountability(p_key uuid,p_id bigint,p_kind text,p_amount text,p_description text,p_proof bigint,p_reference text default null,p_account bigint default null,p_date date default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;v numeric:=charm.finance_money(p_amount);old bigint;id bigint;paid numeric;claimed numeric;begin
 old:=charm.claim(p_key,'finance_accountability',jsonb_build_array(p_id,p_kind,p_amount,p_description,p_proof,p_reference,p_account,p_date));if old is not null then return old;end if;
 select * into r from charm.finance_requests where finance_requests.id=p_id for update;
 if charm.finance_role() in ('management','auditor') or r.owner_id is distinct from a or r.kind<>'staff' then raise exception 'forbidden';end if;
 if r.status not in ('part_paid','paid') then raise exception 'financeLocked';end if;
 if p_kind is null or p_kind not in ('expense','refund') or coalesce(length(trim(p_description)),0) not between 1 and 10000 then raise exception 'invalid';end if;
 if not exists(select 1 from charm.finance_documents where finance_documents.id=p_proof and request_id=p_id and kind=case when p_kind='expense' then 'receipt' else 'refund' end and uploaded_by=a) then raise exception 'proofRequired';end if;
 if p_date is not null and p_date>(now() at time zone 'Africa/Nairobi')::date then raise exception 'invalid';end if;
 if p_kind='refund' and (coalesce(length(trim(p_reference)),0) not between 1 and 200 or not exists(select 1 from charm.finance_accounts where finance_accounts.id=p_account and active)) then raise exception 'invalid';end if;
 select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=p_id;
 select coalesce(sum(amount),0) into claimed from charm.finance_accountability where request_id=p_id and status in ('pending','accepted');
 if claimed+v>paid then raise exception 'overpayment';end if;
 insert into charm.finance_accountability(request_id,kind,amount,description,expense_date,reference,account_id,proof_id,submitted_by) values(p_id,p_kind,v,trim(p_description),coalesce(p_date,(now() at time zone 'Africa/Nairobi')::date),case when p_kind='refund' then trim(p_reference) end,case when p_kind='refund' then p_account end,p_proof,a) returning finance_accountability.id into id;
 perform charm.audit('accountabilitySubmitted','finance_requests',p_id,jsonb_build_object('submission_id',id,'amount',v,'kind',p_kind));perform charm.finance_notify(p_id,'accountabilitySubmitted','accountability:'||id,array['finance_officer','finance_manager']);return charm.finish(p_key,id);
end$$;
create or replace function charm.finance_review_accountability(p_id bigint,p_accept boolean,p_reason text,p_confirmed boolean default false) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();s charm.finance_accountability;r charm.finance_requests;paid numeric;settled numeric;begin
 perform charm.require_finance();select * into s from charm.finance_accountability where id=p_id;
 if s.id is null then raise exception 'notFound';end if;
 select * into r from charm.finance_requests where id=s.request_id for update;select * into s from charm.finance_accountability where id=p_id for update;
 if s.submitted_by=a then raise exception 'selfApproval';end if;
 if s.status<>'pending' or r.status='closed' or p_accept is null then raise exception 'financeLocked';end if;
 if not p_accept and coalesce(length(trim(p_reason)),0) not between 1 and 2000 then raise exception 'reasonRequired';end if;
 if p_accept then
  select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=r.id;
  select coalesce(sum(amount),0) into settled from charm.finance_accountability where request_id=r.id and status='accepted';
  if settled+s.amount>paid then raise exception 'overpayment';end if;
  if s.kind='refund' and p_confirmed is distinct from true then raise exception 'paymentConfirmationRequired';end if;
 end if;
 update charm.finance_accountability set status=case when p_accept then 'accepted' else 'returned' end,reviewed_by=a,reviewed_at=now(),reason=nullif(trim(p_reason),'') where id=p_id;
 if p_accept and s.kind='refund' then insert into charm.finance_ledger(request_id,account_id,direction,amount,kind,reference,occurred_at,recorded_by,accountability_id) values(r.id,s.account_id,'in',s.amount,'refund',s.reference,(s.expense_date::timestamp at time zone 'Africa/Nairobi'),a,s.id);end if;
 perform charm.audit('accountabilityReviewed','finance_requests',r.id,jsonb_build_object('submission_id',p_id,'accepted',p_accept,'reason',p_reason,'refund_confirmed',p_confirmed));perform charm.finance_notify(r.id,case when p_accept then 'accountabilityAccepted' else 'accountabilityReturned' end,'accountability-review:'||s.id);
end$$;
create or replace function charm.finance_close_request(p_id bigint,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;paid numeric;settled numeric;begin
 perform charm.require_finance();select * into r from charm.finance_requests where id=p_id for update;
 if r.id is null or r.status not in ('approved','part_paid','paid') then raise exception 'financeLocked';end if;
 if a=r.owner_id then raise exception 'selfApproval';end if;
 if coalesce(length(trim(p_reason)),0) not between 1 and 2000 then raise exception 'reasonRequired';end if;
 select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=p_id;
 select coalesce(sum(amount),0) into settled from charm.finance_accountability where request_id=p_id and status='accepted';
 if (r.kind='staff' and paid<>settled) or exists(select 1 from charm.finance_accountability where request_id=p_id and status='pending') then raise exception 'advanceOutstanding';end if;
 update charm.finance_requests set status='closed',updated_at=now() where id=p_id;
 perform charm.audit('financeClosed','finance_requests',p_id,jsonb_build_object('reason',p_reason,'paid',paid,'settled',settled,'unpaid_approval',r.approved_amount-paid));perform charm.finance_notify(p_id,'financeClosed','closed:'||p_id,array['admin','finance_manager']);
end$$;
create or replace function charm.finance_mark_read(p_id bigint default null) returns void language plpgsql security definer set search_path='' as $$begin
 update charm.finance_notifications set read_at=coalesce(read_at,now()) where recipient_id=charm.require_actor() and (p_id is null or id=p_id);
end$$;
-- Existing expense IDs remain canonical. Financial approval is a distinct budget check,
-- never a claim that legacy approved expenses were paid.
create or replace function charm.finance_bridge_expense() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.budget>0 then
 insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,status,source_expense_id,created_at)
 values(new.salesperson_id,'staff',(select id from charm.finance_categories where name='Other'),new.budget,new.notes,new.date,new.date+7,case when new.status='rejected' then 'rejected' else 'pending' end,new.id,coalesce(new.created_at,now())) on conflict(source_expense_id) do nothing;
 end if;return new;end$$;
drop trigger if exists finance_expense_bridge on charm.expenses;
create trigger finance_expense_bridge after insert on charm.expenses for each row execute function charm.finance_bridge_expense();
insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,status,source_expense_id,created_at)
 select salesperson_id,'staff',(select id from charm.finance_categories where name='Other'),budget,notes,date,date+7,case when status='rejected' then 'rejected' else 'pending' end,id,coalesce(created_at,now()) from charm.expenses where budget>0 on conflict(source_expense_id) do nothing;
do $$ declare f record;begin
 for f in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='charm' and p.proname in ('finance_money','finance_save_request','finance_submit_request','finance_review_request','finance_disburse','finance_submit_accountability','finance_review_accountability','finance_close_request','finance_mark_read','finance_bridge_expense') loop
  execute format('revoke execute on function %s from public,anon,authenticated',f.signature);
  if f.proname not in ('finance_money','finance_bridge_expense') then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;end$$;

-- 202610130012_finance_tools.sql

create table if not exists charm.finance_receipt_allocations(payment_id bigint primary key references charm.payments(id),ledger_id bigint unique not null references charm.finance_ledger(id),account_id bigint not null references charm.finance_accounts(id),reference text not null,confirmed_by bigint not null references charm.users(id),confirmed_at timestamptz not null default now(),unique(account_id,reference));
alter table charm.finance_receipt_allocations enable row level security;
revoke all on charm.finance_receipt_allocations from public,anon,authenticated;
grant select on charm.finance_receipt_allocations to authenticated;
drop policy if exists finance_allocation_read on charm.finance_receipt_allocations;
drop policy if exists finance_allocation_read on charm.finance_receipt_allocations;
create policy finance_allocation_read on charm.finance_receipt_allocations for select to authenticated using(charm.finance_reader());
create unique index if not exists finance_one_opening on charm.finance_ledger(account_id) where kind='opening';
create or replace function charm.finance_configure(p_key uuid,p_kind text,p_data jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;id bigint;v numeric;used numeric;r record;previous jsonb;begin
 perform charm.require_finance(true);old:=charm.claim(p_key,'finance_configure',jsonb_build_array(p_kind,p_data));if old is not null then return old;end if;
 if p_kind='category' then
  if coalesce(length(trim(p_data->>'name')),0) not between 1 and 120 then raise exception 'invalid';end if;
  insert into charm.finance_categories(name) values(trim(p_data->>'name')) returning finance_categories.id into id;
 elsif p_kind='account' then
  if coalesce(length(trim(p_data->>'name')),0) not between 1 and 120 or coalesce(p_data->>'method','') not in ('Cash','Bank','M-Pesa','Other') then raise exception 'invalid';end if;
  insert into charm.finance_accounts(name,method) values(trim(p_data->>'name'),p_data->>'method') returning finance_accounts.id into id;
 elsif p_kind='opening' then
  v:=charm.finance_money(p_data->>'amount');
  if coalesce(p_data->>'confirmed','')<>'true' or coalesce(length(trim(p_data->>'reference')),0) not between 1 and 200 then raise exception 'paymentConfirmationRequired';end if;
  perform 1 from charm.finance_accounts where finance_accounts.id=(p_data->>'account_id')::bigint and active for update;if not found then raise exception 'invalid';end if;
  insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by) values((p_data->>'account_id')::bigint,'in',v,'opening',trim(p_data->>'reference'),now(),a) returning finance_ledger.id into id;
 elsif p_kind='payee' then
  if coalesce(length(trim(p_data->>'name')),0) not between 1 and 200 or coalesce(length(trim(p_data->>'details')),0) not between 1 and 2000 then raise exception 'invalid';end if;
  if p_data->>'staff_id' is not null and not exists(select 1 from charm.users where users.id=(p_data->>'staff_id')::bigint and active) then raise exception 'staffInactive';end if;
  select to_jsonb(p) into previous from charm.finance_payees p where staff_id=(p_data->>'staff_id')::bigint;
  insert into charm.finance_payees(staff_id,name,details,verified_by) values((p_data->>'staff_id')::bigint,trim(p_data->>'name'),trim(p_data->>'details'),a)
  on conflict(staff_id) do update set name=excluded.name,details=excluded.details,verified_by=a,verified_at=now() returning finance_payees.id into id;
 elsif p_kind='budget' then
  if coalesce(p_data->>'amount','') !~ '^\d{1,10}(\.\d{1,2})?$' then raise exception 'invalidMoney';end if;v:=(p_data->>'amount')::numeric;
  if (p_data->>'month')::date is null or extract(day from (p_data->>'month')::date)<>1 then raise exception 'invalid';end if;
  select * into r from charm.finance_budgets where category_id=(p_data->>'category_id')::bigint and month=(p_data->>'month')::date for update;
  previous:=to_jsonb(r);
  used:=charm.finance_budget_committed(r.id);
  if v<used then raise exception 'budgetExceeded';end if;
  insert into charm.finance_budgets(category_id,month,amount,updated_by) values((p_data->>'category_id')::bigint,(p_data->>'month')::date,v,a)
  on conflict(category_id,month) do update set amount=v,updated_by=a,updated_at=now() returning finance_budgets.id into id;
 else raise exception 'invalid';end if;
 perform charm.audit('financeConfigured','finance_'||p_kind,id,jsonb_build_object('before',previous,'after',p_data));return charm.finish(p_key,id);
end$$;
create or replace function charm.finance_statement(p_key uuid,p_account bigint,p_reference text,p_direction text,p_amount text,p_date date) returns bigint language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();old bigint;id bigint;v numeric:=charm.finance_money(p_amount);begin
 perform charm.require_finance();old:=charm.claim(p_key,'finance_statement',jsonb_build_array(p_account,p_reference,p_direction,p_amount,p_date));if old is not null then return old;end if;
 if coalesce(length(trim(p_reference)),0) not between 1 and 200 or p_direction is null or p_direction not in ('in','out') or p_date is null or p_date>(now() at time zone 'Africa/Nairobi')::date then raise exception 'invalid';end if;
 if not exists(select 1 from charm.finance_accounts where finance_accounts.id=p_account and active) then raise exception 'invalid';end if;
 insert into charm.finance_statement_lines(account_id,reference,direction,amount,occurred_at,imported_by) values(p_account,trim(p_reference),p_direction,v,p_date,a) returning finance_statement_lines.id into id;
 perform charm.audit('statementImported','finance_statement_lines',id,jsonb_build_object('amount',v,'reference',p_reference));return charm.finish(p_key,id);
end$$;
create or replace function charm.finance_match_statement(p_id bigint,p_ledger bigint) returns void language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();s charm.finance_statement_lines;l charm.finance_ledger;effective_account bigint;begin
 perform charm.require_finance();select * into s from charm.finance_statement_lines where id=p_id for update;select * into l from charm.finance_ledger where id=p_ledger for update;
 if s.id is null or l.id is null or s.ledger_id is not null then raise exception 'financeLocked';end if;
 select account_id into effective_account from charm.finance_cashbook where id=p_ledger;
 if (effective_account is not null and s.account_id<>effective_account) or s.amount<>l.amount or s.direction<>l.direction or lower(trim(s.reference))<>lower(trim(l.reference)) or s.occurred_at<>(l.occurred_at at time zone 'Africa/Nairobi')::date then raise exception 'reconciliationMismatch';end if;
 update charm.finance_statement_lines set ledger_id=p_ledger,matched_by=a,matched_at=now() where id=p_id;
 perform charm.audit('statementMatched','finance_statement_lines',p_id,jsonb_build_object('ledger_id',p_ledger));
end$$;
-- Reuse existing customer payments: receipt verification and the cashbook insertion
-- share one transaction. Historical verified payments are linked once, not recreated.
create or replace function charm.finance_capture_customer_payment() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='verified' then
 insert into charm.finance_ledger(direction,amount,kind,reference,occurred_at,recorded_by,customer_payment_id) values('in',new.amount,'customer_receipt',new.reference,coalesce(new.received_at,now()),new.verified_by,new.id) on conflict(customer_payment_id) do nothing;
 end if;return new;end$$;
drop trigger if exists finance_customer_payment on charm.payments;
create trigger finance_customer_payment after insert or update of status on charm.payments for each row execute function charm.finance_capture_customer_payment();
insert into charm.finance_ledger(direction,amount,kind,reference,occurred_at,recorded_by,customer_payment_id)
 select 'in',amount,'customer_receipt',reference,received_at,verified_by,id from charm.payments where status='verified' and amount>0 and verified_by is not null on conflict(customer_payment_id) do nothing;
create or replace function charm.finance_verify_customer_receipt(p_id bigint,p_confirmed boolean,p_account bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();p charm.payments;o charm.orders;paid numeric;begin
 perform charm.require_finance();if p_confirmed is distinct from true then raise exception 'paymentConfirmationRequired';end if;
 if not exists(select 1 from charm.finance_accounts where id=p_account and active) then raise exception 'invalid';end if;
 select * into p from charm.payments where id=p_id;if p.id is null then raise exception 'notFound';end if;
 select * into o from charm.orders where id=p.order_id for update;select * into p from charm.payments where id=p_id for update;
 if p.submitted_by=a then raise exception 'selfApproval';end if;
 if p.status<>'pending' or o.status<>'confirmed' then raise exception 'financeLocked';end if;
 if p.proof_path is null or not exists(select 1 from storage.objects where bucket_id='charm-private' and name=p.proof_path) then raise exception 'proofRequired';end if;
 select coalesce(sum(amount),0) into paid from charm.payments where order_id=o.id and status='verified';if paid+p.amount>o.total then raise exception 'overpayment';end if;
 update charm.payments set status='verified',verified_by=a,verified_at=now(),updated_at=now() where id=p_id;
 -- The trigger first captures the receipt; an immutable allocation establishes its account.
 insert into charm.finance_receipt_allocations(payment_id,ledger_id,account_id,reference,confirmed_by)
 select p_id,id,p_account,p.reference,a from charm.finance_ledger where customer_payment_id=p_id;
 perform charm.audit('receiptConfirmed','payments',p_id,jsonb_build_object('account_id',p_account,'reference',p.reference,'amount',p.amount));
end$$;
-- Include statement allocations for receipts whose account was unknown in the legacy system.
create or replace view charm.finance_cashbook with(security_invoker=true) as
 select l.id,l.request_id,coalesce(l.account_id,a.account_id,s.account_id) account_id,l.direction,l.amount,l.kind,l.reference,l.occurred_at,l.recorded_by,l.customer_payment_id,s.id statement_id,s.matched_at
 from charm.finance_ledger l left join charm.finance_receipt_allocations a on a.ledger_id=l.id left join charm.finance_statement_lines s on s.ledger_id=l.id;
grant select on charm.finance_cashbook to authenticated;
-- Lock completed postings against accidental privileged modifications as well as browser writes.
create or replace function charm.finance_immutable() returns trigger language plpgsql set search_path='' as $$begin raise exception 'financeImmutable';end$$;
drop trigger if exists immutable_finance_allocations on charm.finance_receipt_allocations;
create trigger immutable_finance_allocations before update or delete on charm.finance_receipt_allocations for each row execute function charm.finance_immutable();
drop trigger if exists immutable_finance_documents on charm.finance_documents;
create trigger immutable_finance_documents before update or delete on charm.finance_documents for each row execute function charm.finance_immutable();
drop trigger if exists immutable_finance_ledger on charm.finance_ledger;
create trigger immutable_finance_ledger before update or delete on charm.finance_ledger for each row execute function charm.finance_immutable();
drop trigger if exists immutable_finance_disbursements on charm.finance_disbursements;
create trigger immutable_finance_disbursements before update or delete on charm.finance_disbursements for each row execute function charm.finance_immutable();
do $$ declare f record;begin
 for f in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='charm' and p.proname in ('finance_configure','finance_statement','finance_match_statement','finance_capture_customer_payment','finance_verify_customer_receipt','finance_immutable') loop
  execute format('revoke execute on function %s from public,anon,authenticated',f.signature);
  if f.proname not in ('finance_capture_customer_payment','finance_immutable') then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;end$$;

-- 202610130013_finance_storage.sql

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('charm-finance','charm-finance',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create or replace function charm.finance_file_access(p_path text,p_write boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare parts text[]:=string_to_array(p_path,'/');r charm.finance_requests;a bigint:=charm.actor();begin
 if a is null or p_path !~ '^requests/[0-9]+/(support|payment|receipt|refund)/[0-9]+/[a-f0-9-]{36}\.(pdf|jpg|png|webp)$' then return false;end if;
 select * into r from charm.finance_requests where id=parts[2]::bigint;
 if r.id is null then return false;end if;
 if not p_write then return charm.finance_access(r.id);end if;
 if charm.finance_role() in ('management','auditor') then return false;end if;
 if parts[4]::bigint<>a then return false;end if;
 return (parts[3]='support' and r.owner_id=a and r.status in ('draft','returned'))
  or (parts[3]='payment' and charm.finance_operator() and r.owner_id<>a and r.status in ('approved','part_paid'))
  or (parts[3] in ('receipt','refund') and r.owner_id=a and r.kind='staff' and r.status in ('part_paid','paid'));
end$$;
drop policy if exists finance_file_read on storage.objects;
create policy finance_file_read on storage.objects for select to authenticated using(bucket_id='charm-finance' and charm.finance_file_access(name,false));
drop policy if exists finance_file_upload on storage.objects;
create policy finance_file_upload on storage.objects for insert to authenticated with check(bucket_id='charm-finance' and charm.finance_file_access(name,true));
-- No overwrite/delete permission: attached evidence and payment proof are immutable.
create or replace function charm.finance_attach_document(p_id bigint,p_kind text,p_path text) returns bigint language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();id bigint;begin
 perform 1 from charm.finance_requests where finance_requests.id=p_id for update;
 if split_part(p_path,'/',2) is distinct from p_id::text or split_part(p_path,'/',3) is distinct from p_kind or not charm.finance_file_access(p_path,true) then raise exception 'forbidden';end if;
 if not exists(select 1 from storage.objects where bucket_id='charm-finance' and name=p_path) then raise exception 'proofRequired';end if;
 select finance_documents.id into id from charm.finance_documents where path=p_path;if id is not null then return id;end if;
 insert into charm.finance_documents(request_id,kind,path,uploaded_by) values(p_id,p_kind,p_path,a) returning finance_documents.id into id;
 perform charm.audit('financeDocument','finance_requests',p_id,jsonb_build_object('document_id',id,'kind',p_kind));return id;
end$$;
revoke execute on function charm.finance_file_access(text,boolean),charm.finance_attach_document(bigint,text,text) from public,anon,authenticated;
grant execute on function charm.finance_file_access(text,boolean),charm.finance_attach_document(bigint,text,text) to authenticated;
do $$ declare t text;begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
 foreach t in array array['finance_requests','finance_disbursements','finance_accountability','finance_ledger','finance_budgets','finance_notifications','finance_statement_lines'] loop
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='charm' and tablename=t) then execute format('alter publication supabase_realtime add table charm.%I',t);end if;
 end loop;end if;
end$$;

-- 202610130014_finance_reporting.sql

create or replace view charm.finance_request_balances with(security_invoker=true) as
 select r.*,u.name owner_name,c.name category_name,
 coalesce(d.paid,0)::numeric(14,2) paid,coalesce(e.spent,0)::numeric(14,2) spent,coalesce(e.refunded,0)::numeric(14,2) refunded,
 (case when r.kind='staff' then coalesce(d.paid,0)-coalesce(e.spent,0)-coalesce(e.refunded,0) else 0 end)::numeric(14,2) outstanding,
 coalesce(e.pending,0)::numeric(14,2) pending_accountability
 from charm.finance_requests r join charm.users u on u.id=r.owner_id join charm.finance_categories c on c.id=r.category_id
 left join lateral(select sum(amount) paid from charm.finance_disbursements where request_id=r.id)d on true
 left join lateral(select sum(amount) filter(where status='accepted' and kind='expense') spent,sum(amount) filter(where status='accepted' and kind='refund') refunded,sum(amount) filter(where status='pending') pending from charm.finance_accountability where request_id=r.id)e on true;
grant select on charm.finance_request_balances to authenticated;
create or replace view charm.finance_expenditure with(security_invoker=true) as
 select 'E-'||a.id::text id,a.request_id,r.owner_id,u.name owner_name,c.name category_name,a.expense_date,a.amount,a.description,'expense'::text kind,a.status,a.reference
 from charm.finance_accountability a join charm.finance_requests r on r.id=a.request_id join charm.users u on u.id=r.owner_id join charm.finance_categories c on c.id=r.category_id where a.kind='expense' and a.status='accepted'
 union all
 select 'S-'||d.id::text,d.request_id,r.owner_id,u.name,c.name,(d.paid_at at time zone 'Africa/Nairobi')::date,d.amount,r.purpose,'supplier'::text,'accepted'::text,d.reference
 from charm.finance_disbursements d join charm.finance_requests r on r.id=d.request_id join charm.users u on u.id=r.owner_id join charm.finance_categories c on c.id=r.category_id where r.kind='supplier';
grant select on charm.finance_expenditure to authenticated;
create or replace function charm.finance_metadata() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform charm.require_actor();return jsonb_build_object(
 'categories',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_categories c where active),
 'accounts',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('balance',(select coalesce(sum(case when direction='in' then amount else -amount end),0)::text from charm.finance_cashbook where account_id=c.id)) order by name),'[]') from charm.finance_accounts c where active and charm.finance_reader()),
 'refund_accounts',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_accounts c where active),
 'payees',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_payees c where staff_id=charm.actor() or charm.finance_reader()),
 'staff',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'active',active) order by name),'[]') from charm.users where charm.finance_reader()));
end$$;
create or replace function charm.finance_summary(p_from date,p_to date,p_owner bigint default null) returns jsonb language plpgsql stable security definer set search_path='' as $$declare a bigint:=charm.require_actor();result jsonb;begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 select jsonb_build_object('pending',count(*) filter(where status='pending'),'approved',coalesce(sum(approved_amount) filter(where status in ('approved','part_paid','paid','closed')),0)::text,'outstanding',coalesce(sum(outstanding),0)::text,'overdue',count(*) filter(where outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date),'expenses',coalesce(sum(spent),0)::text) into result from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and required_date between p_from and p_to;
 result:=result||jsonb_build_object('disbursed',(select coalesce(sum(d.amount),0)::text from charm.finance_disbursements d join charm.finance_requests r on r.id=d.request_id where (r.owner_id=a or charm.finance_reader()) and (p_owner is null or r.owner_id=p_owner) and (d.paid_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
 'cashflow',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select to_char(occurred_at at time zone 'Africa/Nairobi','YYYY-MM') as month,coalesce(sum(amount) filter(where direction='in'),0)::text incoming,coalesce(sum(amount) filter(where direction='out'),0)::text outgoing from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to and kind<>'opening' group by 1 order by 1)x),
 'categories',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select category_name,sum(amount)::text amount from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to group by category_name order by category_name)x),
 'expenses',(select coalesce(sum(amount),0)::text from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to),
 'outstanding',(select coalesce(sum(outstanding),0)::text from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner)),
 'overdue',(select count(*) from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date));return result;
end$$;
create or replace function charm.finance_register(p_view text,p_from date,p_to date,p_status text default '',p_owner bigint default null,p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_actor();rows jsonb;total bigint;begin
 if p_page is null or p_page<1 or p_page>10000 or p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 if p_view='requests' then
  select count(*) into total from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and required_date between p_from and p_to and (p_status='' or status=p_status);
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text,'approved_amount',approved_amount::text,'paid',paid::text,'spent',spent::text,'refunded',refunded::text,'outstanding',outstanding::text,'pending_accountability',pending_accountability::text)),'[]') into rows from(select * from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and required_date between p_from and p_to and (p_status='' or status=p_status) order by id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='cashbook' then
  select count(*) into total from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to order by id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='audit' and charm.finance_reader() then
  select count(*) into total from charm.audit_logs l where (l.entity like 'finance_%' or l.entity='payments') and (l.entity<>'finance_requests' or charm.finance_access(l.entity_id)) and (l.created_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_owner is null or (l.entity='finance_requests' and exists(select 1 from charm.finance_requests where id=l.entity_id and owner_id=p_owner)));
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from(select l.*,u.name actor_name from charm.audit_logs l join charm.users u on u.id=l.actor_id where (l.entity like 'finance_%' or l.entity='payments') and (l.entity<>'finance_requests' or charm.finance_access(l.entity_id)) and (l.created_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_owner is null or (l.entity='finance_requests' and exists(select 1 from charm.finance_requests where id=l.entity_id and owner_id=p_owner))) order by l.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='expenditure' then
  select count(*) into total from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to order by expense_date desc,id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='budgets' and charm.finance_reader() then
  select count(*) into total from charm.finance_budgets where month between date_trunc('month',p_from)::date and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from(select b.id,b.month,c.name category_name,b.amount::text amount,charm.finance_budget_committed(b.id)::text committed from charm.finance_budgets b join charm.finance_categories c on c.id=b.category_id where month between date_trunc('month',p_from)::date and p_to order by month desc,b.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='statements' and charm.finance_reader() then
  select count(*) into total from charm.finance_statement_lines where occurred_at between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.finance_statement_lines where occurred_at between p_from and p_to order by id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='receipts' and charm.finance_reader() then
  select count(*) into total from charm.payments where (received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or status=p_status);
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.payments where (received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or status=p_status) order by id desc limit 100 offset (p_page-1)*100)x;
 else raise exception 'forbidden';end if;
 return jsonb_build_object('rows',rows,'total',total);
end$$;
create or replace function charm.finance_detail(p_id bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$declare r jsonb;begin
 if not charm.finance_access(p_id) then raise exception 'forbidden';end if;
 select to_jsonb(x)||jsonb_build_object('amount',amount::text,'approved_amount',approved_amount::text,'paid',paid::text,'spent',spent::text,'refunded',refunded::text,'outstanding',outstanding::text,'pending_accountability',pending_accountability::text) into r from charm.finance_request_balances x where id=p_id;
 return jsonb_build_object('request',r,'documents',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from charm.finance_documents x where request_id=p_id),
 'payments',(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text) order by id),'[]') from charm.finance_disbursements x where request_id=p_id),
 'accountability',(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text) order by id),'[]') from charm.finance_accountability x where request_id=p_id),
 'history',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from(select l.id,l.actor_id,u.name actor_name,l.action,l.details,l.created_at from charm.audit_logs l join charm.users u on u.id=l.actor_id where (l.entity='finance_requests' and l.entity_id=p_id) or (l.entity='expenses' and l.entity_id=(select source_expense_id from charm.finance_requests where id=p_id)) order by l.id desc limit 200)x));
end$$;
do $$ declare f record;begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='charm' and p.proname in ('finance_metadata','finance_summary','finance_register','finance_detail') loop
  execute format('revoke execute on function %s from public,anon',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
 end loop;end$$;
notify pgrst,'reload schema';

-- 202610130015_finance_staff_roles.sql

create or replace function charm.update_staff(p_id bigint,p_name text,p_phone text,p_territory text,p_role text,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint; u charm.users; caller charm.users;
begin
 a:=charm.require_admin();
 perform pg_advisory_xact_lock(817201008);
 select * into caller from charm.users where id=a for update;
 if caller.role<>'admin' or not caller.active then raise exception 'forbidden'; end if;
 select * into u from charm.users where id=p_id for update;
 if not found then raise exception 'notFound'; end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(p_phone),0)>40 or coalesce(length(p_territory),0)>200 or p_role is null or p_role not in ('admin','salesperson','finance_officer','finance_manager','management','auditor') or p_active is null then raise exception 'invalid'; end if;
 if p_id=a and (p_role<>u.role or p_active<>u.active) then raise exception 'selfRoleChange'; end if;
 if u.role='admin' and u.active and (p_role<>'admin' or not p_active) and (select count(*) from charm.users where role='admin' and active)<=1 then raise exception 'lastAdmin'; end if;
 update charm.users set name=trim(p_name),phone=nullif(trim(p_phone),''),territory=nullif(trim(p_territory),''),role=p_role,active=p_active,updated_at=now() where id=p_id;
 perform charm.audit('staffUpdated','users',p_id,jsonb_build_object('before',jsonb_build_object('name',u.name,'phone',u.phone,'territory',u.territory,'role',u.role,'active',u.active),'after',jsonb_build_object('name',trim(p_name),'phone',p_phone,'territory',p_territory,'role',p_role,'active',p_active)));
end $$;
create or replace function charm.link_staff(p_actor uuid,p_auth uuid,p_email text,p_name text,p_role text) returns bigint language plpgsql security definer set search_path='' as $$
declare admin_id bigint; staff_id bigint; existing_auth uuid; canonical_email text;
begin
 select u.id into admin_id from charm.auth_accounts a join charm.users u on u.id=a.salesperson_id where a.auth_user_id=p_actor and u.active and u.role='admin';
 if admin_id is null or p_actor=p_auth then raise exception 'forbidden'; end if;
 select email into canonical_email from auth.users where id=p_auth;
 if canonical_email is null or lower(canonical_email)<>lower(trim(p_email)) or p_role not in ('admin','salesperson','finance_officer','finance_manager','management','auditor') or coalesce(length(trim(p_name)),0) not between 1 and 200 then raise exception 'invalid'; end if;
 perform pg_advisory_xact_lock(hashtextextended(lower(trim(p_email)),1));
 if (select count(*) from charm.users where lower(email)=lower(trim(p_email)))>1 then raise exception 'duplicateConflict'; end if;
 select id into staff_id from charm.users where lower(email)=lower(trim(p_email)) for update;
 if staff_id=admin_id then raise exception 'forbidden'; end if;
 if staff_id is null then
  -- Unusable legacy password; Supabase reset/invite establishes the real credential.
  insert into charm.users(name,email,password,role,active,created_at,updated_at) values(p_name,lower(trim(p_email)),'!supabase-auth-only!',p_role,true,now(),now()) returning id into staff_id;
 end if;
 select auth_user_id into existing_auth from charm.auth_accounts where salesperson_id=staff_id;
 if existing_auth is not null and existing_auth<>p_auth then raise exception 'duplicateConflict'; end if;
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values(p_auth,staff_id) on conflict(auth_user_id) do nothing;
 if not exists(select 1 from charm.auth_accounts where auth_user_id=p_auth and salesperson_id=staff_id) then raise exception 'duplicateConflict'; end if;
 insert into charm.audit_logs(actor_id,action,entity,entity_id,details,created_at) values(admin_id,'invited','users',staff_id,jsonb_build_object('auth_user_id',p_auth),now());
 return staff_id;
end $$;

-- 202610130016_finance_role_guards.sql

create or replace function charm.require_sales_writer() returns bigint language plpgsql stable security definer set search_path='' as $$begin if charm.finance_role() not in ('admin','salesperson') then raise exception 'forbidden';end if;return charm.require_actor();end$$;
revoke execute on function charm.require_sales_writer() from public,anon,authenticated;
create or replace function charm.submit_order(p_key uuid,p_client bigint,p_due date,p_items jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); c charm.clients; p charm.products; item jsonb; total numeric:=0; id bigint; old bigint; qty integer; price numeric;
begin
 old:=charm.claim(p_key,'order',jsonb_build_object('client',p_client,'due',p_due,'items',p_items)); if old is not null then return old; end if;
 select * into c from charm.clients where clients.id=p_client for share;
 if not found or not charm.can_access(c.salesperson_id) then raise exception 'forbidden'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'invalid'; end if;
 if jsonb_array_length(p_items) not between 1 and 100 then raise exception 'invalid'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  select * into p from charm.products where products.id=(item->>'product_id')::bigint and active;
  if not found or item->>'unit' not in ('bottle','carton') or item->>'unit' is null then raise exception 'invalid'; end if;
  if coalesce(item->>'quantity','') !~ '^\d+$' then raise exception 'invalidQuantity'; end if;
  qty:=(item->>'quantity')::integer; if qty not between 1 and 100000 then raise exception 'invalidQuantity'; end if;
  price:=charm.money(item->>'unit_price'); total:=total+qty*price;
 end loop;
 if total>999999999999.99 then raise exception 'invalidMoney'; end if;
 insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at)
 values(p_key,p_client,c.salesperson_id,a,total,p_due,'pending',now(),now()) returning orders.id into id;
 for item in select value from jsonb_array_elements(p_items) loop
  select * into p from charm.products where products.id=(item->>'product_id')::bigint;
  insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total)
  values(id,p.id,concat(p.category,' ',p.capacity,' ',p.fragrance),item->>'unit',(item->>'quantity')::integer,(item->>'unit_price')::numeric,(item->>'quantity')::integer*(item->>'unit_price')::numeric);
 end loop;
 perform charm.audit('submitted','orders',id); return charm.finish(p_key,id);
end $$;
create or replace function charm.submit_payment(p_key uuid,p_order bigint,p_amount text,p_reference text,p_received timestamptz,p_notes text default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); o charm.orders; id bigint; old bigint; amount numeric:=charm.money(p_amount);
begin
 old:=charm.claim(p_key,'payment',jsonb_build_object('order',p_order,'amount',p_amount,'reference',p_reference,'received',p_received,'notes',p_notes)); if old is not null then return old; end if;
 select * into o from charm.orders where orders.id=p_order;
 if not found or not charm.can_access(o.salesperson_id) then raise exception 'forbidden'; end if;
 if o.status<>'confirmed' or p_received is null or p_received>now() or coalesce(length(trim(p_reference)),0) not between 1 and 200 or coalesce(length(p_notes),0)>10000 then raise exception 'invalid'; end if;
 insert into charm.payments(submission_key,order_id,submitted_by,amount,reference,received_at,follow_up_notes,status,created_at,updated_at)
 values(p_key,p_order,a,amount,p_reference,p_received,p_notes,'pending',now(),now()) returning payments.id into id;
 perform charm.audit('submitted','payments',id); return charm.finish(p_key,id);
end $$;
create or replace function charm.save_client(p_key uuid,p_name text,p_contact text,p_phone text,p_location text,p_owner bigint) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); old bigint; id bigint;
begin
 if p_owner is null or (p_owner<>a and not charm.is_admin()) then raise exception 'forbidden'; end if;
 old:=charm.claim(p_key,'client',jsonb_build_array(p_name,p_contact,p_phone,p_location,p_owner)); if old is not null then return old; end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(trim(p_contact)),0) not between 1 and 200 or coalesce(length(trim(p_location)),0) not between 1 and 255 or coalesce(length(p_phone),0)>40 or not exists(select 1 from charm.users where users.id=p_owner and active) then raise exception 'invalid'; end if;
 insert into charm.clients(salesperson_id,name,contact,phone,location,created_at,updated_at) values(p_owner,p_name,p_contact,p_phone,p_location,now(),now()) returning clients.id into id;
 perform charm.audit('created','clients',id); return charm.finish(p_key,id);
end $$;
create or replace function charm.submit_record(p_key uuid,p_kind text,p_date date,p_client bigint,p_budget text,p_notes text,p_follow_up date default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); old bigint; id bigint; budget numeric;
begin
 if p_kind not in ('plans','expenses','reports') or p_kind is null then raise exception 'invalid'; end if;
 old:=charm.claim(p_key,p_kind,jsonb_build_array(p_date,p_client,p_budget,p_notes,p_follow_up)); if old is not null then return old; end if;
 if p_date is null or coalesce(length(trim(p_notes)),0) not between 1 and 10000 then raise exception 'invalid'; end if;
 if p_kind in ('plans','expenses') and p_date<=(now() at time zone 'Africa/Nairobi')::date then raise exception 'advanceRequired'; end if;
 if p_client is not null and not exists(select 1 from charm.clients where clients.id=p_client and charm.can_access(salesperson_id)) then raise exception 'forbidden'; end if;
 if p_kind='expenses' and p_client is null then raise exception 'clientRequired'; end if;
 if p_follow_up is not null and p_follow_up<p_date then raise exception 'invalid'; end if;
 if p_budget is not null and p_budget<>'' then
  if p_budget !~ '^\d{1,8}(\.\d{1,2})?$' then raise exception 'invalidMoney'; end if;
  budget:=p_budget::numeric;
 end if;
 execute format('insert into charm.%I(submission_key,salesperson_id,date,client_id,budget,notes,status,created_at,updated_at) values($1,$2,$3,$4,$5,$6,''pending'',now(),now()) returning id',p_kind)
 into id using p_key,a,p_date,p_client,budget,p_notes;
 if p_kind='reports' then update charm.reports set follow_up_date=p_follow_up where reports.id=id; end if;
 perform charm.audit('submitted',p_kind,id); return charm.finish(p_key,id);
end $$;
create or replace function charm.submit_visit(p_key uuid,p_client bigint,p_lat numeric,p_lng numeric,p_accuracy numeric,p_outcome text,p_notes text,p_reason text,p_next text,p_follow_up date) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); id bigint; old bigint;
begin
 old:=charm.claim(p_key,'visit',jsonb_build_array(p_client,p_lat,p_lng,p_accuracy,p_outcome,p_notes,p_reason,p_next,p_follow_up)); if old is not null then return old; end if;
 if not exists(select 1 from charm.clients where clients.id=p_client and charm.can_access(salesperson_id)) then raise exception 'forbidden'; end if;
 if p_lat is null or p_lng is null or p_accuracy is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy not between 0 and 100000 then raise exception 'invalidLocation'; end if;
 if p_outcome is null or p_outcome not in ('order','follow-up','no-sale','payment-follow-up') or coalesce(length(trim(p_notes)),0) not between 1 and 10000 or coalesce(length(p_next),0)>1000 then raise exception 'invalid'; end if;
 if p_outcome='no-sale' and coalesce(length(trim(p_reason)),0) not between 1 and 1000 then raise exception 'reasonRequired'; end if;
 insert into charm.visits(submission_key,salesperson_id,client_id,check_in_at,latitude,longitude,accuracy_m,outcome,notes,unsuccessful_reason,next_action,follow_up_date,created_at,updated_at)
 values(p_key,a,p_client,now(),p_lat,p_lng,p_accuracy,p_outcome,p_notes,p_reason,p_next,p_follow_up,now(),now()) returning visits.id into id;
 perform charm.audit('checkedIn','visits',id); return charm.finish(p_key,id);
end $$;
create or replace function charm.checkout_visit(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); v charm.visits;
begin
 select * into v from charm.visits where id=p_id for update;
 if not found or v.salesperson_id<>a then raise exception 'forbidden'; end if;
 if v.check_out_at is null then update charm.visits set check_out_at=now(),updated_at=now() where id=p_id; perform charm.audit('checkedOut','visits',p_id); end if;
end $$;
create or replace function charm.start_workday() returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); id bigint; w charm.workdays;
begin
 perform 1 from charm.users where users.id=a for update;
 select * into w from charm.workdays where salesperson_id=a and (ended_at is null or date=(now() at time zone 'Africa/Nairobi')::date) order by id desc limit 1;
 if found then if w.ended_at is not null then raise exception 'alreadyReviewed'; end if; return w.id; end if;
 insert into charm.workdays(salesperson_id,date,started_at) values(a,(now() at time zone 'Africa/Nairobi')::date,now()) returning workdays.id into id;
 return id;
end $$;
create or replace function charm.end_workday(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 update charm.workdays set ended_at=coalesce(ended_at,now()) where id=p_id and salesperson_id=charm.require_sales_writer();
 if not found then raise exception 'forbidden'; end if;
end $$;
create or replace function charm.location_batch(p_workday bigint,p_points jsonb) returns integer language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); w charm.workdays; point jsonb; at timestamptz; key uuid; old bigint; id bigint; lat numeric; lng numeric; accuracy numeric;
begin
 select * into w from charm.workdays where workdays.id=p_workday for update;
 if not found or w.salesperson_id<>a then raise exception 'forbidden'; end if;
 if p_points is null or jsonb_typeof(p_points)<>'array' then raise exception 'invalid'; end if;
 if jsonb_array_length(p_points) not between 1 and 200 then raise exception 'invalid'; end if;
 for point in select value from jsonb_array_elements(p_points) loop
  key:=(point->>'submission_key')::uuid; at:=(point->>'recorded_at')::timestamptz;
  lat:=(point->>'latitude')::numeric; lng:=(point->>'longitude')::numeric; accuracy:=(point->>'accuracy_m')::numeric;
  if at is null or at<w.started_at or at>coalesce(w.ended_at,now()) or lat is null or lng is null or accuracy is null or lat not between -90 and 90 or lng not between -180 and 180 or accuracy not between 0 and 100000 then raise exception 'invalidLocation'; end if;
  old:=charm.claim(key,'location',jsonb_build_object('workday',p_workday,'point',point));
  if old is null then
   insert into charm.location_points(submission_key,workday_id,latitude,longitude,accuracy_m,recorded_at,received_at) values(key,p_workday,lat,lng,accuracy,at,now()) returning location_points.id into id;
   perform charm.finish(key,id);
  end if;
 end loop;
 return jsonb_array_length(p_points);
end $$;
create or replace function charm.set_client_location(p_id bigint,p_lat numeric,p_lng numeric,p_accuracy numeric) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); c charm.clients;
begin
 select * into c from charm.clients where id=p_id for update;
 if not found or not charm.can_access(c.salesperson_id) then raise exception 'forbidden'; end if;
 if p_lat is null or p_lng is null or p_accuracy is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy not between 0 and 100000 then raise exception 'invalidLocation'; end if;
 update charm.clients set latitude=p_lat,longitude=p_lng,location_accuracy_m=p_accuracy,location_captured_at=now(),updated_at=now() where id=p_id;
 perform charm.audit('locationUpdated','clients',p_id,jsonb_build_object('accuracy_m',p_accuracy));
end $$;
drop policy if exists finance_customer_proof_read on storage.objects;
create policy finance_customer_proof_read on storage.objects for select to authenticated using(bucket_id='charm-private' and charm.finance_reader() and split_part(name,'/',1)='payments' and split_part(name,'/',2) ~ '^\d+$' and exists(select 1 from charm.payments where id=split_part(name,'/',2)::bigint));
create or replace function charm.file_access(path text,writing boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare kind text:=split_part(path,'/',1); record_id bigint; owner bigint; status text;
begin
 if writing and charm.finance_role() not in ('admin','salesperson') then return false;end if;
 if charm.actor() is null or split_part(path,'/',2) !~ '^\d+$' then return false; end if;
 record_id:=split_part(path,'/',2)::bigint;
 if kind='visits' then select salesperson_id into owner from charm.visits where visits.id=record_id;
 elsif kind='payments' then select o.salesperson_id,p.status into owner,status from charm.payments p join charm.orders o on o.id=p.order_id where p.id=record_id;
 else return false; end if;
 if writing and kind='payments' and status<>'pending' then return false; end if;
 return owner is not null and coalesce(charm.can_access(owner),false);
end $$;
create or replace function charm.review_record(p_kind text,p_id bigint,p_approve boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor(); r record;
begin
 perform charm.require_admin();
 if p_approve is null then raise exception 'invalid'; end if;
 if p_kind not in ('plans','expenses','reports') or p_kind is null then raise exception 'invalid'; end if;
 execute format('select * from charm.%I where id=$1 for update',p_kind) into r using p_id;
 if r.id is null then raise exception 'notFound'; end if;
 if r.salesperson_id=a then raise exception 'selfApproval'; end if;
 if r.status<>'pending' then raise exception 'alreadyReviewed'; end if;
 execute format('update charm.%I set status=$1,reviewed_by=$2,reviewed_at=now(),updated_at=now() where id=$3',p_kind) using case when p_approve then 'approved' else 'rejected' end,a,p_id;
 perform charm.audit(case when p_approve then 'approved' else 'rejected' end,p_kind,p_id);
end $$;
create or replace function charm.approve_order(p_id bigint,p_confirm boolean,p_reason text default null) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor(); o charm.orders;
begin
 perform charm.require_admin();
 if p_confirm is null then raise exception 'invalid'; end if;
 select * into o from charm.orders where id=p_id for update;
 if not found then raise exception 'notFound'; end if;
 if o.submitted_by=a or (o.submitted_by is null and o.salesperson_id=a) then raise exception 'selfApproval'; end if;
 if o.status<>'pending' then raise exception 'alreadyReviewed'; end if;
 if not p_confirm and coalesce(length(trim(p_reason)),0) not between 1 and 1000 then raise exception 'reasonRequired'; end if;
 update charm.orders set status=case when p_confirm then 'confirmed' else 'rejected' end,
 confirmed_at=case when p_confirm then now() end,confirmed_by=case when p_confirm then a end,reason=p_reason,updated_at=now() where id=p_id;
 perform charm.audit(case when p_confirm then 'confirmed' else 'rejected' end,'orders',p_id);
end $$;
create or replace function charm.review_payment(p_id bigint,p_verify boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor(); p charm.payments; o charm.orders; paid numeric;
begin
 perform charm.require_admin();
 if p_verify is null then raise exception 'invalid'; end if;
 select * into p from charm.payments where id=p_id;
 if not found then raise exception 'notFound'; end if;
 -- Always lock parent order first: serializes competing partial-payment approvals.
 select * into o from charm.orders where id=p.order_id for update;
 select * into p from charm.payments where id=p_id for update;
 if p.submitted_by=a then raise exception 'selfApproval'; end if;
 if p.status<>'pending' or o.status<>'confirmed' then raise exception 'alreadyReviewed'; end if;
 select coalesce(sum(amount),0) into paid from charm.payments where order_id=o.id and status='verified';
 if p_verify and paid+p.amount>o.total then raise exception 'overpayment'; end if;
 update charm.payments set status=case when p_verify then 'verified' else 'rejected' end,verified_by=a,verified_at=now(),updated_at=now() where id=p_id;
 perform charm.audit(case when p_verify then 'verified' else 'rejected' end,'payments',p_id);
end $$;
notify pgrst,'reload schema';

-- 202610130017_finance_exports.sql

-- STABLE uses the caller statement's MVCC snapshot across every register page.
create or replace function charm.finance_export(p_view text,p_from date,p_to date,p_status text default '',p_owner bigint default null) returns jsonb language plpgsql stable security definer set search_path='' as $$declare data jsonb;rows jsonb;page integer:=2;begin
 data:=charm.finance_register(p_view,p_from,p_to,p_status,p_owner,1);
 if (data->>'total')::integer>5000 then raise exception 'financeExportLimit';end if;rows:=data->'rows';
 while jsonb_array_length(rows)<(data->>'total')::integer loop rows:=rows||(charm.finance_register(p_view,p_from,p_to,p_status,p_owner,page)->'rows');page:=page+1;end loop;return rows;
end$$;
revoke execute on function charm.finance_export(text,date,date,text,bigint) from public,anon;
grant execute on function charm.finance_export(text,date,date,text,bigint) to authenticated;
notify pgrst,'reload schema';

-- 202610130018_finance_record_guards.sql

create or replace function charm.finance_protect_request() returns trigger language plpgsql set search_path='' as $$begin
 if tg_op='DELETE' or old.status='closed' then raise exception 'financeImmutable';end if;
 if old.status in ('approved','part_paid','paid') and row(old.owner_id,old.kind,old.payee_id,old.category_id,old.amount,old.approved_amount,old.purpose,old.required_date,old.accountability_due,old.approved_by,old.approved_at,old.budget_id,old.source_expense_id) is distinct from row(new.owner_id,new.kind,new.payee_id,new.category_id,new.amount,new.approved_amount,new.purpose,new.required_date,new.accountability_due,new.approved_by,new.approved_at,new.budget_id,new.source_expense_id) then raise exception 'financeImmutable';end if;
 return new;
end$$;
drop trigger if exists finance_request_guard on charm.finance_requests;
create trigger finance_request_guard before update or delete on charm.finance_requests for each row execute function charm.finance_protect_request();
create or replace function charm.finance_protect_accountability() returns trigger language plpgsql set search_path='' as $$begin
 if tg_op='DELETE' or old.status='accepted' then raise exception 'financeImmutable';end if;return new;
end$$;
drop trigger if exists finance_accountability_guard on charm.finance_accountability;
create trigger finance_accountability_guard before update or delete on charm.finance_accountability for each row execute function charm.finance_protect_accountability();
revoke execute on function charm.finance_protect_request(),charm.finance_protect_accountability() from public,anon,authenticated;
notify pgrst,'reload schema';

-- 202610130019_finance_legacy_relay.sql

create or replace function charm.finance_bridge_expense() returns trigger language plpgsql security definer set search_path='' as $$declare id bigint;begin
 if new.budget>0 then
 insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,status,source_expense_id,created_at)
 values(new.salesperson_id,'staff',(select c.id from charm.finance_categories c where c.name='Other'),new.budget,new.notes,new.date,new.date+7,case when new.status='rejected' then 'rejected' else 'pending' end,new.id,coalesce(new.created_at,now())) on conflict(source_expense_id) do nothing returning finance_requests.id into id;
 if id is not null and new.status<>'rejected' then perform charm.finance_notify(id,'financeSubmitted','legacy-expense:'||new.id,array['admin']);end if;
 end if;return new;
end$$;
create or replace function charm.finance_sync_expense_rejection() returns trigger language plpgsql security definer set search_path='' as $$declare id bigint;begin
 if new.status='rejected' and old.status='pending' then
 update charm.finance_requests set status='rejected',reason='Original travel request rejected',updated_at=now() where source_expense_id=new.id and status in ('draft','pending','returned') returning finance_requests.id into id;
 if id is not null then perform charm.finance_notify(id,'rejected','legacy-rejected:'||new.id);end if;
 end if;return new;
end$$;
drop trigger if exists finance_expense_rejection on charm.expenses;
create trigger finance_expense_rejection after update of status on charm.expenses for each row execute function charm.finance_sync_expense_rejection();
revoke execute on function charm.finance_bridge_expense(),charm.finance_sync_expense_rejection() from public,anon,authenticated;
notify pgrst,'reload schema';

-- 202610130020_finance_reference_controls.sql

create unique index if not exists finance_disbursement_reference_normalized on charm.finance_disbursements(account_id,lower(trim(reference)));
create unique index if not exists finance_refund_reference_normalized on charm.finance_accountability(account_id,lower(trim(reference))) where kind='refund' and status='accepted';
create unique index if not exists finance_receipt_reference_normalized on charm.finance_receipt_allocations(account_id,lower(trim(reference)));
create unique index if not exists finance_statement_reference_normalized on charm.finance_statement_lines(account_id,lower(trim(reference)),direction);
notify pgrst,'reload schema';

-- 202610130021_finance_company_hub.sql

alter table charm.users drop constraint if exists users_finance_roles;
update charm.users set role='finance_officer' where role in ('finance_manager','management','auditor');
alter table charm.users add constraint users_finance_roles check(role in ('admin','salesperson','finance_officer'));
create or replace function charm.finance_reader() returns boolean language sql stable security definer set search_path='' as $$select coalesce(charm.finance_role() in ('admin','finance_officer'),false)$$;
create or replace function charm.finance_operator() returns boolean language sql stable security definer set search_path='' as $$select coalesce(charm.finance_role() in ('admin','finance_officer'),false)$$;
create or replace function charm.require_finance(p_manager boolean default false) returns bigint language plpgsql stable security definer set search_path='' as $$begin
 if not charm.finance_operator() then raise exception 'forbidden'; end if; return charm.require_actor(); end$$;

create or replace function charm.finance_money(p_value text) returns numeric language plpgsql immutable set search_path='' as $$begin
 if p_value is null or p_value !~ '^\d{1,10}(\.\d{1,2})?$' or p_value::numeric<=0 then raise exception 'invalidMoney';end if;return p_value::numeric;end$$;
create or replace function charm.finance_budget_committed(p_id bigint) returns numeric language sql stable security definer set search_path='' as $$
 select coalesce(sum(case when r.status='closed' then case when r.kind='staff' then (select coalesce(sum(amount),0) from charm.finance_accountability where request_id=r.id and kind='expense' and status='accepted') else (select coalesce(sum(amount),0) from charm.finance_disbursements where request_id=r.id) end else r.approved_amount end),0)
 from charm.finance_requests r where r.budget_id=p_id and r.status in ('approved','part_paid','paid','closed')
$$;
create or replace function charm.finance_save_request(p_key uuid,p_id bigint,p_category bigint,p_amount text,p_purpose text,p_date date,p_due date,p_payee bigint default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;old bigint;v numeric:=charm.finance_money(p_amount);request_kind text;
begin
 if charm.finance_role() not in ('salesperson','admin','finance_officer') then raise exception 'forbidden';end if;
 old:=charm.claim(p_key,'finance_save_request',jsonb_build_array(p_id,p_category,p_amount,p_purpose,p_date,p_due,p_payee));if old is not null then return old;end if;
 if not exists(select 1 from charm.finance_categories where id=p_category and active) or coalesce(length(trim(p_purpose)),0) not between 1 and 10000 or p_date is null or p_due is null or p_date<(now() at time zone 'Africa/Nairobi')::date or p_due<p_date then raise exception 'invalid';end if;
 request_kind:=case when p_payee is null then 'staff' else 'supplier' end;
 if request_kind='staff' and charm.finance_role() not in ('salesperson','admin') then raise exception 'forbidden';end if;
 if request_kind='supplier' and (not charm.finance_operator() or not exists(select 1 from charm.finance_payees where id=p_payee and staff_id is null)) then raise exception 'forbidden';end if;
 if p_id is null then
  insert into charm.finance_requests(owner_id,kind,payee_id,category_id,amount,purpose,required_date,accountability_due) values(a,request_kind,p_payee,p_category,v,trim(p_purpose),p_date,p_due) returning * into r;
 else
  select * into r from charm.finance_requests where id=p_id for update;
  if r.owner_id is distinct from a or r.status not in ('draft','returned')  then raise exception 'financeLocked';end if;
  update charm.finance_requests set category_id=p_category,amount=v,purpose=trim(p_purpose),required_date=p_date,accountability_due=p_due,kind=request_kind,payee_id=p_payee,updated_at=now() where id=p_id;
 end if;
 perform charm.audit('financeDraft','finance_requests',r.id,jsonb_build_object('before',case when p_id is null then null else to_jsonb(r) end,'amount',v,'purpose',p_purpose,'category_id',p_category,'required_date',p_date,'accountability_due',p_due,'payee_id',p_payee));return charm.finish(p_key,r.id);
end$$;
create or replace function charm.finance_submit_request(p_id bigint) returns void language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;begin
 select * into r from charm.finance_requests where id=p_id for update;
 if r.owner_id is distinct from a then raise exception 'forbidden';end if;
 if r.status='pending' then return;end if;
 if r.status not in ('draft','returned') then raise exception 'financeLocked';end if;
 update charm.finance_requests set status='pending',reason=null,updated_at=now() where id=p_id;
 perform charm.audit('financeSubmitted','finance_requests',p_id);
 perform charm.finance_notify(p_id,'financeSubmitted','submitted:'||p_id||':'||now(),array['admin']);
end$$;
create or replace function charm.finance_review_request(p_id bigint,p_decision text,p_reason text,p_amount text default null) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;b charm.finance_budgets;v numeric;used numeric;begin
 select * into r from charm.finance_requests where id=p_id for update;
 if r.id is null then raise exception 'notFound';end if;
 if not charm.is_admin() then raise exception 'forbidden';end if;
 if r.owner_id=a then raise exception 'selfApproval';end if;
 if r.status<>'pending' or p_decision is null or p_decision not in ('approved','returned','rejected') then raise exception 'financeLocked';end if;
 if p_decision<>'approved' and coalesce(length(trim(p_reason)),0) not between 1 and 2000 then raise exception 'reasonRequired';end if;
 if p_decision='approved' then
  v:=charm.finance_money(p_amount);if v>r.amount then raise exception 'overpayment';end if;
  select * into b from charm.finance_budgets where category_id=r.category_id and month=date_trunc('month',r.required_date)::date for update;
  if b.id is null then raise exception 'budgetMissing';end if;
  used:=charm.finance_budget_committed(b.id);
  if used+v>b.amount then raise exception 'budgetExceeded';end if;
 end if;
 update charm.finance_requests set status=p_decision,reason=nullif(trim(p_reason),''),approved_amount=v,approved_by=a,approved_at=now(),budget_id=b.id,updated_at=now() where id=p_id;
 if r.source_expense_id is not null and p_decision in ('approved','rejected') then
  update charm.expenses set status=p_decision,reviewed_by=a,reviewed_at=now(),updated_at=now() where id=r.source_expense_id and status='pending';
 end if;
 perform charm.audit('financeDecision','finance_requests',p_id,jsonb_build_object('decision',p_decision,'reason',p_reason,'approved_amount',v,'before_status',r.status));
 perform charm.finance_notify(p_id,p_decision,'decision:'||p_id||':'||now(),case when p_decision='approved' then array['finance_officer'] else '{}'::text[] end);
end$$;
create or replace function charm.finance_disburse(p_key uuid,p_id bigint,p_account bigint,p_amount text,p_reference text,p_date timestamptz,p_proof bigint,p_confirmed boolean) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;payee charm.finance_payees;v numeric:=charm.finance_money(p_amount);paid numeric;outstanding numeric;old bigint;id bigint;balance numeric;
begin
 perform charm.require_finance();old:=charm.claim(p_key,'finance_disburse',jsonb_build_array(p_id,p_account,p_amount,p_reference,p_date,p_proof,p_confirmed));if old is not null then return old;end if;
 select * into r from charm.finance_requests where finance_requests.id=p_id for update;
 if r.status is null or r.status not in ('approved','part_paid') or r.approved_amount is null or r.approved_at is null or r.approved_by is null or r.approved_by=r.owner_id or r.budget_id is null then raise exception 'financeLocked';end if;
 if r.kind='staff' and a=r.owner_id then raise exception 'selfApproval';end if;
 if p_confirmed is distinct from true or coalesce(length(trim(p_reference)),0) not between 1 and 200 or p_date is null or p_date>now() or p_date<date_trunc('minute',r.approved_at) then raise exception 'paymentConfirmationRequired';end if;
 if not exists(select 1 from charm.finance_accounts where finance_accounts.id=p_account and active) then raise exception 'invalid';end if;
 if not exists(select 1 from charm.finance_documents where finance_documents.id=p_proof and request_id=p_id and kind='payment' and uploaded_by=a) then raise exception 'proofRequired';end if;
 select * into payee from charm.finance_payees where (r.kind='staff' and staff_id=r.owner_id) or (r.kind='supplier' and finance_payees.id=r.payee_id);
 if payee.id is null then raise exception 'payeeMissing';end if;
 if r.kind='staff' and not exists(select 1 from charm.users where users.id=r.owner_id and active) then raise exception 'staffInactive';end if;
 select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=p_id;
 if paid+v>r.approved_amount then raise exception 'overpayment';end if;
 -- Block a new advance if another disbursed advance for this person remains unsettled.
 if r.kind='staff' then
  select coalesce(sum(d.paid-coalesce(e.settled,0)),0) into outstanding from charm.finance_requests x
  join lateral(select coalesce(sum(amount),0) paid from charm.finance_disbursements where request_id=x.id)d on true
  join lateral(select coalesce(sum(amount),0) settled from charm.finance_accountability where request_id=x.id and status='accepted')e on true
  where x.owner_id=r.owner_id and x.kind='staff' and x.id<>p_id and x.status<>'closed';
  if outstanding>0 then raise exception 'advanceOutstanding';end if;
 end if;
 perform 1 from charm.finance_accounts where finance_accounts.id=p_account for update;
 select coalesce(sum(case when direction='in' then amount else -amount end),0) into balance from charm.finance_cashbook where account_id=p_account;
 if balance<v then raise exception 'insufficientFunds';end if;
 insert into charm.finance_disbursements(request_id,account_id,amount,reference,paid_at,payee_snapshot,proof_id,recorded_by) values(p_id,p_account,v,trim(p_reference),p_date,to_jsonb(payee),p_proof,a) returning finance_disbursements.id into id;
 insert into charm.finance_ledger(request_id,account_id,direction,amount,kind,reference,occurred_at,recorded_by,disbursement_id) values(p_id,p_account,'out',v,case when r.kind='staff' then 'advance' else 'supplier' end,trim(p_reference),p_date,a,id);
 update charm.finance_requests set status=case when paid+v=approved_amount then 'paid' else 'part_paid' end,updated_at=now() where finance_requests.id=p_id;
 perform charm.audit('financeDisbursed','finance_requests',p_id,jsonb_build_object('disbursement_id',id,'amount',v,'account_id',p_account,'reference',trim(p_reference),'payee_id',payee.id,'proof_id',p_proof));
 perform charm.finance_notify(p_id,'financeDisbursed','disbursement:'||id,array['admin']);return charm.finish(p_key,id);
end$$;
create or replace function charm.finance_submit_accountability(p_key uuid,p_id bigint,p_kind text,p_amount text,p_description text,p_proof bigint,p_reference text default null,p_account bigint default null,p_date date default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;v numeric:=charm.finance_money(p_amount);old bigint;id bigint;paid numeric;claimed numeric;begin
 old:=charm.claim(p_key,'finance_accountability',jsonb_build_array(p_id,p_kind,p_amount,p_description,p_proof,p_reference,p_account,p_date));if old is not null then return old;end if;
 select * into r from charm.finance_requests where finance_requests.id=p_id for update;
 if r.owner_id is distinct from a or r.kind<>'staff' then raise exception 'forbidden';end if;
 if r.status not in ('part_paid','paid') then raise exception 'financeLocked';end if;
 if p_kind is null or p_kind not in ('expense','refund') or coalesce(length(trim(p_description)),0) not between 1 and 10000 then raise exception 'invalid';end if;
 if not exists(select 1 from charm.finance_documents where finance_documents.id=p_proof and request_id=p_id and kind=case when p_kind='expense' then 'receipt' else 'refund' end and uploaded_by=a) then raise exception 'proofRequired';end if;
 if p_date is not null and p_date>(now() at time zone 'Africa/Nairobi')::date then raise exception 'invalid';end if;
 if p_kind='refund' and (coalesce(length(trim(p_reference)),0) not between 1 and 200 or not exists(select 1 from charm.finance_accounts where finance_accounts.id=p_account and active)) then raise exception 'invalid';end if;
 select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=p_id;
 select coalesce(sum(amount),0) into claimed from charm.finance_accountability where request_id=p_id and status in ('pending','accepted');
 if claimed+v>paid then raise exception 'overpayment';end if;
 insert into charm.finance_accountability(request_id,kind,amount,description,expense_date,reference,account_id,proof_id,submitted_by) values(p_id,p_kind,v,trim(p_description),coalesce(p_date,(now() at time zone 'Africa/Nairobi')::date),case when p_kind='refund' then trim(p_reference) end,case when p_kind='refund' then p_account end,p_proof,a) returning finance_accountability.id into id;
 perform charm.audit('accountabilitySubmitted','finance_requests',p_id,jsonb_build_object('submission_id',id,'amount',v,'kind',p_kind));perform charm.finance_notify(p_id,'accountabilitySubmitted','accountability:'||id,array['finance_officer']);return charm.finish(p_key,id);
end$$;
create or replace function charm.finance_review_accountability(p_id bigint,p_accept boolean,p_reason text,p_confirmed boolean default false) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();s charm.finance_accountability;r charm.finance_requests;paid numeric;settled numeric;begin
 perform charm.require_finance();select * into s from charm.finance_accountability where id=p_id;
 if s.id is null then raise exception 'notFound';end if;
 select * into r from charm.finance_requests where id=s.request_id for update;select * into s from charm.finance_accountability where id=p_id for update;
 if s.submitted_by=a then raise exception 'selfApproval';end if;
 if s.status<>'pending' or r.status='closed' or p_accept is null then raise exception 'financeLocked';end if;
 if not p_accept and coalesce(length(trim(p_reason)),0) not between 1 and 2000 then raise exception 'reasonRequired';end if;
 if p_accept then
  select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=r.id;
  select coalesce(sum(amount),0) into settled from charm.finance_accountability where request_id=r.id and status='accepted';
  if settled+s.amount>paid then raise exception 'overpayment';end if;
  if s.kind='refund' and p_confirmed is distinct from true then raise exception 'paymentConfirmationRequired';end if;
 end if;
 update charm.finance_accountability set status=case when p_accept then 'accepted' else 'returned' end,reviewed_by=a,reviewed_at=now(),reason=nullif(trim(p_reason),'') where id=p_id;
 if p_accept and s.kind='refund' then insert into charm.finance_ledger(request_id,account_id,direction,amount,kind,reference,occurred_at,recorded_by,accountability_id) values(r.id,s.account_id,'in',s.amount,'refund',s.reference,(s.expense_date::timestamp at time zone 'Africa/Nairobi'),a,s.id);end if;
 perform charm.audit('accountabilityReviewed','finance_requests',r.id,jsonb_build_object('submission_id',p_id,'accepted',p_accept,'reason',p_reason,'refund_confirmed',p_confirmed));perform charm.finance_notify(r.id,case when p_accept then 'accountabilityAccepted' else 'accountabilityReturned' end,'accountability-review:'||s.id);
end$$;
create or replace function charm.finance_close_request(p_id bigint,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;paid numeric;settled numeric;begin
 perform charm.require_finance();select * into r from charm.finance_requests where id=p_id for update;
 if r.id is null or r.status not in ('approved','part_paid','paid') then raise exception 'financeLocked';end if;
 if r.kind='staff' and a=r.owner_id then raise exception 'selfApproval';end if;
 if coalesce(length(trim(p_reason)),0) not between 1 and 2000 then raise exception 'reasonRequired';end if;
 select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=p_id;
 select coalesce(sum(amount),0) into settled from charm.finance_accountability where request_id=p_id and status='accepted';
 if (r.kind='staff' and paid<>settled) or exists(select 1 from charm.finance_accountability where request_id=p_id and status='pending') then raise exception 'advanceOutstanding';end if;
 update charm.finance_requests set status='closed',updated_at=now() where id=p_id;
 perform charm.audit('financeClosed','finance_requests',p_id,jsonb_build_object('reason',p_reason,'paid',paid,'settled',settled,'unpaid_approval',r.approved_amount-paid));perform charm.finance_notify(p_id,'financeClosed','closed:'||p_id,array['admin']);
end$$;
create or replace function charm.finance_mark_read(p_id bigint default null) returns void language plpgsql security definer set search_path='' as $$begin
 update charm.finance_notifications set read_at=coalesce(read_at,now()) where recipient_id=charm.require_actor() and (p_id is null or id=p_id);
end$$;
create or replace function charm.finance_bridge_expense() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.budget>0 then
 insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,status,source_expense_id,created_at)
 values(new.salesperson_id,'staff',(select id from charm.finance_categories where name='Other'),new.budget,new.notes,new.date,new.date+7,case when new.status='rejected' then 'rejected' else 'pending' end,new.id,coalesce(new.created_at,now())) on conflict(source_expense_id) do nothing;
 end if;return new;end$$;
create or replace function charm.finance_configure(p_key uuid,p_kind text,p_data jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;id bigint;v numeric;used numeric;r record;previous jsonb;begin
 perform charm.require_finance(true);old:=charm.claim(p_key,'finance_configure',jsonb_build_array(p_kind,p_data));if old is not null then return old;end if;
 if p_kind='category' then
  if coalesce(length(trim(p_data->>'name')),0) not between 1 and 120 then raise exception 'invalid';end if;
  insert into charm.finance_categories(name) values(trim(p_data->>'name')) returning finance_categories.id into id;
 elsif p_kind='account' then
  if coalesce(length(trim(p_data->>'name')),0) not between 1 and 120 or coalesce(p_data->>'method','') not in ('Cash','Bank','M-Pesa','Other') then raise exception 'invalid';end if;
  insert into charm.finance_accounts(name,method) values(trim(p_data->>'name'),p_data->>'method') returning finance_accounts.id into id;
 elsif p_kind='opening' then
  v:=charm.finance_money(p_data->>'amount');
  if coalesce(p_data->>'confirmed','')<>'true' or coalesce(length(trim(p_data->>'reference')),0) not between 1 and 200 then raise exception 'paymentConfirmationRequired';end if;
  perform 1 from charm.finance_accounts where finance_accounts.id=(p_data->>'account_id')::bigint and active for update;if not found then raise exception 'invalid';end if;
  insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by) values((p_data->>'account_id')::bigint,'in',v,'opening',trim(p_data->>'reference'),now(),a) returning finance_ledger.id into id;
 elsif p_kind='payee' then
  if coalesce(length(trim(p_data->>'name')),0) not between 1 and 200 or coalesce(length(trim(p_data->>'details')),0) not between 1 and 2000 then raise exception 'invalid';end if;
  if p_data->>'staff_id' is not null and not exists(select 1 from charm.users where users.id=(p_data->>'staff_id')::bigint and active) then raise exception 'staffInactive';end if;
  select to_jsonb(p) into previous from charm.finance_payees p where staff_id=(p_data->>'staff_id')::bigint;
  insert into charm.finance_payees(staff_id,name,details,verified_by) values((p_data->>'staff_id')::bigint,trim(p_data->>'name'),trim(p_data->>'details'),a)
  on conflict(staff_id) do update set name=excluded.name,details=excluded.details,verified_by=a,verified_at=now() returning finance_payees.id into id;
 elsif p_kind='budget' then
  if coalesce(p_data->>'amount','') !~ '^\d{1,10}(\.\d{1,2})?$' then raise exception 'invalidMoney';end if;v:=(p_data->>'amount')::numeric;
  if (p_data->>'month')::date is null or extract(day from (p_data->>'month')::date)<>1 then raise exception 'invalid';end if;
  select * into r from charm.finance_budgets where category_id=(p_data->>'category_id')::bigint and month=(p_data->>'month')::date for update;
  previous:=to_jsonb(r);
  used:=charm.finance_budget_committed(r.id);
  if v<used then raise exception 'budgetExceeded';end if;
  insert into charm.finance_budgets(category_id,month,amount,updated_by) values((p_data->>'category_id')::bigint,(p_data->>'month')::date,v,a)
  on conflict(category_id,month) do update set amount=v,updated_by=a,updated_at=now() returning finance_budgets.id into id;
 else raise exception 'invalid';end if;
 perform charm.audit('financeConfigured','finance_'||p_kind,id,jsonb_build_object('before',previous,'after',p_data));return charm.finish(p_key,id);
end$$;
create or replace function charm.finance_statement(p_key uuid,p_account bigint,p_reference text,p_direction text,p_amount text,p_date date) returns bigint language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();old bigint;id bigint;v numeric:=charm.finance_money(p_amount);begin
 perform charm.require_finance();old:=charm.claim(p_key,'finance_statement',jsonb_build_array(p_account,p_reference,p_direction,p_amount,p_date));if old is not null then return old;end if;
 if coalesce(length(trim(p_reference)),0) not between 1 and 200 or p_direction is null or p_direction not in ('in','out') or p_date is null or p_date>(now() at time zone 'Africa/Nairobi')::date then raise exception 'invalid';end if;
 if not exists(select 1 from charm.finance_accounts where finance_accounts.id=p_account and active) then raise exception 'invalid';end if;
 insert into charm.finance_statement_lines(account_id,reference,direction,amount,occurred_at,imported_by) values(p_account,trim(p_reference),p_direction,v,p_date,a) returning finance_statement_lines.id into id;
 perform charm.audit('statementImported','finance_statement_lines',id,jsonb_build_object('amount',v,'reference',p_reference));return charm.finish(p_key,id);
end$$;
create or replace function charm.finance_match_statement(p_id bigint,p_ledger bigint) returns void language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();s charm.finance_statement_lines;l charm.finance_ledger;effective_account bigint;begin
 perform charm.require_finance();select * into s from charm.finance_statement_lines where id=p_id for update;select * into l from charm.finance_ledger where id=p_ledger for update;
 if s.id is null or l.id is null or s.ledger_id is not null then raise exception 'financeLocked';end if;
 select account_id into effective_account from charm.finance_cashbook where id=p_ledger;
 if (effective_account is not null and s.account_id<>effective_account) or s.amount<>l.amount or s.direction<>l.direction or lower(trim(s.reference))<>lower(trim(l.reference)) or s.occurred_at<>(l.occurred_at at time zone 'Africa/Nairobi')::date then raise exception 'reconciliationMismatch';end if;
 update charm.finance_statement_lines set ledger_id=p_ledger,matched_by=a,matched_at=now() where id=p_id;
 perform charm.audit('statementMatched','finance_statement_lines',p_id,jsonb_build_object('ledger_id',p_ledger));
end$$;
create or replace function charm.finance_capture_customer_payment() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='verified' then
 insert into charm.finance_ledger(direction,amount,kind,reference,occurred_at,recorded_by,customer_payment_id) values('in',new.amount,'customer_receipt',new.reference,coalesce(new.received_at,now()),new.verified_by,new.id) on conflict(customer_payment_id) do nothing;
 end if;return new;end$$;
create or replace function charm.finance_verify_customer_receipt(p_id bigint,p_confirmed boolean,p_account bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();p charm.payments;o charm.orders;paid numeric;begin
 perform charm.require_finance();if p_confirmed is distinct from true then raise exception 'paymentConfirmationRequired';end if;
 if not exists(select 1 from charm.finance_accounts where id=p_account and active) then raise exception 'invalid';end if;
 select * into p from charm.payments where id=p_id;if p.id is null then raise exception 'notFound';end if;
 select * into o from charm.orders where id=p.order_id for update;select * into p from charm.payments where id=p_id for update;
 if p.submitted_by=a then raise exception 'selfApproval';end if;
 if p.status<>'pending' or o.status<>'confirmed' then raise exception 'financeLocked';end if;
 if p.proof_path is null or not exists(select 1 from storage.objects where bucket_id='charm-private' and name=p.proof_path) then raise exception 'proofRequired';end if;
 select coalesce(sum(amount),0) into paid from charm.payments where order_id=o.id and status='verified';if paid+p.amount>o.total then raise exception 'overpayment';end if;
 update charm.payments set status='verified',verified_by=a,verified_at=now(),updated_at=now() where id=p_id;
 -- The trigger first captures the receipt; an immutable allocation establishes its account.
 insert into charm.finance_receipt_allocations(payment_id,ledger_id,account_id,reference,confirmed_by)
 select p_id,id,p_account,p.reference,a from charm.finance_ledger where customer_payment_id=p_id;
 perform charm.audit('receiptConfirmed','payments',p_id,jsonb_build_object('account_id',p_account,'reference',p.reference,'amount',p.amount));
end$$;
create or replace function charm.finance_immutable() returns trigger language plpgsql set search_path='' as $$begin raise exception 'financeImmutable';end$$;
create or replace function charm.finance_file_access(p_path text,p_write boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare parts text[]:=string_to_array(p_path,'/');r charm.finance_requests;a bigint:=charm.actor();begin
 if a is null or p_path !~ '^requests/[0-9]+/(support|payment|receipt|refund)/[0-9]+/[a-f0-9-]{36}\.(pdf|jpg|png|webp)$' then return false;end if;
 select * into r from charm.finance_requests where id=parts[2]::bigint;
 if r.id is null then return false;end if;
 if not p_write then return charm.finance_access(r.id);end if;
 if parts[4]::bigint<>a then return false;end if;
 return (parts[3]='support' and r.owner_id=a and r.status in ('draft','returned'))
  or (parts[3]='payment' and charm.finance_operator() and (r.kind='supplier' or r.owner_id<>a) and r.status in ('approved','part_paid'))
  or (parts[3] in ('receipt','refund') and r.owner_id=a and r.kind='staff' and r.status in ('part_paid','paid'));
end$$;
create or replace function charm.finance_attach_document(p_id bigint,p_kind text,p_path text) returns bigint language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();id bigint;begin
 perform 1 from charm.finance_requests where finance_requests.id=p_id for update;
 if split_part(p_path,'/',2) is distinct from p_id::text or split_part(p_path,'/',3) is distinct from p_kind or not charm.finance_file_access(p_path,true) then raise exception 'forbidden';end if;
 if not exists(select 1 from storage.objects where bucket_id='charm-finance' and name=p_path) then raise exception 'proofRequired';end if;
 select finance_documents.id into id from charm.finance_documents where path=p_path;if id is not null then return id;end if;
 insert into charm.finance_documents(request_id,kind,path,uploaded_by) values(p_id,p_kind,p_path,a) returning finance_documents.id into id;
 perform charm.audit('financeDocument','finance_requests',p_id,jsonb_build_object('document_id',id,'kind',p_kind));return id;
end$$;
create or replace function charm.finance_metadata() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform charm.require_actor();return jsonb_build_object(
 'categories',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_categories c where active),
 'accounts',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('balance',(select coalesce(sum(case when direction='in' then amount else -amount end),0)::text from charm.finance_cashbook where account_id=c.id)) order by name),'[]') from charm.finance_accounts c where active and charm.finance_reader()),
 'refund_accounts',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_accounts c where active),
 'payees',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_payees c where staff_id=charm.actor() or charm.finance_reader()),
 'staff',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'active',active) order by name),'[]') from charm.users where charm.finance_reader()));
end$$;
create or replace function charm.finance_summary(p_from date,p_to date,p_owner bigint default null) returns jsonb language plpgsql stable security definer set search_path='' as $$declare a bigint:=charm.require_actor();result jsonb;begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 select jsonb_build_object('pending',count(*) filter(where status='pending'),'approved',coalesce(sum(approved_amount) filter(where status in ('approved','part_paid','paid','closed')),0)::text,'outstanding',coalesce(sum(outstanding),0)::text,'overdue',count(*) filter(where outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date),'expenses',coalesce(sum(spent),0)::text) into result from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and required_date between p_from and p_to;
 result:=result||jsonb_build_object('disbursed',(select coalesce(sum(d.amount),0)::text from charm.finance_disbursements d join charm.finance_requests r on r.id=d.request_id where (r.owner_id=a or charm.finance_reader()) and (p_owner is null or r.owner_id=p_owner) and (d.paid_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
 'cashflow',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select to_char(occurred_at at time zone 'Africa/Nairobi','YYYY-MM') as month,coalesce(sum(amount) filter(where direction='in'),0)::text incoming,coalesce(sum(amount) filter(where direction='out'),0)::text outgoing from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to and kind<>'opening' group by 1 order by 1)x),
 'categories',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select category_name,sum(amount)::text amount from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to group by category_name order by category_name)x),
 'expenses',(select coalesce(sum(amount),0)::text from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to),
 'outstanding',(select coalesce(sum(outstanding),0)::text from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner)),
 'overdue',(select count(*) from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date));return result;
end$$;
create or replace function charm.finance_register(p_view text,p_from date,p_to date,p_status text default '',p_owner bigint default null,p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_actor();rows jsonb;total bigint;begin
 if p_page is null or p_page<1 or p_page>10000 or p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 if p_view='requests' then
  select count(*) into total from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and required_date between p_from and p_to and (p_status='' or status=p_status);
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text,'approved_amount',approved_amount::text,'paid',paid::text,'spent',spent::text,'refunded',refunded::text,'outstanding',outstanding::text,'pending_accountability',pending_accountability::text)),'[]') into rows from(select * from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and required_date between p_from and p_to and (p_status='' or status=p_status) order by id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='cashbook' then
  select count(*) into total from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to order by id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='audit' and charm.finance_reader() then
  select count(*) into total from charm.audit_logs l where (l.entity like 'finance_%' or l.entity='payments') and (l.entity<>'finance_requests' or charm.finance_access(l.entity_id)) and (l.created_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_owner is null or (l.entity='finance_requests' and exists(select 1 from charm.finance_requests where id=l.entity_id and owner_id=p_owner)));
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from(select l.*,u.name actor_name from charm.audit_logs l join charm.users u on u.id=l.actor_id where (l.entity like 'finance_%' or l.entity='payments') and (l.entity<>'finance_requests' or charm.finance_access(l.entity_id)) and (l.created_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_owner is null or (l.entity='finance_requests' and exists(select 1 from charm.finance_requests where id=l.entity_id and owner_id=p_owner))) order by l.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='expenditure' then
  select count(*) into total from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to order by expense_date desc,id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='budgets' and charm.finance_reader() then
  select count(*) into total from charm.finance_budgets where month between date_trunc('month',p_from)::date and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from(select b.id,b.month,c.name category_name,b.amount::text amount,charm.finance_budget_committed(b.id)::text committed from charm.finance_budgets b join charm.finance_categories c on c.id=b.category_id where month between date_trunc('month',p_from)::date and p_to order by month desc,b.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='statements' and charm.finance_reader() then
  select count(*) into total from charm.finance_statement_lines where occurred_at between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.finance_statement_lines where occurred_at between p_from and p_to order by id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='receipts' and charm.finance_reader() then
  select count(*) into total from charm.payments where (received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or status=p_status);
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.payments where (received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or status=p_status) order by id desc limit 100 offset (p_page-1)*100)x;
 else raise exception 'forbidden';end if;
 return jsonb_build_object('rows',rows,'total',total);
end$$;
create or replace function charm.finance_detail(p_id bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$declare r jsonb;begin
 if not charm.finance_access(p_id) then raise exception 'forbidden';end if;
 select to_jsonb(x)||jsonb_build_object('amount',amount::text,'approved_amount',approved_amount::text,'paid',paid::text,'spent',spent::text,'refunded',refunded::text,'outstanding',outstanding::text,'pending_accountability',pending_accountability::text) into r from charm.finance_request_balances x where id=p_id;
 return jsonb_build_object('request',r,'documents',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from charm.finance_documents x where request_id=p_id),
 'payments',(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text) order by id),'[]') from charm.finance_disbursements x where request_id=p_id),
 'accountability',(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text) order by id),'[]') from charm.finance_accountability x where request_id=p_id),
 'history',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from(select l.id,l.actor_id,u.name actor_name,l.action,l.details,l.created_at from charm.audit_logs l join charm.users u on u.id=l.actor_id where (l.entity='finance_requests' and l.entity_id=p_id) or (l.entity='expenses' and l.entity_id=(select source_expense_id from charm.finance_requests where id=p_id)) order by l.id desc limit 200)x));
end$$;
create or replace function charm.update_staff(p_id bigint,p_name text,p_phone text,p_territory text,p_role text,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint; u charm.users; caller charm.users;
begin
 a:=charm.require_admin();
 perform pg_advisory_xact_lock(817201008);
 select * into caller from charm.users where id=a for update;
 if caller.role<>'admin' or not caller.active then raise exception 'forbidden'; end if;
 select * into u from charm.users where id=p_id for update;
 if not found then raise exception 'notFound'; end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(p_phone),0)>40 or coalesce(length(p_territory),0)>200 or p_role is null or p_role not in ('admin','salesperson','finance_officer') or p_active is null then raise exception 'invalid'; end if;
 if p_id=a and (p_role<>u.role or p_active<>u.active) then raise exception 'selfRoleChange'; end if;
 if u.role='admin' and u.active and (p_role<>'admin' or not p_active) and (select count(*) from charm.users where role='admin' and active)<=1 then raise exception 'lastAdmin'; end if;
 update charm.users set name=trim(p_name),phone=nullif(trim(p_phone),''),territory=nullif(trim(p_territory),''),role=p_role,active=p_active,updated_at=now() where id=p_id;
 perform charm.audit('staffUpdated','users',p_id,jsonb_build_object('before',jsonb_build_object('name',u.name,'phone',u.phone,'territory',u.territory,'role',u.role,'active',u.active),'after',jsonb_build_object('name',trim(p_name),'phone',p_phone,'territory',p_territory,'role',p_role,'active',p_active)));
end $$;
create or replace function charm.link_staff(p_actor uuid,p_auth uuid,p_email text,p_name text,p_role text) returns bigint language plpgsql security definer set search_path='' as $$
declare admin_id bigint; staff_id bigint; existing_auth uuid; canonical_email text;
begin
 perform pg_advisory_xact_lock(817201008);
 select u.id into admin_id from charm.auth_accounts a join charm.users u on u.id=a.salesperson_id where a.auth_user_id=p_actor and u.active and u.role='admin';
 if admin_id is null or p_actor=p_auth then raise exception 'forbidden'; end if;
 select email into canonical_email from auth.users where id=p_auth;
 if canonical_email is null or lower(canonical_email)<>lower(trim(p_email)) or p_role not in ('admin','salesperson','finance_officer') or coalesce(length(trim(p_name)),0) not between 1 and 200 then raise exception 'invalid'; end if;
 perform pg_advisory_xact_lock(hashtextextended(lower(trim(p_email)),1));
 if (select count(*) from charm.users where lower(email)=lower(trim(p_email)))>1 then raise exception 'duplicateConflict'; end if;
 select id into staff_id from charm.users where lower(email)=lower(trim(p_email)) for update;
 if staff_id=admin_id then raise exception 'forbidden'; end if;
 if staff_id is null then
  -- Unusable legacy password; Supabase reset/invite establishes the real credential.
  insert into charm.users(name,email,password,role,active,created_at,updated_at) values(p_name,lower(trim(p_email)),'!supabase-auth-only!',p_role,true,now(),now()) returning id into staff_id;
 end if;
 select auth_user_id into existing_auth from charm.auth_accounts where salesperson_id=staff_id;
 if existing_auth is not null and existing_auth<>p_auth then raise exception 'duplicateConflict'; end if;
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values(p_auth,staff_id) on conflict(auth_user_id) do nothing;
 if not exists(select 1 from charm.auth_accounts where auth_user_id=p_auth and salesperson_id=staff_id) then raise exception 'duplicateConflict'; end if;
 insert into charm.audit_logs(actor_id,action,entity,entity_id,details,created_at) values(admin_id,'invited','users',staff_id,jsonb_build_object('auth_user_id',p_auth),now());
 return staff_id;
end $$;
drop policy if exists finance_audit_read on charm.audit_logs;
drop policy if exists finance_audit_read on charm.audit_logs;
create policy finance_audit_read on charm.audit_logs for select to authenticated using(charm.finance_role()='finance_officer' and (entity like 'finance_%' or entity='payments'));
notify pgrst,'reload schema';

-- 202610130023_finance_work_queues.sql
-- Focused workflow queues; ownership, approval and payment controls remain unchanged.

create or replace function charm.finance_register(p_view text,p_from date,p_to date,p_status text default '',p_owner bigint default null,p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_actor();rows jsonb;total bigint;begin
 if p_page is null or p_page<1 or p_page>10000 or p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 if p_view='requests' then
  select count(*) into total from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and (p_status in ('awaiting_payment','partial_payments','needs_accountability','outstanding','overdue') or required_date between p_from and p_to) and (p_status='' or status=p_status
 or (p_status='awaiting_payment' and status in ('approved','part_paid'))
 or (p_status='partial_payments' and status='part_paid')
 or (p_status='needs_accountability' and status in ('part_paid','paid'))
 or (p_status='outstanding' and outstanding>0)
 or (p_status='overdue' and outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date));
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text,'approved_amount',approved_amount::text,'paid',paid::text,'spent',spent::text,'refunded',refunded::text,'outstanding',outstanding::text,'pending_accountability',pending_accountability::text)),'[]') into rows from(select * from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and (p_status in ('awaiting_payment','partial_payments','needs_accountability','outstanding','overdue') or required_date between p_from and p_to) and (p_status='' or status=p_status
 or (p_status='awaiting_payment' and status in ('approved','part_paid'))
 or (p_status='partial_payments' and status='part_paid')
 or (p_status='needs_accountability' and status in ('part_paid','paid'))
 or (p_status='outstanding' and outstanding>0)
 or (p_status='overdue' and outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date)) order by id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='cashbook' then
  select count(*) into total from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to order by id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='audit' and charm.finance_reader() then
  select count(*) into total from charm.audit_logs l where (l.entity like 'finance_%' or l.entity='payments') and (l.entity<>'finance_requests' or charm.finance_access(l.entity_id)) and (l.created_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_owner is null or (l.entity='finance_requests' and exists(select 1 from charm.finance_requests where id=l.entity_id and owner_id=p_owner)));
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from(select l.*,u.name actor_name from charm.audit_logs l join charm.users u on u.id=l.actor_id where (l.entity like 'finance_%' or l.entity='payments') and (l.entity<>'finance_requests' or charm.finance_access(l.entity_id)) and (l.created_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_owner is null or (l.entity='finance_requests' and exists(select 1 from charm.finance_requests where id=l.entity_id and owner_id=p_owner))) order by l.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='expenditure' then
  select count(*) into total from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to order by expense_date desc,id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='budgets' and charm.finance_reader() then
  select count(*) into total from charm.finance_budgets where month between date_trunc('month',p_from)::date and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from(select b.id,b.month,c.name category_name,b.amount::text amount,charm.finance_budget_committed(b.id)::text committed from charm.finance_budgets b join charm.finance_categories c on c.id=b.category_id where month between date_trunc('month',p_from)::date and p_to order by month desc,b.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='statements' and charm.finance_reader() then
  select count(*) into total from charm.finance_statement_lines where occurred_at between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.finance_statement_lines where occurred_at between p_from and p_to order by id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='receipts' and charm.finance_reader() then
  select count(*) into total from charm.payments where (received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or status=p_status);
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.payments where (received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or status=p_status) order by id desc limit 100 offset (p_page-1)*100)x;
 else raise exception 'forbidden';end if;
 return jsonb_build_object('rows',rows,'total',total);
end$$;
create or replace function charm.finance_work_queue_version() returns integer
language plpgsql stable security definer set search_path='' as $$
begin perform charm.require_actor();return 1;end$$;
revoke all on function charm.finance_work_queue_version() from public,anon,authenticated;
grant execute on function charm.finance_work_queue_version() to authenticated;
notify pgrst,'reload schema';

notify pgrst,'reload schema';
commit;

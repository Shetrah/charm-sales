-- Additive finance foundation. Review/apply after 009. No financial records are deleted.
begin;
do $$ declare c record; begin
 for c in select conname from pg_constraint where conrelid='charm.users'::regclass and contype='c' and pg_get_constraintdef(oid) like '%role%' loop
  execute format('alter table charm.users drop constraint %I',c.conname);
 end loop;
end $$;
alter table charm.users add constraint users_finance_roles check(role in ('salesperson','admin','finance_officer','finance_manager','management','auditor'));
create function charm.finance_role() returns text language sql stable security definer set search_path='' as $$select role::text from charm.users where id=charm.actor()$$;
create function charm.finance_reader() returns boolean language sql stable security definer set search_path='' as $$select coalesce(charm.finance_role() in ('admin','finance_officer','finance_manager','management','auditor'),false)$$;
create function charm.finance_operator() returns boolean language sql stable security definer set search_path='' as $$select coalesce(charm.finance_role() in ('finance_officer','finance_manager'),false)$$;
create function charm.require_finance(p_manager boolean default false) returns bigint language plpgsql stable security definer set search_path='' as $$begin
 if not charm.finance_operator() or (p_manager and charm.finance_role()<>'finance_manager') then raise exception 'forbidden'; end if; return charm.require_actor(); end$$;

create table charm.finance_categories(id bigserial primary key,name text unique not null check(length(name) between 1 and 120),active boolean not null default true);
-- Configuration labels, never sample transactions or balances.
insert into charm.finance_categories(name) values('Travel'),('Accommodation'),('Meals'),('Marketing'),('Office'),('Suppliers'),('Other');
create table charm.finance_accounts(id bigserial primary key,name text unique not null,method text not null check(method in ('Cash','Bank','M-Pesa','Other')),active boolean not null default true);
create table charm.finance_payees(id bigserial primary key,staff_id bigint unique references charm.users(id),name text not null,details text not null,verified_by bigint not null references charm.users(id),verified_at timestamptz not null default now());
create table charm.finance_budgets(id bigserial primary key,category_id bigint not null references charm.finance_categories(id),month date not null check(extract(day from month)=1),amount numeric(14,2) not null check(amount>=0),updated_by bigint not null references charm.users(id),updated_at timestamptz not null default now(),unique(category_id,month));
create table charm.finance_requests(
 id bigserial primary key,owner_id bigint not null references charm.users(id),kind text not null check(kind in ('staff','supplier')),
 payee_id bigint references charm.finance_payees(id),category_id bigint not null references charm.finance_categories(id),
 amount numeric(14,2) not null check(amount>0),approved_amount numeric(14,2) check(approved_amount>0 and approved_amount<=amount),
 purpose text not null check(length(purpose) between 1 and 10000),required_date date not null,accountability_due date not null,
 status text not null default 'draft' check(status in ('draft','pending','returned','rejected','approved','part_paid','paid','closed')),
 reason text,approved_by bigint references charm.users(id),approved_at timestamptz,budget_id bigint references charm.finance_budgets(id),
 source_expense_id bigint unique references charm.expenses(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table charm.finance_documents(id bigserial primary key,request_id bigint not null references charm.finance_requests(id),kind text not null check(kind in ('support','payment','receipt','refund')),path text unique not null,uploaded_by bigint not null references charm.users(id),created_at timestamptz not null default now());
create table charm.finance_disbursements(id bigserial primary key,request_id bigint not null references charm.finance_requests(id),account_id bigint not null references charm.finance_accounts(id),amount numeric(14,2) not null check(amount>0),reference text not null,paid_at timestamptz not null,payee_snapshot jsonb not null,proof_id bigint not null unique references charm.finance_documents(id),recorded_by bigint not null references charm.users(id),created_at timestamptz not null default now(),unique(account_id,reference));
create table charm.finance_accountability(id bigserial primary key,request_id bigint not null references charm.finance_requests(id),kind text not null check(kind in ('expense','refund')),amount numeric(14,2) not null check(amount>0),description text not null,expense_date date not null default ((now() at time zone 'Africa/Nairobi')::date),reference text,account_id bigint references charm.finance_accounts(id),proof_id bigint not null unique references charm.finance_documents(id),status text not null default 'pending' check(status in ('pending','accepted','returned')),submitted_by bigint not null references charm.users(id),reviewed_by bigint references charm.users(id),reason text,created_at timestamptz not null default now(),reviewed_at timestamptz);
create unique index finance_refund_reference on charm.finance_accountability(account_id,reference) where kind='refund' and status='accepted';
-- Append-only cash movements. Staff spending is recognized only after accountability review.
create table charm.finance_ledger(id bigserial primary key,request_id bigint references charm.finance_requests(id),account_id bigint references charm.finance_accounts(id),direction text not null check(direction in ('in','out')),amount numeric(14,2) not null check(amount>0),kind text not null check(kind in ('advance','supplier','refund','customer_receipt','opening')),reference text not null,occurred_at timestamptz not null,recorded_by bigint not null references charm.users(id),disbursement_id bigint unique references charm.finance_disbursements(id),accountability_id bigint unique references charm.finance_accountability(id),customer_payment_id bigint unique references charm.payments(id),created_at timestamptz not null default now());
create table charm.finance_receipt_allocations(payment_id bigint primary key references charm.payments(id),ledger_id bigint unique not null references charm.finance_ledger(id),account_id bigint not null references charm.finance_accounts(id),reference text not null,confirmed_by bigint not null references charm.users(id),confirmed_at timestamptz not null default now(),unique(account_id,reference));
create table charm.finance_statement_lines(id bigserial primary key,account_id bigint not null references charm.finance_accounts(id),reference text not null,direction text not null check(direction in ('in','out')),amount numeric(14,2) not null check(amount>0),occurred_at date not null,ledger_id bigint unique references charm.finance_ledger(id),imported_by bigint not null references charm.users(id),matched_by bigint references charm.users(id),matched_at timestamptz,unique(account_id,reference,direction));
create table charm.finance_notifications(id bigserial primary key,recipient_id bigint not null references charm.users(id),request_id bigint references charm.finance_requests(id),event text not null,event_key text not null,read_at timestamptz,created_at timestamptz not null default now(),unique(recipient_id,event_key));
create index finance_requests_owner on charm.finance_requests(owner_id,id desc);
create index finance_requests_queue on charm.finance_requests(status,required_date);
create index finance_ledger_date on charm.finance_ledger(occurred_at,id);
create index finance_disbursements_request on charm.finance_disbursements(request_id);
create index finance_accountability_request on charm.finance_accountability(request_id,status);
create index finance_notifications_recipient on charm.finance_notifications(recipient_id,id desc);
create function charm.finance_access(p_id bigint) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from charm.finance_requests where id=p_id and (owner_id=charm.actor() or (charm.finance_reader() and (charm.finance_role()<>'finance_officer' or status in ('approved','part_paid','paid','closed')))))$$;
do $$ declare t text; begin
 foreach t in array array['finance_categories','finance_accounts','finance_payees','finance_budgets','finance_requests','finance_documents','finance_disbursements','finance_accountability','finance_ledger','finance_receipt_allocations','finance_statement_lines','finance_notifications'] loop
  execute format('alter table charm.%I enable row level security',t);
  execute format('revoke all on charm.%I from public,anon,authenticated',t);
  execute format('grant select on charm.%I to authenticated',t);
 end loop;
end $$;
create policy finance_category_read on charm.finance_categories for select to authenticated using(charm.actor() is not null);
create policy finance_account_read on charm.finance_accounts for select to authenticated using(charm.actor() is not null);
create policy finance_payee_read on charm.finance_payees for select to authenticated using(staff_id=charm.actor() or charm.finance_reader());
create policy finance_budget_read on charm.finance_budgets for select to authenticated using(charm.finance_reader());
create policy finance_request_read on charm.finance_requests for select to authenticated using(charm.finance_access(id));
create policy finance_document_read on charm.finance_documents for select to authenticated using(charm.finance_access(request_id));
create policy finance_disbursement_read on charm.finance_disbursements for select to authenticated using(charm.finance_access(request_id));
create policy finance_accountability_read on charm.finance_accountability for select to authenticated using(charm.finance_access(request_id));
create policy finance_ledger_read on charm.finance_ledger for select to authenticated using(charm.finance_reader() or (request_id is not null and charm.finance_access(request_id)));
create policy finance_allocation_read on charm.finance_receipt_allocations for select to authenticated using(charm.finance_reader());
create policy finance_statement_read on charm.finance_statement_lines for select to authenticated using(charm.finance_reader());
create policy finance_notification_read on charm.finance_notifications for select to authenticated using(recipient_id=charm.actor());
-- Finance can read customer collections but receives no direct write privileges.
create policy finance_user_read on charm.users for select to authenticated using(charm.finance_reader());
create policy finance_client_read on charm.clients for select to authenticated using(charm.finance_reader());
create policy finance_order_read on charm.orders for select to authenticated using(charm.finance_reader());
create policy finance_payment_read on charm.payments for select to authenticated using(charm.finance_reader());
create policy finance_audit_read on charm.audit_logs for select to authenticated using(charm.finance_role() in ('finance_manager','management','auditor') and (entity like 'finance_%' or entity='payments'));
create function charm.finance_notify(p_request bigint,p_event text,p_key text,p_roles text[] default '{}',p_owner boolean default true) returns void language sql security definer set search_path='' as $$
 insert into charm.finance_notifications(recipient_id,request_id,event,event_key)
 select u.id,p_request,p_event,p_key from charm.users u where u.active and (u.role=any(p_roles) or (p_owner and u.id=(select owner_id from charm.finance_requests where id=p_request))) on conflict do nothing
$$;
-- Fresh role check on every write; role changes serialize with staff management.
create function charm.finance_lock_actor() returns bigint language plpgsql security definer set search_path='' as $$declare a bigint:=charm.require_actor();begin
 perform pg_advisory_xact_lock(817201008);perform 1 from charm.users where id=a for update;
 if charm.actor() is null then raise exception 'unauthorized'; end if;return a;end$$;
revoke execute on function charm.finance_role(),charm.finance_reader(),charm.finance_operator(),charm.require_finance(boolean),charm.finance_access(bigint),charm.finance_notify(bigint,text,text,text[],boolean),charm.finance_lock_actor() from public,anon,authenticated;
grant execute on function charm.finance_role(),charm.finance_reader(),charm.finance_operator(),charm.finance_access(bigint) to authenticated;
commit;

-- One expense, one identity. The financial request becomes the single company expense header so that
-- expenditure, payments and cash movements describe the same record instead of competing copies of it.
begin;

-- Departments are configurable master data, not free text, so breakdowns group reliably.
create table charm.finance_departments(id bigserial primary key,name text unique not null check(length(trim(name)) between 1 and 120),active boolean not null default true);
insert into charm.finance_departments(name) values('Sales'),('Logistics'),('Production'),('Administration'),('Finance'),('Management') on conflict(name) do nothing;

-- Expense categories the company actually spends against. The seven original names are untouched, so
-- historical requests, budgets and reports keep their meaning.
insert into charm.finance_categories(name) values
 ('Salaries and Wages'),('Staff Welfare'),('Rent and Premises'),('Electricity and Water'),('Internet and Communication'),
 ('Transport and Fuel'),('Vehicle Maintenance'),('Office Supplies'),('Stationery'),('Repairs and Maintenance'),
 ('Cleaning and Sanitation'),('Production Expenses'),('Raw Materials and Chemicals'),('Packaging Materials'),
 ('Laboratory Expenses'),('Professional Services'),('Bank Charges'),('Licences and Permits'),
 ('Taxes and Statutory Payments'),('Security'),('Insurance'),('Miscellaneous Expenses')
on conflict(name) do nothing;

alter table charm.finance_requests
 add column if not exists expense_number text unique,
 add column if not exists department_id bigint references charm.finance_departments(id),
 add column if not exists expense_on date,
 add column if not exists payment_method text,
 add column if not exists order_id bigint references charm.orders(id),
 add column if not exists recipient text,
 add column if not exists source_type text,
 add column if not exists source_id bigint,
 add column if not exists recorded_by bigint references charm.users(id);

-- A direct company expense has no advance to settle and no supplier bill to match, so it needs its own kind.
do $$ declare c record; begin
 for c in select conname from pg_constraint where conrelid='charm.finance_requests'::regclass and contype='c' and pg_get_constraintdef(oid) like '%kind%' loop
  execute format('alter table charm.finance_requests drop constraint %I',c.conname);
 end loop;
end $$;
alter table charm.finance_requests add constraint finance_requests_kind_check check(kind in ('staff','supplier','expense'));
alter table charm.finance_requests add constraint finance_requests_payment_method_check check(payment_method is null or payment_method in ('Cash','Bank','M-Pesa','Cheque','Other'));
alter table charm.finance_requests add constraint finance_requests_source_type_check check(source_type is null or source_type in ('travel','commission','supplier_invoice','purchase_order','batch_cost','operating','manual'));

-- The double-count guard: one expense record per originating business event, enforced by the database.
create unique index finance_request_source on charm.finance_requests(source_type,source_id) where source_id is not null;
create index finance_requests_expense_on on charm.finance_requests(expense_on,id desc);
create index finance_requests_department on charm.finance_requests(department_id,expense_on);

-- Line items give the officer a multi-item expense form without letting item totals compete with the
-- header amount: only the header is ever summed into a company figure.
create table charm.finance_expense_items(
 id bigserial primary key,request_id bigint not null references charm.finance_requests(id) on delete cascade,
 description text not null check(length(trim(description)) between 1 and 300),
 quantity numeric(14,4) not null default 1 check(quantity>0),unit_price numeric(14,2) not null check(unit_price>=0),
 discount numeric(14,2) not null default 0 check(discount>=0),tax numeric(14,2) not null default 0 check(tax>=0),
 line_total numeric(14,2) not null check(line_total>=0),sort integer not null default 0,
 created_at timestamptz not null default now()
);
create index finance_expense_items_request on charm.finance_expense_items(request_id,id);

-- Legacy revenue/expense postings can now be attached to the expense they belong to.
alter table charm.finance_operating_entries add column if not exists request_id bigint references charm.finance_requests(id);

-- Human-readable expense numbers, Nairobi-dated, from their own sequence.
create sequence charm.finance_expense_seq;
create function charm.finance_expense_number() returns trigger language plpgsql set search_path='' as $$begin
 if coalesce(trim(new.expense_number),'')='' then
  new.expense_number:='EXP-'||to_char(now() at time zone 'Africa/Nairobi','YYYYMMDD')||'-'||lpad(nextval('charm.finance_expense_seq')::text,5,'0');
 end if;return new;end$$;
create trigger finance_expense_number_assign before insert on charm.finance_requests for each row execute function charm.finance_expense_number();

-- Backfill existing records so every expense has a number, a date and an owner from day one.
update charm.finance_requests set
 expense_number='EXP-'||to_char(created_at at time zone 'Africa/Nairobi','YYYYMMDD')||'-'||lpad(id::text,5,'0'),
 expense_on=required_date,
 recorded_by=owner_id
 where expense_number is null;
-- Fresh installs have no rows, and setval rejects zero; seed from the highest existing id only when there is one.
do $$ declare v bigint; begin
 select coalesce(max(id),0) into v from charm.finance_requests;
 if v>0 then perform setval('charm.finance_expense_seq',v); else perform setval('charm.finance_expense_seq',1,false); end if;
end $$;

-- Adopt the source links that already existed in another form.
update charm.finance_requests set source_type='travel',source_id=source_expense_id where source_expense_id is not null and source_id is null;
update charm.finance_requests r set source_type='supplier_invoice',source_id=i.invoice_id
 from (select request_id,min(id) invoice_id,count(*) n from charm.finance_supplier_invoices where request_id is not null group by 1)i
 where i.n=1 and i.request_id=r.id and r.source_id is null;

-- The balances view expands finance_requests with r.*, so PostgreSQL refuses to replace it once the table
-- widens. Rebuilding it with the identical text carries the new expense identity into every register.
drop view if exists charm.finance_request_balances;
create view charm.finance_request_balances with(security_invoker=true) as
 select r.*,u.name owner_name,c.name category_name,
 coalesce(d.paid,0)::numeric(14,2) paid,coalesce(e.spent,0)::numeric(14,2) spent,coalesce(e.refunded,0)::numeric(14,2) refunded,
 (case when r.kind='staff' then coalesce(d.paid,0)-coalesce(e.spent,0)-coalesce(e.refunded,0) else 0 end)::numeric(14,2) outstanding,
 coalesce(e.pending,0)::numeric(14,2) pending_accountability
 from charm.finance_requests r join charm.users u on u.id=r.owner_id join charm.finance_categories c on c.id=r.category_id
 left join lateral(select sum(amount) paid from charm.finance_disbursements where request_id=r.id)d on true
 left join lateral(select sum(amount) filter(where status='accepted' and kind='expense') spent,sum(amount) filter(where status='accepted' and kind='refund') refunded,sum(amount) filter(where status='pending') pending from charm.finance_accountability where request_id=r.id)e on true;
grant select on charm.finance_request_balances to authenticated;

do $$ declare t text; begin
 foreach t in array array['finance_departments','finance_expense_items'] loop
  execute format('alter table charm.%I enable row level security',t);
  execute format('revoke all on charm.%I from public,anon,authenticated',t);
  execute format('grant select on charm.%I to authenticated',t);
 end loop;
end $$;
grant usage on schema charm to authenticated;
grant usage,select on sequence charm.finance_departments_id_seq to authenticated;
create policy finance_department_read on charm.finance_departments for select to authenticated using(charm.actor() is not null);
create policy finance_expense_item_read on charm.finance_expense_items for select to authenticated using(charm.finance_access(request_id));
revoke execute on function charm.finance_expense_number() from public,anon,authenticated;
commit;

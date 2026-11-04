-- Charm Company Hub 2.2.0: balanced contra transfers between company-owned accounts.
-- Run once in Supabase SQL Editor after the previously deployed Charm migrations.
-- Additive only: existing records remain intact. Transfer posting is atomic and append-only.
begin;

do $$ declare c record; begin
 for c in select conname from pg_constraint where conrelid='charm.finance_ledger'::regclass and contype='c' and pg_get_constraintdef(oid) like '%kind%' loop
  execute format('alter table charm.finance_ledger drop constraint %I',c.conname);
 end loop;
end $$;
alter table charm.finance_ledger add constraint finance_ledger_kind_check
 check(kind in ('advance','supplier','refund','customer_receipt','opening','expense','contra_transfer'));

create table if not exists charm.finance_account_transfers(
 id bigserial primary key,
 source_account_id bigint not null references charm.finance_accounts(id),
 destination_account_id bigint not null references charm.finance_accounts(id),
 amount numeric(14,2) not null check(amount>0),
 occurred_on date not null check(occurred_on>='2020-01-01'::date),
 reference text not null check(length(trim(reference)) between 1 and 200),
 description text not null check(length(trim(description)) between 1 and 2000),
 created_by bigint not null references charm.users(id),
 created_at timestamptz not null default now(),
 check(source_account_id<>destination_account_id)
);
create unique index if not exists finance_account_transfers_reference_uq
 on charm.finance_account_transfers(lower(trim(reference)));
create index if not exists finance_account_transfers_date_idx
 on charm.finance_account_transfers(occurred_on desc,id desc);

alter table charm.finance_account_transfers enable row level security;
revoke all on charm.finance_account_transfers from public,anon,authenticated;
grant select on charm.finance_account_transfers to authenticated;
drop policy if exists finance_account_transfers_read on charm.finance_account_transfers;
create policy finance_account_transfers_read on charm.finance_account_transfers
 for select to authenticated using(charm.finance_reader());
drop trigger if exists immutable_finance_account_transfers on charm.finance_account_transfers;
create trigger immutable_finance_account_transfers
 before update or delete on charm.finance_account_transfers
 for each row execute function charm.finance_immutable();

create or replace function charm.finance_transfer_accounts(
 p_key uuid,p_source bigint,p_destination bigint,p_amount text,p_date date,p_reference text,p_description text
) returns bigint language plpgsql security definer set search_path='' as $$
declare
 a bigint:=charm.finance_lock_actor();
 old bigint;
 v numeric;
 balance numeric;
 account_count integer;
 transfer_id bigint;
 ref text:=trim(coalesce(p_reference,''));
 details text:=trim(coalesce(p_description,''));
begin
 perform charm.require_finance();
 old:=charm.claim(p_key,'finance_transfer_accounts',jsonb_build_array(p_source,p_destination,p_amount,p_date,ref,details));
 if old is not null then return old; end if;
 v:=charm.finance_money(p_amount);
 if p_source is null or p_destination is null or p_source=p_destination
   or p_date is null or p_date<'2020-01-01'::date
   or p_date>(now() at time zone 'Africa/Nairobi')::date
   or length(ref) not between 1 and 200 or length(details) not between 1 and 2000 then
  raise exception 'invalid';
 end if;
 -- Lock both accounts in ID order so concurrent transfers cannot deadlock or overspend.
 perform id from charm.finance_accounts
  where id in (p_source,p_destination) and active order by id for update;
 select count(*) into account_count from charm.finance_accounts
  where id in (p_source,p_destination) and active;
 if account_count<>2 then raise exception 'invalid'; end if;
 if exists(select 1 from charm.finance_account_transfers where lower(trim(reference))=lower(ref)) then
  raise exception 'duplicateReference';
 end if;
 select coalesce(sum(case when direction='in' then amount else -amount end),0)
  into balance from charm.finance_ledger where account_id=p_source;
 if balance<v then raise exception 'insufficientFunds'; end if;
 insert into charm.finance_account_transfers(source_account_id,destination_account_id,amount,occurred_on,reference,description,created_by)
  values(p_source,p_destination,v,p_date,ref,details,a) returning id into transfer_id;
 -- The source debit and destination credit commit or roll back together.
 insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by)
  values
   (p_source,'out',v,'contra_transfer',ref,p_date::timestamp at time zone 'Africa/Nairobi',a),
   (p_destination,'in',v,'contra_transfer',ref,p_date::timestamp at time zone 'Africa/Nairobi',a);
 perform charm.audit('financeContraTransfer','finance_account_transfers',transfer_id,
  jsonb_build_object('source_account_id',p_source,'destination_account_id',p_destination,
   'amount',v::text,'occurred_on',p_date,'reference',ref));
 return charm.finish(p_key,transfer_id);
end$$;

create or replace function charm.finance_contra_register(p_from date,p_to date,p_page integer default 1)
 returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_finance(); rows jsonb; total bigint;
begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660
   or p_page is null or p_page<1 or p_page>10000 then raise exception 'invalid'; end if;
 select count(*) into total from charm.finance_account_transfers t
  where t.occurred_on between p_from and p_to;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into rows from(
  select t.id,t.occurred_on,t.amount::text amount,t.reference,t.description,
   src.name source_name,dst.name destination_name,u.name actor_name
  from charm.finance_account_transfers t
  join charm.finance_accounts src on src.id=t.source_account_id
  join charm.finance_accounts dst on dst.id=t.destination_account_id
  join charm.users u on u.id=t.created_by
  where t.occurred_on between p_from and p_to
  order by t.occurred_on desc,t.id desc limit 100 offset (p_page-1)*100
 )x;
 return jsonb_build_object('rows',rows,'total',total);
end$$;

create or replace function charm.finance_summary(p_from date,p_to date,p_owner bigint default null) returns jsonb language plpgsql stable security definer set search_path='' as $$declare a bigint:=charm.require_actor();result jsonb;begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 select jsonb_build_object('pending',count(*) filter(where status='pending'),'approved',coalesce(sum(approved_amount) filter(where status in ('approved','part_paid','paid','closed')),0)::text,'outstanding',coalesce(sum(outstanding),0)::text,'overdue',count(*) filter(where outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date)) into result from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and required_date between p_from and p_to;
 result:=result||jsonb_build_object(
  'disbursed',(select coalesce(sum(d.amount),0)::text from charm.finance_disbursements d join charm.finance_requests r on r.id=d.request_id where (r.owner_id=a or charm.finance_reader()) and (p_owner is null or r.owner_id=p_owner) and (d.paid_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
  'cashflow',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select to_char(occurred_at at time zone 'Africa/Nairobi','YYYY-MM') as month,coalesce(sum(amount) filter(where direction='in'),0)::text incoming,coalesce(sum(amount) filter(where direction='out'),0)::text outgoing from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to and kind not in ('opening','contra_transfer') group by 1 order by 1)x),
  'expenses',(select coalesce(sum(amount),0)::text from charm.finance_expense_lines where classification='expense' and (charm.finance_reader() or request_id is not null and charm.finance_access(request_id)) and (p_owner is null or owner_id=p_owner) and expense_on between p_from and p_to),
  'categories',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select category_name,sum(amount)::text amount from charm.finance_expense_lines where classification='expense' and (charm.finance_reader() or request_id is not null and charm.finance_access(request_id)) and (p_owner is null or owner_id=p_owner) and expense_on between p_from and p_to group by category_name order by category_name)x),
  'outstanding',(select coalesce(sum(outstanding),0)::text from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner)),
  'overdue',(select count(*) from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date));return result;
end$$;

create or replace function charm.finance_expense_totals(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_finance();today date:=(now() at time zone 'Africa/Nairobi')::date;week_start date;result jsonb;
begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 week_start:=today-(extract(isodow from today)::int-1);
 select jsonb_build_object(
  'today',coalesce(sum(amount) filter(where classification='expense' and expense_on=today),0)::text,
  'week',coalesce(sum(amount) filter(where classification='expense' and expense_on between week_start and today),0)::text,
  'month',coalesce(sum(amount) filter(where classification='expense' and expense_on between date_trunc('month',today)::date and today),0)::text,
  'year',coalesce(sum(amount) filter(where classification='expense' and extract(year from expense_on)=extract(year from today)),0)::text,
  'period',coalesce(sum(amount) filter(where classification='expense' and expense_on between p_from and p_to),0)::text,
  'costOfSales',coalesce(sum(amount) filter(where classification='cost_of_sales' and expense_on between p_from and p_to),0)::text,
  'advances',coalesce(sum(amount) filter(where classification='advance' and expense_on between p_from and p_to),0)::text,
  'committed',coalesce(sum(amount) filter(where classification='committed' and expense_on between p_from and p_to),0)::text,
  'unpaid',coalesce(sum(outstanding) filter(where classification in ('expense','committed') and expense_on between p_from and p_to),0)::text,
  'paidAmount',coalesce(sum(amount) filter(where classification='expense' and payment_status='paid' and expense_on between p_from and p_to),0)::text,
  'records',count(*) filter(where classification='expense' and expense_on between p_from and p_to))
 into result from charm.finance_expense_lines;
 result:=result||jsonb_build_object(
  'categories',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select category_name,sum(amount)::text amount from charm.finance_expense_lines where classification='expense' and expense_on between p_from and p_to group by category_name order by category_name)x),
  'departments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select coalesce(department_name,'Unassigned') department_name,sum(amount)::text amount from charm.finance_expense_lines where classification='expense' and expense_on between p_from and p_to group by 1 order by 1)x),
  'sources',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select classification,sum(amount)::text amount from charm.finance_expense_lines where expense_on between p_from and p_to group by 1 order by 1)x),
  'trend',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select to_char(expense_on,'YYYY-MM') as month,sum(amount)::text amount from charm.finance_expense_lines where classification='expense' and expense_on between p_from and p_to group by 1 order by 1)x),
  'pending',coalesce((select jsonb_build_object('count',count(*),'amount',coalesce(sum(amount),0)::text) from charm.finance_requests where status='pending' and required_date between p_from and p_to),'{"count":0,"amount":"0"}'),
  'approved',coalesce((select jsonb_build_object('count',count(*),'amount',coalesce(sum(approved_amount),0)::text) from charm.finance_requests where status='approved' and required_date between p_from and p_to),'{"count":0,"amount":"0"}'),
  'settled',coalesce((select jsonb_build_object('count',count(*),'amount',coalesce(sum(approved_amount),0)::text) from charm.finance_requests where status in ('part_paid','paid','closed') and required_date between p_from and p_to),'{"count":0,"amount":"0"}'),
  'cashOut',(select coalesce(sum(amount),0)::text from charm.finance_cashbook where direction='out' and kind not in ('opening','contra_transfer') and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
  'cashIn',(select coalesce(sum(amount),0)::text from charm.finance_cashbook where direction='in' and kind not in ('opening','contra_transfer') and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
  'balance',(select coalesce(sum(case when direction='in' then amount else -amount end),0)::text from charm.finance_cashbook),
  'receivable',(select coalesce(sum(balance),0)::text from charm.order_balances where balance>0),
  'payable',(select coalesce(sum(outstanding),0)::text from charm.finance_request_balances where kind='supplier' and outstanding>0));
 -- Every confirmed payment out of an account falls into exactly one of these four classes, so the buckets
 -- below always add back up to cashOut. That is the reconciliation the officer can trust.
 return result||jsonb_build_object('cashOutByKind',
  jsonb_build_object('advance','0','supplier','0','purchase','0','expense','0')||coalesce((select jsonb_object_agg(k,v::text) from(
   select case when l.kind='advance' then 'advance'
    when l.kind='expense' then 'expense'
    when exists(select 1 from charm.finance_supplier_invoices si where si.request_id=l.request_id and si.po_id is not null) then 'purchase'
    else 'supplier' end k,sum(l.amount) v from charm.finance_cashbook l
   where l.direction='out' and l.kind not in ('opening','contra_transfer') and (l.occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to
   group by 1)x),'{}'));
end$$;

revoke all on function charm.finance_transfer_accounts(uuid,bigint,bigint,text,date,text,text) from public,anon,authenticated;
grant execute on function charm.finance_transfer_accounts(uuid,bigint,bigint,text,date,text,text) to authenticated;
revoke all on function charm.finance_contra_register(date,date,integer) from public,anon,authenticated;
grant execute on function charm.finance_contra_register(date,date,integer) to authenticated;
notify pgrst,'reload schema';
commit;

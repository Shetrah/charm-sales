begin;

-- Store the selected expense subcategory alongside the existing operational /
-- financial classification so reports retain both levels.
alter table charm.finance_operating_entries
 add column if not exists subcategory text;

create or replace function charm.finance_record_operating_entry(
 p_direction text,p_category text,p_amount numeric,p_date date,p_description text,p_reference text,
 p_account bigint default null,p_subcategory text default null
) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();entry_id bigint;req bigint;cat bigint;sub text:=nullif(trim(coalesce(p_subcategory,'')),'');
begin
 if not charm.finance_operator() or p_direction not in ('revenue','expense') or p_category not in ('operational','financial','other','sales','tax','duty') or p_amount<=0 or p_date is null or coalesce(length(trim(p_description)),0) not between 1 and 2000 or coalesce(length(trim(p_reference)),0) not between 1 and 200 then raise exception 'invalid';end if;
 if p_direction='expense' and p_category in ('operational','financial') and (sub is null or length(sub)>120) then raise exception 'invalid';end if;
 if sub is not null and (p_category not in ('operational','financial') or length(sub)>120) then raise exception 'invalid';end if;
 insert into charm.finance_operating_entries(direction,category,subcategory,amount,occurred_on,description,reference,account_id,created_by) values(p_direction,p_category,sub,p_amount,p_date,trim(p_description),trim(p_reference),p_account,a) returning finance_operating_entries.id into entry_id;
 if p_account is not null then insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by) values(p_account,case when p_direction='revenue' then 'in' else 'out' end, p_amount,case when p_direction='revenue' then 'customer_receipt' else 'expense' end,trim(p_reference),p_date::timestamp at time zone 'Africa/Nairobi',a);end if;
 if p_direction='expense' then
  select id into cat from charm.finance_categories where name='Miscellaneous Expenses' and active;
  if cat is null then select id into cat from charm.finance_categories where name='Other' and active;end if;
  insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,expense_on,recorded_by,source_type,source_id,status,approved_amount,approved_by,approved_at)
  values(a,'expense',cat,p_amount,trim(p_description)||case when sub is null then '' else ' · '||p_category||' / '||sub end,p_date,p_date+7,p_date,a,'operating',entry_id,
   case when p_account is not null then 'paid' else 'pending' end,case when p_account is not null then p_amount end,case when p_account is not null then a end,case when p_account is not null then now() end)
  on conflict(source_type,source_id) where source_id is not null do nothing returning finance_requests.id into req;
  if req is null then select request_id into req from charm.finance_requests where source_type='operating' and source_id=entry_id;end if;
  update charm.finance_operating_entries set request_id=req where finance_operating_entries.id=entry_id;
  if p_account is null then perform charm.finance_notify(req,'expenseSubmitted','operating-expense:'||entry_id,array['admin'],false);end if;
 end if;
 perform charm.audit('operatingEntryRecorded','finance_operating_entries',entry_id,jsonb_build_object('direction',p_direction,'category',p_category,'subcategory',sub,'amount',p_amount,'reference',p_reference,'request_id',req));return entry_id;
end$$;

-- Travel request payouts are expenses. A cash advance remains a separately
-- created staff request, never an automatic interpretation of travel funding.
create or replace function charm.travel_finance_request(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare e charm.expenses;cid bigint;req bigint;day date;
begin
 select * into e from charm.expenses where expenses.id=p_id;
 if not found or not e.advance_required or coalesce(e.total_estimated,0)<=0 then return;end if;
 select id into cid from charm.finance_categories where name='Travel' and active limit 1;
 if cid is null then select id into cid from charm.finance_categories where active order by id limit 1;end if;
 if cid is null then return;end if;
 day:=coalesce((e.depart_at at time zone 'Africa/Nairobi')::date,(now() at time zone 'Africa/Nairobi')::date);
 insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,expense_on,recorded_by,source_type,source_id,status,source_expense_id,created_at,updated_at)
 values(e.salesperson_id,'expense',cid,e.total_estimated,coalesce(e.purpose,'Travel expense'),day,day+7,day,e.salesperson_id,'travel',e.id,'pending',e.id,now(),now())
 on conflict(source_type,source_id) where source_id is not null do nothing;
end$$;

-- finance_requests is immutable after creation. Historical travel classification is
-- corrected in finance_expense_totals below without rewriting protected rows.

-- Source chart: any historical advance row tied to a travel request is reported
-- as expense. Standalone staff advances remain classified as advances.
create or replace function charm.finance_expense_totals(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 select jsonb_build_object(
  'today',coalesce(sum(amount) filter(where classification='expense' and expense_on=(now() at time zone 'Africa/Nairobi')::date),0)::text,
  'week',coalesce(sum(amount) filter(where classification='expense' and expense_on between (now() at time zone 'Africa/Nairobi')::date-(extract(isodow from (now() at time zone 'Africa/Nairobi')::date)::int-1) and (now() at time zone 'Africa/Nairobi')::date),0)::text,
  'month',coalesce(sum(amount) filter(where classification='expense' and expense_on between date_trunc('month',(now() at time zone 'Africa/Nairobi')::date)::date and (now() at time zone 'Africa/Nairobi')::date),0)::text,
  'year',coalesce(sum(amount) filter(where classification='expense' and extract(year from expense_on)=extract(year from (now() at time zone 'Africa/Nairobi')::date)),0)::text,
  'period',coalesce(sum(amount) filter(where classification='expense' and expense_on between p_from and p_to),0)::text,
  'costOfSales',coalesce(sum(amount) filter(where classification='cost_of_sales' and expense_on between p_from and p_to),0)::text,
  'advances',coalesce(sum(amount) filter(where classification='advance' and expense_on between p_from and p_to and source_type is distinct from 'travel' and not exists(select 1 from charm.finance_requests tr where tr.id=fl.source_id and tr.source_expense_id is not null)),0)::text,
  'committed',coalesce(sum(amount) filter(where classification='committed' and expense_on between p_from and p_to),0)::text,
  'unpaid',coalesce(sum(outstanding) filter(where classification in ('expense','committed') and expense_on between p_from and p_to),0)::text,
  'paidAmount',coalesce(sum(amount) filter(where classification='expense' and payment_status='paid' and expense_on between p_from and p_to),0)::text,
  'records',count(*) filter(where classification='expense' and expense_on between p_from and p_to))
 into result from charm.finance_expense_lines fl;
 result:=result||jsonb_build_object(
  'categories',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select category_name,sum(amount)::text amount from charm.finance_expense_lines where classification='expense' and expense_on between p_from and p_to group by category_name order by category_name)x),
  'departments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select coalesce(department_name,'Unassigned') department_name,sum(amount)::text amount from charm.finance_expense_lines where classification='expense' and expense_on between p_from and p_to group by 1 order by 1)x),
  'sources',(select coalesce(jsonb_agg(to_jsonb(x) order by classification),'[]') from(
   select case when source_type='travel' or source_type='advance' and exists(select 1 from charm.finance_requests tr where tr.id=fl.source_id and tr.source_expense_id is not null) then 'expense' else classification end classification,
    sum(amount)::text amount from charm.finance_expense_lines fl where expense_on between p_from and p_to
   group by 1)x),
  'trend',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select to_char(expense_on,'YYYY-MM') as "month",sum(amount)::text amount from charm.finance_expense_lines where classification='expense' and expense_on between p_from and p_to group by 1 order by 1)x),
  'pending',coalesce((select jsonb_build_object('count',count(*),'amount',coalesce(sum(amount),0)::text) from charm.finance_requests where status='pending' and required_date between p_from and p_to),'{"count":0,"amount":"0"}'),
  'approved',coalesce((select jsonb_build_object('count',count(*),'amount',coalesce(sum(approved_amount),0)::text) from charm.finance_requests where status='approved' and required_date between p_from and p_to),'{"count":0,"amount":"0"}'),
  'settled',coalesce((select jsonb_build_object('count',count(*),'amount',coalesce(sum(approved_amount),0)::text) from charm.finance_requests where status in ('part_paid','paid','closed') and required_date between p_from and p_to),'{"count":0,"amount":"0"}'),
  'cashOut',(select coalesce(sum(amount),0)::text from charm.finance_cashbook where direction='out' and kind<>'opening' and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
  'cashIn',(select coalesce(sum(amount),0)::text from charm.finance_cashbook where direction='in' and kind<>'opening' and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
  'balance',(select coalesce(sum(case when direction='in' then amount else -amount end),0)::text from charm.finance_cashbook),
  'receivable',(select coalesce(sum(balance),0)::text from charm.order_balances where balance>0),
  'payable',(select coalesce(sum(outstanding),0)::text from charm.finance_request_balances where kind='supplier' and outstanding>0));
 return result||jsonb_build_object('cashOutByKind',jsonb_build_object('advance','0','supplier','0','purchase','0','expense','0')||coalesce((select jsonb_object_agg(k,v::text) from(
  select case when l.kind='advance' and r.source_expense_id is not null then 'expense' when l.kind='advance' then 'advance' when l.kind='expense' then 'expense'
   when exists(select 1 from charm.finance_supplier_invoices si where si.request_id=l.request_id and si.po_id is not null) then 'purchase' else 'supplier' end k,sum(l.amount) v
  from charm.finance_cashbook l left join charm.finance_requests r on r.id=l.request_id
  where l.direction='out' and l.kind<>'opening' and (l.occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to group by 1)x),'{}'));
end$$;
revoke execute on function charm.finance_expense_totals(date,date) from public,anon;
grant execute on function charm.finance_expense_totals(date,date) to authenticated;
-- finance_ledger is immutable by design; the totals function above maps its
-- travel-linked advance movements into the Expense bucket without rewriting
-- the original audit rows.

notify pgrst,'reload schema';
commit;

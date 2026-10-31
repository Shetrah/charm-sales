-- The company-wide expense report. One classified register reads every spend source, so a figure entered
-- once is counted once: advances, purchases and payables stay in their own class instead of inflating expenses.
begin;

-- Classification key:
--   expense         recognised operating expenditure (approved company expenses, accepted staff receipts,
--                   supplier payments for services/bills, finance-keyed operating postings)
--   cost_of_sales   money paid for goods bought to produce or resell (PO-backed supplier invoices)
--   advance         staff cash still awaiting accountable receipts
--   committed       approved amounts that have not been paid yet (payables and pending advances)
create or replace view charm.finance_expense_lines with(security_invoker=true) as
 -- 1. Direct company expenses: the header itself is the recognised spend once approved.
 select 'R-'||r.id::text line_id,r.id request_id,r.expense_number,coalesce(r.expense_on,r.required_date) expense_on,r.purpose description,
  r.category_id,c.name category_name,r.department_id,dp.name department_name,'expense'::text classification,
  coalesce(r.source_type,'manual') source_type,r.source_id,r.kind,r.status,r.approved_amount amount,
  coalesce(p.paid,0) paid,greatest(r.approved_amount-coalesce(p.paid,0),0) outstanding,
  r.payment_method,acc.id account_id,acc.name account_name,ref.reference,
  coalesce(nullif(d.payee_snapshot->>'name',''),py.name,nullif(trim(r.recipient),''),u.name) recipient,
  r.owner_id,u.name owner_name,r.recorded_by,rb.name recorded_by_name,
  case when coalesce(p.paid,0)<=0 then 'unpaid' when p.paid<r.approved_amount then 'partial' else 'paid' end payment_status,
  r.created_at
 from charm.finance_requests r
 join charm.users u on u.id=r.owner_id
 join charm.finance_categories c on c.id=r.category_id
 left join charm.finance_departments dp on dp.id=r.department_id
 left join charm.finance_payees py on py.id=r.payee_id
 left join charm.users rb on rb.id=r.recorded_by
 left join lateral(select coalesce(sum(amount),0)::numeric(14,2) paid,min(id) first_id from charm.finance_disbursements where request_id=r.id)p on true
 left join charm.finance_disbursements d on d.id=p.first_id
 left join charm.finance_accounts acc on acc.id=d.account_id
 left join lateral(select reference from charm.finance_disbursements where request_id=r.id order by id desc limit 1)ref on true
 where r.kind='expense' and r.source_type is distinct from 'operating' and r.status in ('approved','part_paid','paid','closed')
 union all
 -- 2. Staff advances become expense through accepted, receipt-backed accountability.
 select 'A-'||ac.id::text,ac.request_id,r.expense_number,ac.expense_date,ac.description,r.category_id,c.name,r.department_id,dp.name,
  'expense','accountability',ac.id,r.kind,ac.status,ac.amount,ac.amount,0,r.payment_method,ac.account_id,acc.name,ac.reference,u.name,
  r.owner_id,u.name,ac.submitted_by,sb.name,'paid',ac.created_at
 from charm.finance_accountability ac
 join charm.finance_requests r on r.id=ac.request_id
 join charm.users u on u.id=r.owner_id
 join charm.finance_categories c on c.id=r.category_id
 join charm.users sb on sb.id=ac.submitted_by
 left join charm.finance_departments dp on dp.id=r.department_id
 left join charm.finance_accounts acc on acc.id=ac.account_id
 where ac.kind='expense' and ac.status='accepted'
 union all
 -- 3. Supplier payments for services and bills are recognised when the money actually moves.
 select 'D-'||d.id::text,d.request_id,r.expense_number,(d.paid_at at time zone 'Africa/Nairobi')::date,r.purpose,r.category_id,c.name,r.department_id,dp.name,
  'expense','supplier_payment',d.id,r.kind,r.status,d.amount,d.amount,0,acc.method,d.account_id,acc.name,d.reference,
  coalesce(nullif(d.payee_snapshot->>'name',''),u.name),r.owner_id,u.name,d.recorded_by,rb.name,'paid',d.created_at
 from charm.finance_disbursements d
 join charm.finance_requests r on r.id=d.request_id
 join charm.users u on u.id=r.owner_id
 join charm.finance_categories c on c.id=r.category_id
 join charm.finance_accounts acc on acc.id=d.account_id
 left join charm.users rb on rb.id=d.recorded_by
 left join charm.finance_departments dp on dp.id=r.department_id
 where r.kind='supplier' and not exists(select 1 from charm.finance_supplier_invoices si where si.request_id=r.id and si.po_id is not null)
 union all
 -- 4. Goods bought for production or resale are cost of sales, reported apart from operating expenses.
 select 'S-'||d.id::text,d.request_id,r.expense_number,(d.paid_at at time zone 'Africa/Nairobi')::date,'Purchase payment · '||r.purpose,r.category_id,c.name,r.department_id,dp.name,
  'cost_of_sales','purchase',d.id,r.kind,r.status,d.amount,d.amount,0,acc.method,d.account_id,acc.name,d.reference,
  coalesce(nullif(d.payee_snapshot->>'name',''),u.name),r.owner_id,u.name,d.recorded_by,rb.name,'paid',d.created_at
 from charm.finance_disbursements d
 join charm.finance_requests r on r.id=d.request_id
 join charm.users u on u.id=r.owner_id
 join charm.finance_categories c on c.id=r.category_id
 join charm.finance_accounts acc on acc.id=d.account_id
 left join charm.users rb on rb.id=d.recorded_by
 left join charm.finance_departments dp on dp.id=r.department_id
 where r.kind='supplier' and exists(select 1 from charm.finance_supplier_invoices si where si.request_id=r.id and si.po_id is not null)
 union all
 -- 5. Operating postings recorded by Finance, including history written before expenses had an identity.
 select 'O-'||oe.id::text,oe.request_id,coalesce(r.expense_number,'OP-'||oe.id::text),oe.occurred_on,oe.description,r.category_id,
  coalesce(c.name,initcap(oe.category)),r.department_id,dp.name,'expense','operating',oe.id,'expense',oe.category,oe.amount,
  case when oe.account_id is not null then oe.amount else 0::numeric(14,2) end,
  case when oe.account_id is not null then 0 else oe.amount end::numeric(14,2),
  acc.method,oe.account_id,acc.name,oe.reference,coalesce(nullif(trim(r.recipient),''),cb.name,oe.category),oe.created_by,
  cb.name,oe.created_by,cb.name,case when oe.account_id is not null then 'paid' else 'unpaid' end,oe.created_at
 from charm.finance_operating_entries oe
 join charm.users cb on cb.id=oe.created_by
 left join charm.finance_requests r on r.id=oe.request_id
 left join charm.finance_categories c on c.id=r.category_id
 left join charm.finance_departments dp on dp.id=r.department_id
 left join charm.finance_accounts acc on acc.id=oe.account_id
 where oe.direction='expense'
 union all
 -- 6. Cash already in a member of staff's hands that has not been accounted for.
 select 'V-'||r.id::text,r.id,r.expense_number,greatest((select max(paid_at) at time zone 'Africa/Nairobi' from charm.finance_disbursements where request_id=r.id),r.required_date),
  'Advance awaiting accountability · '||r.purpose,r.category_id,c.name,r.department_id,dp.name,'advance','advance',r.id,r.kind,r.status,
  (coalesce(p.paid,0)-coalesce(a.settled,0)-coalesce(a.refunded,0))::numeric(14,2),coalesce(p.paid,0)::numeric(14,2),0::numeric(14,2),
  r.payment_method,null,null::text,null::text,u.name,r.owner_id,u.name,r.owner_id,u.name,
  case when coalesce(p.paid,0)-coalesce(a.settled,0)-coalesce(a.refunded,0)>0 then 'partial' else 'paid' end,r.created_at
 from charm.finance_requests r
 join charm.users u on u.id=r.owner_id
 join charm.finance_categories c on c.id=r.category_id
 left join charm.finance_departments dp on dp.id=r.department_id
 left join lateral(select coalesce(sum(amount),0) paid from charm.finance_disbursements where request_id=r.id)p on true
 left join lateral(select coalesce(sum(amount) filter(where kind='expense' and status='accepted'),0) settled,
  coalesce(sum(amount) filter(where kind='refund' and status='accepted'),0) refunded from charm.finance_accountability where request_id=r.id)a on true
 where r.kind='staff' and coalesce(p.paid,0)>0 and coalesce(p.paid,0)-coalesce(a.settled,0)-coalesce(a.refunded,0)>0
 union all
 -- 7. Approved commitments not yet paid: supplier payables and advances waiting to be funded.
 select 'C-'||r.id::text,r.id,r.expense_number,coalesce(r.expense_on,r.required_date),
  case when r.kind='staff' then 'Approved advance to pay · ' else 'Payable · ' end||r.purpose,r.category_id,c.name,r.department_id,dp.name,
  'committed','commitment',r.id,r.kind,r.status,(r.approved_amount-coalesce(p.paid,0))::numeric(14,2),coalesce(p.paid,0)::numeric(14,2),
  (r.approved_amount-coalesce(p.paid,0))::numeric(14,2),r.payment_method,null,null::text,null::text,
  coalesce(py.name,u.name),r.owner_id,u.name,r.approved_by,ab.name,'unpaid',r.created_at
 from charm.finance_requests r
 join charm.users u on u.id=r.owner_id
 join charm.finance_categories c on c.id=r.category_id
 join charm.users ab on ab.id=r.approved_by
 left join charm.finance_departments dp on dp.id=r.department_id
 left join charm.finance_payees py on py.id=r.payee_id
 left join lateral(select coalesce(sum(amount),0) paid from charm.finance_disbursements where request_id=r.id)p on true
 where r.kind in ('staff','supplier') and r.status='approved' and coalesce(p.paid,0)<r.approved_amount;

grant select on charm.finance_expense_lines to authenticated;

-- One place the company total comes from: cards, breakdowns and the reconciliation all read this function.
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
  'cashOut',(select coalesce(sum(amount),0)::text from charm.finance_cashbook where direction='out' and kind<>'opening' and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
  'cashIn',(select coalesce(sum(amount),0)::text from charm.finance_cashbook where direction='in' and kind<>'opening' and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
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
   where l.direction='out' and l.kind<>'opening' and (l.occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to
   group by 1)x),'{}'));
end$$;

-- The single expense register: filtered, paginated, and exportable straight from the same query.
create or replace function charm.finance_expense_register(p_from date,p_to date,p_classification text default '',p_category bigint default null,p_department bigint default null,p_account bigint default null,p_payment text default '',p_search text default '',p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_finance();rows jsonb;total bigint;
begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 or p_page is null or p_page<0 or p_page>10000 then raise exception 'invalid';end if;
 if p_classification<>'' and p_classification not in ('expense','cost_of_sales','advance','committed') then raise exception 'invalid';end if;
 if p_payment<>'' and p_payment not in ('unpaid','partial','paid') then raise exception 'invalid';end if;
 select count(*) into total from charm.finance_expense_lines x where expense_on between p_from and p_to
  and (p_classification='' or classification=p_classification) and (p_category is null or category_id=p_category)
  and (p_department is null or department_id=p_department) and (p_account is null or account_id=p_account)
  and (p_payment='' or payment_status=p_payment)
  and (coalesce(p_search,'')='' or x.description ilike '%'||trim(p_search)||'%' or coalesce(x.expense_number,'') ilike '%'||trim(p_search)||'%'
   or coalesce(x.reference,'') ilike '%'||trim(p_search)||'%' or coalesce(x.recipient,'') ilike '%'||trim(p_search)||'%' or coalesce(x.owner_name,'') ilike '%'||trim(p_search)||'%');
 if p_page=0 then
  if total>5000 then raise exception 'financeExportLimit';end if;
  -- Money leaves this function as exact text, the same as every other finance RPC, never as a JSON float.
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',x.amount::text,'paid',x.paid::text,'outstanding',x.outstanding::text) order by x.expense_on desc,x.line_id),'[]') into rows from charm.finance_expense_lines x where expense_on between p_from and p_to
   and (p_classification='' or classification=p_classification) and (p_category is null or category_id=p_category)
   and (p_department is null or department_id=p_department) and (p_account is null or account_id=p_account)
   and (p_payment='' or payment_status=p_payment)
   and (coalesce(p_search,'')='' or x.description ilike '%'||trim(p_search)||'%' or coalesce(x.expense_number,'') ilike '%'||trim(p_search)||'%'
    or coalesce(x.reference,'') ilike '%'||trim(p_search)||'%' or coalesce(x.recipient,'') ilike '%'||trim(p_search)||'%' or coalesce(x.owner_name,'') ilike '%'||trim(p_search)||'%');
 else
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',x.amount::text,'paid',x.paid::text,'outstanding',x.outstanding::text) order by x.expense_on desc,x.line_id),'[]') into rows from(select * from charm.finance_expense_lines x where expense_on between p_from and p_to
   and (p_classification='' or classification=p_classification) and (p_category is null or category_id=p_category)
   and (p_department is null or department_id=p_department) and (p_account is null or account_id=p_account)
   and (p_payment='' or payment_status=p_payment)
   and (coalesce(p_search,'')='' or x.description ilike '%'||trim(p_search)||'%' or coalesce(x.expense_number,'') ilike '%'||trim(p_search)||'%'
    or coalesce(x.reference,'') ilike '%'||trim(p_search)||'%' or coalesce(x.recipient,'') ilike '%'||trim(p_search)||'%' or coalesce(x.owner_name,'') ilike '%'||trim(p_search)||'%')
   order by expense_on desc,line_id limit 100 offset (p_page-1)*100)x;
 end if;
 return jsonb_build_object('rows',rows,'total',total);
end$$;

-- Departments and both kinds of expense master data reach the portal through metadata, like accounts do.
create or replace function charm.finance_metadata() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform charm.require_actor();return jsonb_build_object(
 'categories',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_categories c where active),
 'departments',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_departments c where active),
 'accounts',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('balance',(select coalesce(sum(case when direction='in' then amount else -amount end),0)::text from charm.finance_cashbook where account_id=c.id)) order by name),'[]') from charm.finance_accounts c where active and charm.finance_reader()),
 'refund_accounts',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_accounts c where active),
 'payees',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_payees c where staff_id=charm.actor() or charm.finance_reader()),
 'staff',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'active',active) order by name),'[]') from charm.users where charm.finance_reader()));
end$$;

-- The finance dashboard reads the consolidated register, so 'expenses' means one figure, not two.
create or replace function charm.finance_summary(p_from date,p_to date,p_owner bigint default null) returns jsonb language plpgsql stable security definer set search_path='' as $$declare a bigint:=charm.require_actor();result jsonb;begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 select jsonb_build_object('pending',count(*) filter(where status='pending'),'approved',coalesce(sum(approved_amount) filter(where status in ('approved','part_paid','paid','closed')),0)::text,'outstanding',coalesce(sum(outstanding),0)::text,'overdue',count(*) filter(where outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date)) into result from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and required_date between p_from and p_to;
 result:=result||jsonb_build_object(
  'disbursed',(select coalesce(sum(d.amount),0)::text from charm.finance_disbursements d join charm.finance_requests r on r.id=d.request_id where (r.owner_id=a or charm.finance_reader()) and (p_owner is null or r.owner_id=p_owner) and (d.paid_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
  'cashflow',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select to_char(occurred_at at time zone 'Africa/Nairobi','YYYY-MM') as month,coalesce(sum(amount) filter(where direction='in'),0)::text incoming,coalesce(sum(amount) filter(where direction='out'),0)::text outgoing from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to and kind<>'opening' group by 1 order by 1)x),
  'expenses',(select coalesce(sum(amount),0)::text from charm.finance_expense_lines where classification='expense' and (charm.finance_reader() or request_id is not null and charm.finance_access(request_id)) and (p_owner is null or owner_id=p_owner) and expense_on between p_from and p_to),
  'categories',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select category_name,sum(amount)::text amount from charm.finance_expense_lines where classification='expense' and (charm.finance_reader() or request_id is not null and charm.finance_access(request_id)) and (p_owner is null or owner_id=p_owner) and expense_on between p_from and p_to group by category_name order by category_name)x),
  'outstanding',(select coalesce(sum(outstanding),0)::text from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner)),
  'overdue',(select count(*) from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date));return result;
end$$;

revoke execute on function charm.finance_expense_totals(date,date),charm.finance_expense_register(date,date,text,bigint,bigint,bigint,text,text,integer) from public,anon;
grant execute on function charm.finance_expense_totals(date,date),charm.finance_expense_register(date,date,text,bigint,bigint,bigint,text,text,integer) to authenticated;
notify pgrst,'reload schema';
commit;

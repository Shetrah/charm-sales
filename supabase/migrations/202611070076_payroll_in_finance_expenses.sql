begin;

-- Show paid payroll in Finance expense totals and registers. The corresponding ledger row already updates the cashbook and account balance.
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
 where r.kind in ('staff','supplier') and r.status='approved' and coalesce(p.paid,0)<r.approved_amount union all
 -- Payroll payments are expenses in the main finance register as well as account cash out.
 select 'P-'||s.id::text,null::bigint,'PAY-'||s.id::text,s.paid_on,
  'Salary payment · '||e.full_name,null::bigint,'Salaries and Wages'::text,null::bigint,e.department::text,
  'expense'::text,'payroll'::text,s.id,'expense'::text,s.status::text,s.net_pay,s.net_pay,0::numeric(14,2),
  acc.method,acc.id,acc.name,s.payment_reference,e.full_name,
  s.created_by,creator.name,s.paid_by,payer.name,'paid'::text,s.created_at
 from charm.payroll_slips s
 join charm.payroll_employees e on e.id=s.employee_id
 join charm.finance_accounts acc on acc.id=s.account_id
 left join charm.users creator on creator.id=s.created_by
 left join charm.users payer on payer.id=s.paid_by
 where s.status='paid' and s.payment_ledger_id is not null;
grant select on charm.finance_expense_lines to authenticated;
notify pgrst,'reload schema';
commit;

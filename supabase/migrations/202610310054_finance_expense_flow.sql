-- Record an expense once. The header, its line items, the payment and the cash posting are produced from a
-- single action so that expenditure, operating entries, disbursements and the cashbook stop competing copies.
begin;

-- A company expense paid from an account is its own cash movement: not an advance, not a supplier bill.
do $$ declare c record; begin
 for c in select conname from pg_constraint where conrelid='charm.finance_ledger'::regclass and contype='c' and pg_get_constraintdef(oid) like '%kind%' loop
  execute format('alter table charm.finance_ledger drop constraint %I',c.conname);
 end loop;
end $$;
alter table charm.finance_ledger add constraint finance_ledger_kind_check check(kind in ('advance','supplier','refund','customer_receipt','opening','expense'));

-- One form, one transaction: header + lines. Money is always the sum of validated lines, never a typed total.
create or replace function charm.finance_record_expense(p_key uuid,p_id bigint,p_category bigint,p_department bigint,p_expense_on date,p_purpose text,p_recipient text,p_payee bigint,p_order bigint,p_payment_method text,p_items jsonb,p_submit boolean) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;old bigint;expense_id bigint;v numeric:=0;line numeric;item jsonb;d text;q text;u text;f text;x text;lines jsonb:='[]';paid_to text;record_status text;
begin
 perform charm.require_finance();
 old:=charm.claim(p_key,'finance_record_expense',jsonb_build_array(p_id,p_category,p_department,p_expense_on,p_purpose,p_recipient,p_payee,p_order,p_payment_method,p_items,p_submit));if old is not null then return old;end if;
 if not exists(select 1 from charm.finance_categories where finance_categories.id=p_category and active) then raise exception 'invalid';end if;
 if p_department is not null and not exists(select 1 from charm.finance_departments where finance_departments.id=p_department and active) then raise exception 'invalid';end if;
 if p_expense_on is null or p_expense_on<'2020-01-01'::date or p_expense_on>(now() at time zone 'Africa/Nairobi')::date then raise exception 'invalid';end if;
 if coalesce(length(trim(p_purpose)),0) not between 1 and 10000 then raise exception 'invalid';end if;
 paid_to:=nullif(trim(coalesce(p_recipient,'')),'');
 if paid_to is not null and length(paid_to)>200 then raise exception 'invalid';end if;
 if p_payee is not null and not exists(select 1 from charm.finance_payees where finance_payees.id=p_payee and staff_id is null) then raise exception 'invalid';end if;
 if p_payee is null and paid_to is null then raise exception 'payeeMissing';end if;
 if p_order is not null and not exists(select 1 from charm.orders where orders.id=p_order) then raise exception 'invalid';end if;
 if p_payment_method is not null and p_payment_method not in ('Cash','Bank','M-Pesa','Cheque','Other') then raise exception 'invalid';end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 50 then raise exception 'invalid';end if;
 for item in select jsonb_array_elements(p_items) loop
  d:=trim(coalesce(item->>'description',''));q:=coalesce(nullif(item->>'quantity',''),'1');u:=coalesce(nullif(item->>'unit_price',''),'0');
  f:=coalesce(nullif(item->>'discount',''),'0');x:=coalesce(nullif(item->>'tax',''),'0');
  if length(d) not between 1 and 300 or q !~ '^\d{1,9}(\.\d{1,4})?$' or u !~ '^\d{1,11}(\.\d{1,2})?$' or f !~ '^\d{1,11}(\.\d{1,2})?$' or x !~ '^\d{1,11}(\.\d{1,2})?$' then raise exception 'invalid';end if;
  line:=round(q::numeric*u::numeric-f::numeric+x::numeric,2);
  if line<=0 then raise exception 'invalidMoney';end if;
  v:=v+line;lines:=lines||jsonb_build_object('description',d,'quantity',q::numeric,'unit_price',u::numeric,'discount',f::numeric,'tax',x::numeric,'line_total',line);
 end loop;
 if v<=0 or v>9999999999::numeric then raise exception 'invalidMoney';end if;
 record_status:=case when p_submit then 'pending' else 'draft' end;
 if p_id is null then
  insert into charm.finance_requests(owner_id,kind,category_id,department_id,payee_id,amount,purpose,required_date,accountability_due,expense_on,payment_method,recipient,order_id,recorded_by,source_type,status)
  values(a,'expense',p_category,p_department,p_payee,v,trim(p_purpose),p_expense_on,p_expense_on+7,p_expense_on,p_payment_method,paid_to,p_order,a,'manual',record_status) returning finance_requests.id into expense_id;
 else
  select * into r from charm.finance_requests where finance_requests.id=p_id for update;
  if r.id is null or r.kind<>'expense' or r.owner_id is distinct from a or r.status not in ('draft','returned') then raise exception 'financeLocked';end if;
  update charm.finance_requests set category_id=p_category,department_id=p_department,payee_id=p_payee,amount=v,purpose=trim(p_purpose),required_date=p_expense_on,
   accountability_due=p_expense_on+7,expense_on=p_expense_on,payment_method=p_payment_method,recipient=paid_to,order_id=p_order,status=case when p_submit then 'pending' else r.status end,updated_at=now() where finance_requests.id=p_id;
  expense_id:=p_id;delete from charm.finance_expense_items where request_id=expense_id;
 end if;
 insert into charm.finance_expense_items(request_id,description,quantity,unit_price,discount,tax,line_total,sort)
  select expense_id,value->>'description',(value->>'quantity')::numeric,(value->>'unit_price')::numeric,(value->>'discount')::numeric,(value->>'tax')::numeric,(value->>'line_total')::numeric,ordinality
  from jsonb_array_elements(lines) with ordinality as l(value,ordinality);
 perform charm.audit('financeExpense','finance_requests',expense_id,jsonb_build_object('amount',v,'lines',jsonb_array_length(p_items),'category_id',p_category,'department_id',p_department,'expense_on',p_expense_on,'before',case when p_id is null then null else to_jsonb(r) end));
 if p_submit then perform charm.finance_notify(expense_id,'expenseSubmitted','expense-submitted:'||expense_id||':'||now(),array['admin'],false);end if;
 return charm.finish(p_key,expense_id);
end$$;

-- The form reloads exactly what the server stored, so a total can never drift from its lines.
create or replace function charm.finance_expense_detail(p_id bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r charm.finance_requests;begin
 if not charm.finance_access(p_id) then raise exception 'forbidden';end if;
 select * into r from charm.finance_requests where finance_requests.id=p_id;
 return jsonb_build_object('id',r.id,'expense_number',r.expense_number,'kind',r.kind,'status',r.status,'owner_id',r.owner_id,'recorded_by',r.recorded_by,
  'category_id',r.category_id,'department_id',r.department_id,'expense_on',r.expense_on,'required_date',r.required_date,'accountability_due',r.accountability_due,
  'amount',r.amount::text,'approved_amount',r.approved_amount::text,'purpose',r.purpose,'recipient',r.recipient,'payee_id',r.payee_id,'order_id',r.order_id,
  'payment_method',r.payment_method,'source_type',r.source_type,'source_id',r.source_id,'reason',r.reason,'budget_id',r.budget_id,
  'items',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'description',i.description,'quantity',i.quantity::text,'unit_price',i.unit_price::text,'discount',i.discount::text,'tax',i.tax::text,'line_total',i.line_total::text) order by i.sort,i.id),'[]') from charm.finance_expense_items i where i.request_id=p_id),
  'documents',(select coalesce(jsonb_agg(to_jsonb(d) order by d.id),'[]') from charm.finance_documents d where d.request_id=p_id));
end$$;

-- Categories and departments stay configurable data instead of code changes.
create or replace function charm.finance_expense_settings(p_key uuid,p_kind text,p_data jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;target bigint;previous jsonb;label text;is_active boolean;
begin
 perform charm.require_finance();
 old:=charm.claim(p_key,'finance_expense_settings',jsonb_build_array(p_kind,p_data));if old is not null then return old;end if;
 if p_kind not in ('category','department') then raise exception 'invalid';end if;
 label:=nullif(trim(coalesce(p_data->>'name','')),'');
 if coalesce(length(label),0)>120 or label is not null and length(label)<1 then raise exception 'invalid';end if;
 target:=nullif(coalesce(p_data->>'id',''),'')::bigint;
 if target is null and coalesce(p_data->>'id','')<>'' then raise exception 'invalid';end if;
 if target is null then
  if label is null then raise exception 'invalid';end if;
  is_active:=coalesce(nullif(p_data->>'active','')::boolean,true);
  if p_kind='category' then insert into charm.finance_categories(name,active) values(label,is_active) returning finance_categories.id into target;
  else insert into charm.finance_departments(name,active) values(label,is_active) returning finance_departments.id into target;end if;
 else
  if p_kind='category' then select to_jsonb(x) into previous from charm.finance_categories x where x.id=target;
  else select to_jsonb(x) into previous from charm.finance_departments x where x.id=target;end if;
  if previous is null then raise exception 'notFound';end if;
  if label is null and nullif(p_data->>'active','') is null then raise exception 'invalid';end if;
  is_active:=coalesce(nullif(p_data->>'active','')::boolean,(previous->>'active')::boolean,true);
  if p_kind='category' then update charm.finance_categories set name=coalesce(label,name),active=is_active where id=target;
  else update charm.finance_departments set name=coalesce(label,name),active=is_active where id=target;end if;
 end if;
 perform charm.audit('financeExpenseSetting','finance_'||p_kind,target,jsonb_build_object('before',previous,'after',p_data));
 return charm.finish(p_key,target);
end$$;

-- Paying an approved record inherits the outstanding balance instead of asking the officer to type it again,
-- and carries a company expense through the same proof, funds and duplicate-reference controls.
create or replace function charm.finance_disburse(p_key uuid,p_id bigint,p_account bigint,p_amount text,p_reference text,p_date timestamptz,p_proof bigint,p_confirmed boolean) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;payee charm.finance_payees;typed text:=lower(trim(coalesce(p_amount,'')));v numeric;paid numeric;outstanding numeric;old bigint;id bigint;balance numeric;snapshot jsonb;
begin
 perform charm.require_finance();
 old:=charm.claim(p_key,'finance_disburse',jsonb_build_array(p_id,p_account,typed,p_reference,p_date,p_proof,p_confirmed));if old is not null then return old;end if;
 select * into r from charm.finance_requests where finance_requests.id=p_id for update;
 if r.status is null or r.status not in ('approved','part_paid') or r.approved_amount is null or r.approved_at is null or r.approved_by is null or r.approved_by=r.owner_id or r.budget_id is null then raise exception 'financeLocked';end if;
 if r.kind='staff' and a=r.owner_id then raise exception 'selfApproval';end if;
 if p_confirmed is distinct from true or coalesce(length(trim(p_reference)),0) not between 1 and 200 or p_date is null or p_date>now() or p_date<date_trunc('minute',r.approved_at) then raise exception 'paymentConfirmationRequired';end if;
 if not exists(select 1 from charm.finance_accounts where finance_accounts.id=p_account and active) then raise exception 'invalid';end if;
 if not exists(select 1 from charm.finance_documents where finance_documents.id=p_proof and request_id=p_id and kind='payment' and uploaded_by=a) then raise exception 'proofRequired';end if;
 select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=p_id;
 outstanding:=r.approved_amount-paid;
 v:=case when typed='' then outstanding else charm.finance_money(p_amount) end;
 if v<=0 or paid+v>r.approved_amount then raise exception 'overpayment';end if;
 if r.kind='expense' then
  select * into payee from charm.finance_payees where finance_payees.id=r.payee_id;
  if payee.id is null and coalesce(length(trim(coalesce(r.recipient,''))),0)=0 then raise exception 'payeeMissing';end if;
  snapshot:=jsonb_build_object('name',coalesce(payee.name,nullif(trim(r.recipient),'')),'details',coalesce(nullif(payee.details,''),'Company expense recipient'),'kind','expense');
 else
  select * into payee from charm.finance_payees where (r.kind='staff' and staff_id=r.owner_id) or (r.kind='supplier' and finance_payees.id=r.payee_id);
  if payee.id is null then raise exception 'payeeMissing';end if;
  snapshot:=to_jsonb(payee);
  if r.kind='staff' and not exists(select 1 from charm.users where users.id=r.owner_id and active) then raise exception 'staffInactive';end if;
 end if;
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
 insert into charm.finance_disbursements(request_id,account_id,amount,reference,paid_at,payee_snapshot,proof_id,recorded_by) values(p_id,p_account,v,trim(p_reference),p_date,snapshot,p_proof,a) returning finance_disbursements.id into id;
 insert into charm.finance_ledger(request_id,account_id,direction,amount,kind,reference,occurred_at,recorded_by,disbursement_id) values(p_id,p_account,'out',v,case when r.kind='staff' then 'advance' when r.kind='expense' then 'expense' else 'supplier' end,trim(p_reference),p_date,a,id);
 update charm.finance_requests set status=case when paid+v=approved_amount then 'paid' else 'part_paid' end,updated_at=now() where finance_requests.id=p_id;
 perform charm.audit('financeDisbursed','finance_requests',p_id,jsonb_build_object('disbursement_id',id,'amount',v,'account_id',p_account,'reference',trim(p_reference),'recipient',snapshot->>'name','proof_id',p_proof));
 perform charm.finance_notify(p_id,'financeDisbursed','disbursement:'||id,array['admin']);
 return charm.finish(p_key,id);
end$$;

-- Evidence for a company expense belongs to the officer who is accountable for it, at every stage.
create or replace function charm.finance_file_access(p_path text,p_write boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare parts text[]:=string_to_array(p_path,'/');r charm.finance_requests;a bigint:=charm.actor();begin
 if a is null or p_path !~ '^requests/[0-9]+/(support|payment|receipt|refund)/[0-9]+/[a-f0-9-]{36}\.(pdf|jpg|png|webp)$' then return false;end if;
 select * into r from charm.finance_requests where id=parts[2]::bigint;
 if r.id is null then return false;end if;
 if not p_write then return charm.finance_access(r.id);end if;
 if parts[4]::bigint<>a then return false;end if;
 return (parts[3]='support' and r.owner_id=a and r.status in ('draft','returned'))
  or (parts[3]='payment' and charm.finance_operator() and (r.kind in ('supplier','expense') or r.owner_id<>a) and r.status in ('approved','part_paid'))
  or (parts[3] in ('receipt','refund') and r.owner_id=a and r.kind='staff' and r.status in ('part_paid','paid'))
  or (parts[3] in ('support','receipt','payment') and r.kind='expense' and r.owner_id=a and charm.finance_operator());
end$$;

-- A three-way matched supplier bill records where the money came from, so it can never be keyed twice.
create or replace function charm.finance_match_supplier_invoice(p_invoice bigint,p_decision text,p_reason text default '') returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();i charm.finance_supplier_invoices;req bigint;begin
 if not charm.finance_operator() then raise exception 'forbidden';end if;
 select * into i from charm.finance_supplier_invoices where id=p_invoice for update;if i.id is null or i.status<>'pending_match' then raise exception 'financeLocked';end if;
 if p_decision<>'matched' then update charm.finance_supplier_invoices set status='rejected',reviewed_by=a where id=p_invoice;perform charm.audit('supplierInvoiceRejected','finance_supplier_invoices',p_invoice,jsonb_build_object('reason',p_reason));return null;end if;
 if not exists(select 1 from charm.finance_goods_receipts g where g.id=i.grn_id and g.po_id=i.po_id and g.status='approved') then raise exception 'threeWayMatchRequired';end if;
 if i.subtotal>(select coalesce(sum(gl.accepted_quantity*pol.unit_price),0) from charm.finance_goods_receipt_lines gl join charm.finance_purchase_order_lines pol on pol.id=gl.po_line_id where gl.grn_id=i.grn_id) then raise exception 'threeWayAmountMismatch';end if;
 insert into charm.finance_requests(owner_id,kind,payee_id,category_id,amount,purpose,required_date,accountability_due,status,expense_on,recorded_by,source_type,source_id)
 values(a,'supplier',i.supplier_id,coalesce((select id from charm.finance_categories where name='Suppliers' and active),(select id from charm.finance_categories where name='Other' and active)),i.subtotal+i.tax_amount+i.duty_amount,'PO/GRN/Invoice '||i.invoice_number,(now() at time zone 'Africa/Nairobi')::date,(now() at time zone 'Africa/Nairobi')::date+7,'pending',(now() at time zone 'Africa/Nairobi')::date,a,'supplier_invoice',p_invoice) returning id into req;
 update charm.finance_supplier_invoices set status='payment_requested',request_id=req,reviewed_by=a where id=p_invoice;
 perform charm.audit('threeWayMatchPassed','finance_supplier_invoices',p_invoice,jsonb_build_object('po_id',i.po_id,'grn_id',i.grn_id,'request_id',req));
 perform charm.finance_notify(req,'supplierInvoiceMatched','supplier-invoice:'||p_invoice,array['admin'],true);
 return req;
end$$;

-- Operating postings become company expenses with an identity; revenue postings keep their existing behaviour.
create or replace function charm.finance_record_operating_entry(p_direction text,p_category text,p_amount numeric,p_date date,p_description text,p_reference text,p_account bigint default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();entry_id bigint;req bigint;cat bigint;
begin
 if not charm.finance_operator() or p_direction not in ('revenue','expense') or p_category not in ('operational','financial','other','sales','tax','duty') or p_amount<=0 or p_date is null or coalesce(length(trim(p_description)),0) not between 1 and 2000 or coalesce(length(trim(p_reference)),0) not between 1 and 200 then raise exception 'invalid';end if;
 insert into charm.finance_operating_entries(direction,category,amount,occurred_on,description,reference,account_id,created_by) values(p_direction,p_category,p_amount,p_date,trim(p_description),trim(p_reference),p_account,a) returning finance_operating_entries.id into entry_id;
 if p_account is not null then insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by) values(p_account,case when p_direction='revenue' then 'in' else 'out' end,p_amount,case when p_direction='revenue' then 'customer_receipt' else 'expense' end,trim(p_reference),p_date::timestamp at time zone 'Africa/Nairobi',a);end if;
 if p_direction='expense' then
  -- The posting is now the expense record itself, linked back so the same bill can never be keyed twice.
  select id into cat from charm.finance_categories where name='Miscellaneous Expenses' and active;
  if cat is null then select id into cat from charm.finance_categories where name='Other' and active;end if;
  insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,expense_on,recorded_by,source_type,source_id,status,approved_amount,approved_by,approved_at)
  values(a,'expense',cat,p_amount,trim(p_description),p_date,p_date+7,p_date,a,'operating',entry_id,
   case when p_account is not null then 'paid' else 'pending' end,case when p_account is not null then p_amount end,case when p_account is not null then a end,case when p_account is not null then now() end)
  on conflict(source_type,source_id) where source_id is not null do nothing returning finance_requests.id into req;
  if req is null then select request_id into req from charm.finance_requests where source_type='operating' and source_id=entry_id;end if;
  update charm.finance_operating_entries set request_id=req where finance_operating_entries.id=entry_id;
  if p_account is null then perform charm.finance_notify(req,'expenseSubmitted','operating-expense:'||entry_id,array['admin'],false);end if;
 end if;
 perform charm.audit('operatingEntryRecorded','finance_operating_entries',entry_id,jsonb_build_object('direction',p_direction,'category',p_category,'amount',p_amount,'reference',p_reference,'request_id',req));return entry_id;
end$$;

-- Marking a commission paid releases it into the same expense queue; nothing is typed twice.
create or replace function charm.commission_decide(p_entry bigint,p_status text,p_amount numeric default null,p_reason text default '') returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); e charm.commission_entries; r charm.finance_requests; b charm.finance_budgets; cat bigint; day date; v numeric; payable boolean;
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
 if p_status='paid' and e.commission_amount>0 then
  day:=(now() at time zone 'Africa/Nairobi')::date;
  select id into cat from charm.finance_categories where name='Salaries and Wages' and active;
  if cat is null then select id into cat from charm.finance_categories where name='Other' and active; end if;
  select * into b from charm.finance_budgets where category_id=cat and month=date_trunc('month',day)::date for update;
  payable:=b.id is not null and charm.finance_budget_committed(b.id)+e.commission_amount<=b.amount;
  select * into r from charm.finance_requests where source_type='commission' and source_id=p_entry for update;
  if r.id is null then
   insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,expense_on,recorded_by,source_type,source_id,status,approved_amount,approved_by,approved_at,budget_id)
   values(e.salesperson_id,'expense',cat,e.commission_amount,'Commission for period '||e.period_start::text,day,day+7,day,a,'commission',p_entry,
    case when payable then 'approved' else 'pending' end,case when payable then e.commission_amount end,case when payable then a end,case when payable then now() end,case when payable then b.id end) on conflict(source_type,source_id) where source_id is not null do nothing;
   perform charm.finance_notify((select id from charm.finance_requests where source_type='commission' and source_id=p_entry),'commissionPayable','commission-payable:'||p_entry,array['admin','finance_officer'],false);
  elsif r.status in ('draft','pending','approved') then
   update charm.finance_requests set amount=e.commission_amount,approved_amount=case when payable then e.commission_amount else approved_amount end,
    status=case when payable and r.status<>'approved' then 'approved' else r.status end,budget_id=case when payable then b.id else budget_id end,updated_at=now() where id=r.id;
  end if;
 end if;
 if p_status in ('reversed','adjusted') then
  update charm.finance_requests set status='rejected',reason=nullif(trim(p_reason),''),updated_at=now() where source_type='commission' and source_id=p_entry and status in ('draft','pending','returned');
 end if;
end $$;

-- Once the linked expense is actually paid, the commission record reflects it without a second posting.
create or replace function charm.commission_request_payment() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.source_type='commission' and new.source_id is not null and new.status in ('paid','closed') then
  update charm.commission_entries set status='paid',updated_at=now() where id=new.source_id and status in ('earned','approved');
 end if;return new;end$$;
drop trigger if exists commission_request_payment on charm.finance_requests;
create trigger commission_request_payment after update of status on charm.finance_requests for each row execute function charm.commission_request_payment();

do $$ declare f record;begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='charm' and p.proname in ('finance_record_expense','finance_expense_detail','finance_expense_settings','finance_file_access','finance_match_supplier_invoice','finance_record_operating_entry','commission_decide','commission_request_payment','finance_expense_number') loop
  execute format('revoke execute on function %s from public,anon',f.signature);
 end loop;
 revoke execute on function charm.commission_request_payment(),charm.finance_expense_number() from public,anon,authenticated;
 grant execute on function charm.finance_record_expense(uuid,bigint,bigint,bigint,date,text,text,bigint,bigint,text,jsonb,boolean),
  charm.finance_expense_detail(bigint),charm.finance_expense_settings(uuid,text,jsonb),
  charm.finance_match_supplier_invoice(bigint,text,text),charm.finance_record_operating_entry(text,text,numeric,date,text,text,bigint),
  charm.commission_decide(bigint,text,numeric,text) to authenticated;
end$$;
notify pgrst,'reload schema';
commit;

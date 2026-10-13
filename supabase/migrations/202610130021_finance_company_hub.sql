begin;
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
create policy finance_audit_read on charm.audit_logs for select to authenticated using(charm.finance_role()='finance_officer' and (entity like 'finance_%' or entity='payments'));
notify pgrst,'reload schema';
commit;

begin;
alter table charm.finance_accountability add column if not exists expense_date date not null default ((now() at time zone 'Africa/Nairobi')::date);
create function charm.finance_money(p_value text) returns numeric language plpgsql immutable set search_path='' as $$begin
 if p_value is null or p_value !~ '^\d{1,10}(\.\d{1,2})?$' or p_value::numeric<=0 then raise exception 'invalidMoney';end if;return p_value::numeric;end$$;
create function charm.finance_budget_committed(p_id bigint) returns numeric language sql stable security definer set search_path='' as $$
 select coalesce(sum(case when r.status='closed' then case when r.kind='staff' then (select coalesce(sum(amount),0) from charm.finance_accountability where request_id=r.id and kind='expense' and status='accepted') else (select coalesce(sum(amount),0) from charm.finance_disbursements where request_id=r.id) end else r.approved_amount end),0)
 from charm.finance_requests r where r.budget_id=p_id and r.status in ('approved','part_paid','paid','closed')
$$;
revoke execute on function charm.finance_budget_committed(bigint) from public,anon,authenticated;
create function charm.finance_save_request(p_key uuid,p_id bigint,p_category bigint,p_amount text,p_purpose text,p_date date,p_due date,p_payee bigint default null) returns bigint language plpgsql security definer set search_path='' as $$
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
create function charm.finance_submit_request(p_id bigint) returns void language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;begin
 select * into r from charm.finance_requests where id=p_id for update;
 if r.owner_id is distinct from a or charm.finance_role() in ('management','auditor') then raise exception 'forbidden';end if;
 if r.status='pending' then return;end if;
 if r.status not in ('draft','returned') then raise exception 'financeLocked';end if;
 update charm.finance_requests set status='pending',reason=null,updated_at=now() where id=p_id;
 perform charm.audit('financeSubmitted','finance_requests',p_id);
 perform charm.finance_notify(p_id,'financeSubmitted','submitted:'||p_id||':'||now(),case when r.kind='supplier' then array['finance_manager'] else array['admin'] end);
end$$;
create function charm.finance_review_request(p_id bigint,p_decision text,p_reason text,p_amount text default null) returns void language plpgsql security definer set search_path='' as $$
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
create function charm.finance_disburse(p_key uuid,p_id bigint,p_account bigint,p_amount text,p_reference text,p_date timestamptz,p_proof bigint,p_confirmed boolean) returns bigint language plpgsql security definer set search_path='' as $$
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
create function charm.finance_submit_accountability(p_key uuid,p_id bigint,p_kind text,p_amount text,p_description text,p_proof bigint,p_reference text default null,p_account bigint default null,p_date date default null) returns bigint language plpgsql security definer set search_path='' as $$
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
create function charm.finance_review_accountability(p_id bigint,p_accept boolean,p_reason text,p_confirmed boolean default false) returns void language plpgsql security definer set search_path='' as $$
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
create function charm.finance_close_request(p_id bigint,p_reason text) returns void language plpgsql security definer set search_path='' as $$
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
create function charm.finance_mark_read(p_id bigint default null) returns void language plpgsql security definer set search_path='' as $$begin
 update charm.finance_notifications set read_at=coalesce(read_at,now()) where recipient_id=charm.require_actor() and (p_id is null or id=p_id);
end$$;
-- Existing expense IDs remain canonical. Financial approval is a distinct budget check,
-- never a claim that legacy approved expenses were paid.
create function charm.finance_bridge_expense() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.budget>0 then
 insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,status,source_expense_id,created_at)
 values(new.salesperson_id,'staff',(select id from charm.finance_categories where name='Other'),new.budget,new.notes,new.date,new.date+7,case when new.status='rejected' then 'rejected' else 'pending' end,new.id,coalesce(new.created_at,now())) on conflict(source_expense_id) do nothing;
 end if;return new;end$$;
create trigger finance_expense_bridge after insert on charm.expenses for each row execute function charm.finance_bridge_expense();
insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,status,source_expense_id,created_at)
 select salesperson_id,'staff',(select id from charm.finance_categories where name='Other'),budget,notes,date,date+7,case when status='rejected' then 'rejected' else 'pending' end,id,coalesce(created_at,now()) from charm.expenses where budget>0 on conflict(source_expense_id) do nothing;
do $$ declare f record;begin
 for f in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='charm' and p.proname in ('finance_money','finance_save_request','finance_submit_request','finance_review_request','finance_disburse','finance_submit_accountability','finance_review_accountability','finance_close_request','finance_mark_read','finance_bridge_expense') loop
  execute format('revoke execute on function %s from public,anon,authenticated',f.signature);
  if f.proname not in ('finance_money','finance_bridge_expense') then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;end$$;
commit;

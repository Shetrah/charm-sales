-- Direct company expenses are fully recorded at disbursement time. Do not require
-- a second accountability submission to close these requests. Staff advances
-- retain the existing accountability and outstanding-balance controls.
begin;

do $$
begin
 if to_regclass('charm.finance_requests') is null
    or to_regclass('charm.finance_disbursements') is null
    or to_regclass('charm.finance_ledger') is null
    or to_regclass('charm.finance_accountability') is null
    or to_regprocedure('charm.finance_disburse(uuid,bigint,bigint,text,text,timestamp with time zone,bigint,boolean)') is null then
  raise exception 'financeExpenseFlowPrerequisiteMissing';
 end if;
end $$;

create or replace function charm.finance_disburse(p_key uuid,p_id bigint,p_account bigint,p_amount text,p_reference text,p_date timestamptz,p_proof bigint,p_confirmed boolean) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;payee charm.finance_payees;typed text:=lower(trim(coalesce(p_amount,'')));v numeric;paid numeric;outstanding numeric;old bigint;id bigint;balance numeric;snapshot jsonb;final_status text;
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
 -- Staff advances continue to require settlement before another advance.
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
 final_status:=case when paid+v=r.approved_amount then case when r.kind='expense' then 'closed' else 'paid' end else 'part_paid' end;
 update charm.finance_requests set status=final_status,updated_at=now() where finance_requests.id=p_id;
 perform charm.audit('financeDisbursed','finance_requests',p_id,jsonb_build_object('disbursement_id',id,'amount',v,'account_id',p_account,'reference',trim(p_reference),'recipient',snapshot->>'name','proof_id',p_proof,'status',final_status,'auto_closed',final_status='closed'));
 perform charm.finance_notify(p_id,'financeDisbursed','disbursement:'||id,array['admin']);
 return charm.finish(p_key,id);
end$$;

notify pgrst,'reload schema';
commit;

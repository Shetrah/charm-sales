begin;

-- Record the staff member as the receipt recipient without requiring a
-- separately verified payee record. Preserve finance approval, confirmation,
-- account balance, duplicate reference and active staff checks.
create or replace function charm.finance_disburse(
 p_key uuid,p_id bigint,p_account bigint,p_amount text,p_reference text,p_date timestamptz,p_proof bigint,p_confirmed boolean
) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;payee charm.finance_payees;staff_name text;
 typed text:=lower(trim(coalesce(p_amount,'')));v numeric;paid numeric;outstanding numeric;unsettled numeric;old bigint;id bigint;balance numeric;snapshot jsonb;final_status text;
begin
 perform charm.require_finance();old:=charm.claim(p_key,'finance_disburse',jsonb_build_array(p_id,p_account,typed,p_reference,p_date,p_proof,p_confirmed));if old is not null then return old;end if;
 select * into r from charm.finance_requests where finance_requests.id=p_id for update;
 if r.status not in ('approved','part_paid') or r.approved_amount is null or r.approved_at is null or r.approved_by is null or r.approved_by=r.owner_id or r.budget_id is null then raise exception 'financeLocked';end if;
 if r.kind='staff' and a=r.owner_id then raise exception 'selfApproval';end if;
 if p_confirmed is distinct from true or coalesce(length(trim(p_reference)),0) not between 1 and 200 or p_date is null or p_date>now() or p_date<date_trunc('minute',r.approved_at) then raise exception 'paymentConfirmationRequired';end if;
 if not exists(select 1 from charm.finance_accounts where finance_accounts.id=p_account and active) then raise exception 'invalid';end if;
 if p_proof is not null and not exists(select 1 from charm.finance_documents where finance_documents.id=p_proof and request_id=p_id and kind='payment' and uploaded_by=a) then raise exception 'invalid';end if;
 select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=p_id;
 outstanding:=r.approved_amount-paid;v:=case when typed='' then outstanding else charm.finance_money(p_amount) end;
 if v<=0 or paid+v>r.approved_amount then raise exception 'overpayment';end if;
 if r.kind='expense' then
  select * into payee from charm.finance_payees where finance_payees.id=r.payee_id;
  snapshot:=jsonb_build_object('name',coalesce(nullif(trim(payee.name),''),nullif(trim(coalesce(r.recipient,'')),''),'Expense recipient'),'details',coalesce(nullif(payee.details,''),'Recipient recorded with payment'),'kind','expense');
 elsif r.kind='staff' then
  select name into staff_name from charm.users where users.id=r.owner_id and active;
  if staff_name is null then raise exception 'staffInactive';end if;
  select * into payee from charm.finance_payees where staff_id=r.owner_id;
  snapshot:=jsonb_build_object('name',coalesce(payee.name,staff_name),'details',coalesce(nullif(payee.details,''),'Staff payment'),'kind','staff','staff_id',r.owner_id);
 else
  select * into payee from charm.finance_payees where finance_payees.id=r.payee_id;
  snapshot:=jsonb_build_object('name',coalesce(nullif(trim(payee.name),''),nullif(trim(coalesce(r.recipient,'')),''),'Supplier / recipient'),'details',coalesce(nullif(payee.details,''),'Recipient recorded with payment'),'kind',r.kind,'payee_id',r.payee_id);
 end if;
 -- Keep the separate outstanding-advance safeguard; only recipient verification
 -- has been removed from the recording flow.
 if r.kind='staff' then
  select coalesce(sum(d.paid-coalesce(e.settled,0)),0) into unsettled from charm.finance_requests x
  join lateral(select coalesce(sum(amount),0) paid from charm.finance_disbursements where request_id=x.id)d on true
  join lateral(select coalesce(sum(amount),0) settled from charm.finance_accountability where request_id=x.id and status='accepted')e on true
  where x.owner_id=r.owner_id and x.kind='staff' and x.id<>p_id and x.status<>'closed';
  if unsettled>0 then raise exception 'advanceOutstanding';end if;
 end if;
 perform 1 from charm.finance_accounts where finance_accounts.id=p_account for update;
 select coalesce(sum(case when direction='in' then amount else -amount end),0) into balance from charm.finance_cashbook where account_id=p_account;
 if balance<v then raise exception 'insufficientFunds';end if;
 insert into charm.finance_disbursements(request_id,account_id,amount,reference,paid_at,payee_snapshot,proof_id,recorded_by)
 values(p_id,p_account,v,trim(p_reference),p_date,snapshot,p_proof,a) returning finance_disbursements.id into id;
 insert into charm.finance_ledger(request_id,account_id,direction,amount,kind,reference,occurred_at,recorded_by,disbursement_id)
 values(p_id,p_account,'out',v,case when r.kind='staff' then 'advance' when r.kind='expense' then 'expense' else 'supplier' end,trim(p_reference),p_date,a,id);
 final_status:=case when paid+v=r.approved_amount then 'closed' else 'part_paid' end;
 update charm.finance_requests set status=final_status,updated_at=now() where finance_requests.id=p_id;
 perform charm.audit('financeDisbursed','finance_requests',p_id,jsonb_build_object('disbursement_id',id,'amount',v,'account_id',p_account,'reference',trim(p_reference),'recipient',snapshot->>'name','status',final_status));
 perform charm.finance_notify(p_id,'financeDisbursed','disbursement:'||id,array['admin']);return charm.finish(p_key,id);
end$$;

revoke execute on function charm.finance_disburse(uuid,bigint,bigint,text,text,timestamptz,bigint,boolean) from public,anon;
grant execute on function charm.finance_disburse(uuid,bigint,bigint,text,text,timestamptz,bigint,boolean) to authenticated;
notify pgrst,'reload schema';
commit;

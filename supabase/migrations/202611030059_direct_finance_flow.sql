begin;
-- Close out the former accountability workflow while retaining old rows as audit history.
alter table charm.leave_types alter column requires_document set default false;
update charm.leave_types set requires_document=false where requires_document;


alter table charm.finance_disbursements alter column proof_id drop not null;
alter table charm.finance_accountability alter column proof_id drop not null;

create or replace function charm.finance_disburse(p_key uuid,p_id bigint,p_account bigint,p_amount text,p_reference text,p_date timestamptz,p_proof bigint,p_confirmed boolean) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();r charm.finance_requests;payee charm.finance_payees;typed text:=lower(trim(coalesce(p_amount,'')));v numeric;paid numeric;outstanding numeric;old bigint;id bigint;balance numeric;snapshot jsonb;final_status text;
begin
 perform charm.require_finance();old:=charm.claim(p_key,'finance_disburse',jsonb_build_array(p_id,p_account,typed,p_reference,p_date,p_confirmed));if old is not null then return old;end if;
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
  if payee.id is null and coalesce(length(trim(coalesce(r.recipient,''))),0)=0 then raise exception 'payeeMissing';end if;
  snapshot:=jsonb_build_object('name',coalesce(payee.name,nullif(trim(r.recipient),'')),'details',coalesce(nullif(payee.details,''),'Company expense recipient'),'kind','expense');
 else
  select * into payee from charm.finance_payees where (r.kind='staff' and staff_id=r.owner_id) or (r.kind='supplier' and finance_payees.id=r.payee_id);
  if payee.id is null then raise exception 'payeeMissing';end if;snapshot:=to_jsonb(payee);
  if r.kind='staff' and not exists(select 1 from charm.users where users.id=r.owner_id and active) then raise exception 'staffInactive';end if;
 end if;
 perform 1 from charm.finance_accounts where finance_accounts.id=p_account for update;
 select coalesce(sum(case when direction='in' then amount else -amount end),0) into balance from charm.finance_cashbook where account_id=p_account;
 if balance<v then raise exception 'insufficientFunds';end if;
 insert into charm.finance_disbursements(request_id,account_id,amount,reference,paid_at,payee_snapshot,proof_id,recorded_by) values(p_id,p_account,v,trim(p_reference),p_date,snapshot,p_proof,a) returning finance_disbursements.id into id;
 insert into charm.finance_ledger(request_id,account_id,direction,amount,kind,reference,occurred_at,recorded_by,disbursement_id) values(p_id,p_account,'out',v,case when r.kind='staff' then 'advance' when r.kind='expense' then 'expense' else 'supplier' end,trim(p_reference),p_date,a,id);
 final_status:=case when paid+v=r.approved_amount then 'closed' else 'part_paid' end;
 update charm.finance_requests set status=final_status,updated_at=now() where finance_requests.id=p_id;
 perform charm.audit('financeDisbursed','finance_requests',p_id,jsonb_build_object('disbursement_id',id,'amount',v,'account_id',p_account,'reference',trim(p_reference),'recipient',snapshot->>'name','status',final_status));
 perform charm.finance_notify(p_id,'financeDisbursed','disbursement:'||id,array['admin']);return charm.finish(p_key,id);
end$$;

drop view charm.finance_request_balances;
create view charm.finance_request_balances with(security_invoker=true) as
 select r.*,u.name owner_name,c.name category_name,coalesce(d.paid,0)::numeric(14,2) paid,coalesce(e.spent,0)::numeric(14,2) spent,coalesce(e.refunded,0)::numeric(14,2) refunded,greatest(coalesce(r.approved_amount,0)-coalesce(d.paid,0),0)::numeric(14,2) outstanding,0::numeric(14,2) pending_accountability
 from charm.finance_requests r join charm.users u on u.id=r.owner_id join charm.finance_categories c on c.id=r.category_id
 left join lateral(select sum(amount) paid from charm.finance_disbursements where request_id=r.id)d on true
 left join lateral(select sum(amount) filter(where status='accepted' and kind='expense') spent,sum(amount) filter(where status='accepted' and kind='refund') refunded from charm.finance_accountability where request_id=r.id)e on true;
grant select on charm.finance_request_balances to authenticated;
create or replace function charm.finance_budget_committed(p_id bigint) returns numeric language sql stable security definer set search_path='' as $$select coalesce(sum(approved_amount),0) from charm.finance_requests where budget_id=p_id and status in ('approved','part_paid')$$;
create or replace function charm.finance_close_request(p_id bigint,p_reason text) returns void language plpgsql security definer set search_path='' as $$declare r charm.finance_requests;paid numeric;begin perform charm.require_finance();select * into r from charm.finance_requests where id=p_id for update;if r.id is null or r.status not in ('approved','part_paid','paid') then raise exception 'financeLocked';end if;select coalesce(sum(amount),0) into paid from charm.finance_disbursements where request_id=p_id;if paid<r.approved_amount then raise exception 'financeLocked';end if;update charm.finance_requests set status='closed',updated_at=now() where id=p_id;perform charm.audit('financeClosed','finance_requests',p_id,jsonb_build_object('paid',paid));end$$;create or replace function charm.submit_leave_request(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();lr charm.leave_requests;lt charm.leave_types;remaining numeric;
begin
 select * into lr from charm.leave_requests where id=p_id for update;
 if not found then raise exception 'notFound';end if;
 if lr.salesperson_id<>a and not charm.is_admin() then raise exception 'forbidden';end if;
 if lr.status<>'draft' then raise exception 'locked';end if;
 select * into lt from charm.leave_types where id=lr.leave_type_id;
 if lt.id is null then raise exception 'invalidLeaveType';end if;
 if lr.days<=0 then raise exception 'noWorkingDays';end if;
 if lt.paid and lt.annual_days>0 then
  select lt.annual_days-coalesce(sum(x.days),0) into remaining from charm.leave_requests x where x.salesperson_id=lr.salesperson_id and x.leave_type_id=lt.id and x.status='approved' and extract(year from x.start_date)=extract(year from lr.start_date);
  if lr.days>remaining then raise exception 'insufficientLeaveBalance';end if;
 end if;
 update charm.leave_requests set status='pending',updated_at=now() where id=p_id;
 perform charm.audit('leaveSubmitted','leave_requests',p_id,jsonb_build_object('days',lr.days,'type',lt.name));
 insert into charm.finance_notifications(recipient_id,event,event_key,entity,entity_id) select u.id,'leaveSubmitted','leave-submitted:'||p_id||':'||u.id,'leave_requests',p_id from charm.users u where u.active and u.role='admin' on conflict do nothing;
end$$;

create or replace function charm.finance_register(p_view text,p_from date,p_to date,p_status text default '',p_owner bigint default null,p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_actor();rows jsonb;total bigint;begin
 if p_page is null or p_page<1 or p_page>10000 or p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 if p_view='requests' then
  select count(*) into total from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and (p_status in ('awaiting_payment','partial_payments') or p_status='' or required_date between p_from and p_to) and (p_status='' or status=p_status or (p_status='awaiting_payment' and status='approved') or (p_status='partial_payments' and status='part_paid'));
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text,'approved_amount',approved_amount::text,'paid',paid::text,'spent',spent::text,'refunded',refunded::text,'outstanding',outstanding::text,'pending_accountability',pending_accountability::text)),'[]') into rows from(select * from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and (p_status in ('awaiting_payment','partial_payments') or p_status='' or required_date between p_from and p_to) and (p_status='' or status=p_status or (p_status='awaiting_payment' and status='approved') or (p_status='partial_payments' and status='part_paid')) order by id desc limit 100 offset (p_page-1)*100)x;
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
  select count(*) into total from charm.finance_statement_feed where (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.finance_statement_feed where (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to order by occurred_at desc,id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='receipts' and charm.finance_reader() then
  select count(*) into total from charm.payments where (received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or status=p_status);
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text)),'[]') into rows from(select * from charm.payments where (received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or status=p_status) order by id desc limit 100 offset (p_page-1)*100)x;
 else raise exception 'forbidden';end if;
 return jsonb_build_object('rows',rows,'total',total);
end$$;

create or replace function charm.finance_detail(p_id bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$declare r jsonb;begin
 if not charm.finance_access(p_id) then raise exception 'forbidden';end if;
 select to_jsonb(x)||jsonb_build_object('amount',amount::text,'approved_amount',approved_amount::text,'paid',paid::text,'spent',spent::text,'refunded',refunded::text,'outstanding',outstanding::text) into r from charm.finance_request_balances x where id=p_id;
 return jsonb_build_object('request',r,'payments',(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text) order by id),'[]') from charm.finance_disbursements x where request_id=p_id),'history',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from(select l.id,l.actor_id,u.name actor_name,l.action,l.details,l.created_at from charm.audit_logs l join charm.users u on u.id=l.actor_id where (l.entity='finance_requests' and l.entity_id=p_id) or (l.entity='expenses' and l.entity_id=(select source_expense_id from charm.finance_requests where id=p_id)) order by l.id desc limit 200)x));
end$$;-- An imported line that is identical to a movement already on record reconciles itself on import,
-- under exactly the equality rule finance_match_statement enforces, so nothing is matched twice.
create or replace function charm.finance_statement(p_key uuid,p_account bigint,p_reference text,p_direction text,p_amount text,p_date date) returns bigint language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();old bigint;line_id bigint;v numeric:=charm.finance_money(p_amount);matched bigint;begin
 perform charm.require_finance();old:=charm.claim(p_key,'finance_statement',jsonb_build_array(p_account,p_reference,p_direction,p_amount,p_date));if old is not null then return old;end if;
 if coalesce(length(trim(p_reference)),0) not between 1 and 200 or p_direction is null or p_direction not in ('in','out') or p_date is null or p_date>(now() at time zone 'Africa/Nairobi')::date then raise exception 'invalid';end if;
 if not exists(select 1 from charm.finance_accounts where finance_accounts.id=p_account and active) then raise exception 'invalid';end if;
 insert into charm.finance_statement_lines(account_id,reference,direction,amount,occurred_at,imported_by) values(p_account,trim(p_reference),p_direction,v,p_date,a) returning finance_statement_lines.id into line_id;
 select l.id into matched from charm.finance_ledger l where l.account_id=p_account and l.direction=p_direction and l.amount=v and lower(trim(l.reference))=lower(trim(p_reference)) and (l.occurred_at at time zone 'Africa/Nairobi')::date=p_date and not exists(select 1 from charm.finance_statement_lines m where m.ledger_id=l.id) order by l.id limit 1;
 if matched is not null then
  update charm.finance_statement_lines set ledger_id=matched,matched_by=a,matched_at=now() where id=line_id;
  perform charm.audit('statementMatched','finance_statement_lines',line_id,jsonb_build_object('ledger_id',matched,'reference',p_reference,'automatic',true));
 end if;
 perform charm.audit('statementImported','finance_statement_lines',line_id,jsonb_build_object('amount',v,'reference',p_reference,'ledger_id',matched));return charm.finish(p_key,line_id);
end$$;

revoke execute on function charm.finance_submit_accountability(uuid,bigint,text,text,text,bigint,text,bigint,date),charm.finance_review_accountability(bigint,boolean,text,boolean) from public,anon,authenticated;

notify pgrst,'reload schema';
commit;

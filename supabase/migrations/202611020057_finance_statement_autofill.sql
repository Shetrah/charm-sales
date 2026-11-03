-- Bank / M-Pesa reconciliation must reflect the money that actually moved.
-- Every recorded cash movement now appears as a statement line automatically, so the
-- screen is a worklist of what still needs a bank confirmation instead of an empty form.
begin;

create or replace view charm.finance_statement_feed with(security_invoker=true) as
 select l.id,l.occurred_at,l.account_id,acc.name as account_name,l.kind,l.direction,l.reference,l.amount,l.id as ledger_id,l.statement_id,
  case when l.statement_id is not null then 'reconciled' else 'unmatched' end status,'system'::text source
  from charm.finance_cashbook l join charm.finance_accounts acc on acc.id=l.account_id
 union all
 select s.id,(s.occurred_at at time zone 'Africa/Nairobi')::timestamptz,s.account_id,acc.name,'imported'::text,s.direction,s.reference,s.amount,s.ledger_id,s.id,'unmatched'::text,'imported'::text
  from charm.finance_statement_lines s join charm.finance_accounts acc on acc.id=s.account_id where s.ledger_id is null;
grant select on charm.finance_statement_feed to authenticated;

create or replace function charm.finance_register(p_view text,p_from date,p_to date,p_status text default '',p_owner bigint default null,p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_actor();rows jsonb;total bigint;begin
 if p_page is null or p_page<1 or p_page>10000 or p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 if p_view='requests' then
  select count(*) into total from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and (p_status in ('awaiting_payment','partial_payments','needs_accountability','outstanding','overdue') or p_status='' or required_date between p_from and p_to) and (p_status='' or status=p_status
 or (p_status='awaiting_payment' and status in ('approved','part_paid'))
 or (p_status='partial_payments' and status='part_paid')
 or (p_status='needs_accountability' and status in ('part_paid','paid'))
 or (p_status='outstanding' and outstanding>0)
 or (p_status='overdue' and outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date));
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text,'approved_amount',approved_amount::text,'paid',paid::text,'spent',spent::text,'refunded',refunded::text,'outstanding',outstanding::text,'pending_accountability',pending_accountability::text)),'[]') into rows from(select * from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and (p_status in ('awaiting_payment','partial_payments','needs_accountability','outstanding','overdue') or p_status='' or required_date between p_from and p_to) and (p_status='' or status=p_status
 or (p_status='awaiting_payment' and status in ('approved','part_paid'))
 or (p_status='partial_payments' and status='part_paid')
 or (p_status='needs_accountability' and status in ('part_paid','paid'))
 or (p_status='outstanding' and outstanding>0)
 or (p_status='overdue' and outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date)) order by id desc limit 100 offset (p_page-1)*100)x;
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

-- An imported line that is identical to a movement already on record reconciles itself on import,
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

notify pgrst,'reload schema';
commit;

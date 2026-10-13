begin;
create view charm.finance_request_balances with(security_invoker=true) as
 select r.*,u.name owner_name,c.name category_name,
 coalesce(d.paid,0)::numeric(14,2) paid,coalesce(e.spent,0)::numeric(14,2) spent,coalesce(e.refunded,0)::numeric(14,2) refunded,
 (case when r.kind='staff' then coalesce(d.paid,0)-coalesce(e.spent,0)-coalesce(e.refunded,0) else 0 end)::numeric(14,2) outstanding,
 coalesce(e.pending,0)::numeric(14,2) pending_accountability
 from charm.finance_requests r join charm.users u on u.id=r.owner_id join charm.finance_categories c on c.id=r.category_id
 left join lateral(select sum(amount) paid from charm.finance_disbursements where request_id=r.id)d on true
 left join lateral(select sum(amount) filter(where status='accepted' and kind='expense') spent,sum(amount) filter(where status='accepted' and kind='refund') refunded,sum(amount) filter(where status='pending') pending from charm.finance_accountability where request_id=r.id)e on true;
grant select on charm.finance_request_balances to authenticated;
create view charm.finance_expenditure with(security_invoker=true) as
 select 'E-'||a.id::text id,a.request_id,r.owner_id,u.name owner_name,c.name category_name,a.expense_date,a.amount,a.description,'expense'::text kind,a.status,a.reference
 from charm.finance_accountability a join charm.finance_requests r on r.id=a.request_id join charm.users u on u.id=r.owner_id join charm.finance_categories c on c.id=r.category_id where a.kind='expense' and a.status='accepted'
 union all
 select 'S-'||d.id::text,d.request_id,r.owner_id,u.name,c.name,(d.paid_at at time zone 'Africa/Nairobi')::date,d.amount,r.purpose,'supplier'::text,'accepted'::text,d.reference
 from charm.finance_disbursements d join charm.finance_requests r on r.id=d.request_id join charm.users u on u.id=r.owner_id join charm.finance_categories c on c.id=r.category_id where r.kind='supplier';
grant select on charm.finance_expenditure to authenticated;
create function charm.finance_metadata() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform charm.require_actor();return jsonb_build_object(
 'categories',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_categories c where active),
 'accounts',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('balance',(select coalesce(sum(case when direction='in' then amount else -amount end),0)::text from charm.finance_cashbook where account_id=c.id)) order by name),'[]') from charm.finance_accounts c where active and charm.finance_reader()),
 'refund_accounts',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_accounts c where active),
 'payees',(select coalesce(jsonb_agg(to_jsonb(c) order by name),'[]') from charm.finance_payees c where staff_id=charm.actor() or charm.finance_reader()),
 'staff',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'active',active) order by name),'[]') from charm.users where charm.finance_reader()));
end$$;
create function charm.finance_summary(p_from date,p_to date,p_owner bigint default null) returns jsonb language plpgsql stable security definer set search_path='' as $$declare a bigint:=charm.require_actor();result jsonb;begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>3660 then raise exception 'invalid';end if;
 select jsonb_build_object('pending',count(*) filter(where status='pending'),'approved',coalesce(sum(approved_amount) filter(where status in ('approved','part_paid','paid','closed')),0)::text,'outstanding',coalesce(sum(outstanding),0)::text,'overdue',count(*) filter(where outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date),'expenses',coalesce(sum(spent),0)::text) into result from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and required_date between p_from and p_to;
 result:=result||jsonb_build_object('disbursed',(select coalesce(sum(d.amount),0)::text from charm.finance_disbursements d join charm.finance_requests r on r.id=d.request_id where (r.owner_id=a or charm.finance_reader()) and (p_owner is null or r.owner_id=p_owner) and (d.paid_at at time zone 'Africa/Nairobi')::date between p_from and p_to),
 'cashflow',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select to_char(occurred_at at time zone 'Africa/Nairobi','YYYY-MM') as month,coalesce(sum(amount) filter(where direction='in'),0)::text incoming,coalesce(sum(amount) filter(where direction='out'),0)::text outgoing from charm.finance_cashbook l where (charm.finance_reader() or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=a)) and (p_owner is null or exists(select 1 from charm.finance_requests where id=l.request_id and owner_id=p_owner)) and (occurred_at at time zone 'Africa/Nairobi')::date between p_from and p_to and kind<>'opening' group by 1 order by 1)x),
 'categories',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select category_name,sum(amount)::text amount from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to group by category_name order by category_name)x),
 'expenses',(select coalesce(sum(amount),0)::text from charm.finance_expenditure where charm.finance_access(request_id) and (p_owner is null or owner_id=p_owner) and expense_date between p_from and p_to),
 'outstanding',(select coalesce(sum(outstanding),0)::text from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner)),
 'overdue',(select count(*) from charm.finance_request_balances where charm.finance_access(id) and (p_owner is null or owner_id=p_owner) and outstanding>0 and accountability_due<(now() at time zone 'Africa/Nairobi')::date));return result;
end$$;
create function charm.finance_register(p_view text,p_from date,p_to date,p_status text default '',p_owner bigint default null,p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
create function charm.finance_detail(p_id bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$declare r jsonb;begin
 if not charm.finance_access(p_id) then raise exception 'forbidden';end if;
 select to_jsonb(x)||jsonb_build_object('amount',amount::text,'approved_amount',approved_amount::text,'paid',paid::text,'spent',spent::text,'refunded',refunded::text,'outstanding',outstanding::text,'pending_accountability',pending_accountability::text) into r from charm.finance_request_balances x where id=p_id;
 return jsonb_build_object('request',r,'documents',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from charm.finance_documents x where request_id=p_id),
 'payments',(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text) order by id),'[]') from charm.finance_disbursements x where request_id=p_id),
 'accountability',(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',amount::text) order by id),'[]') from charm.finance_accountability x where request_id=p_id),
 'history',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]') from(select l.id,l.actor_id,u.name actor_name,l.action,l.details,l.created_at from charm.audit_logs l join charm.users u on u.id=l.actor_id where (l.entity='finance_requests' and l.entity_id=p_id) or (l.entity='expenses' and l.entity_id=(select source_expense_id from charm.finance_requests where id=p_id)) order by l.id desc limit 200)x));
end$$;
do $$ declare f record;begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='charm' and p.proname in ('finance_metadata','finance_summary','finance_register','finance_detail') loop
  execute format('revoke execute on function %s from public,anon',f.signature);execute format('grant execute on function %s to authenticated',f.signature);
 end loop;end$$;
notify pgrst,'reload schema';
commit;

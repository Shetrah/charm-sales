begin;

-- Keep operational order state (confirmed/delivered workflow) separate from settlement state.
alter table charm.orders add column if not exists payment_status text not null default 'unpaid'
  check (payment_status in ('unpaid','partial','paid'));

create or replace function charm.sync_order_payment_status() returns trigger
language plpgsql security definer set search_path='' as $$
declare target_order bigint; total_due numeric; verified_total numeric;
begin
 target_order:=case when tg_op='DELETE' then old.order_id else new.order_id end;
 select o.total,coalesce(sum(p.amount) filter(where p.status='verified'),0)
  into total_due,verified_total
  from charm.orders o left join charm.payments p on p.order_id=o.id
  where o.id=target_order group by o.id,o.total;
 if total_due is not null then
  update charm.orders set payment_status=case when verified_total>=total_due then 'paid' when verified_total>0 then 'partial' else 'unpaid' end where id=target_order;
 end if;
 if tg_op='UPDATE' and new.order_id is distinct from old.order_id then
  select o.total,coalesce(sum(p.amount) filter(where p.status='verified'),0)
   into total_due,verified_total from charm.orders o left join charm.payments p on p.order_id=o.id
   where o.id=old.order_id group by o.id,o.total;
  if total_due is not null then update charm.orders set payment_status=case when verified_total>=total_due then 'paid' when verified_total>0 then 'partial' else 'unpaid' end where id=old.order_id; end if;
 end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end$$;
drop trigger if exists sync_order_payment_status on charm.payments;
create trigger sync_order_payment_status after insert or update of order_id,status,amount or delete on charm.payments
for each row execute function charm.sync_order_payment_status();
update charm.orders o set payment_status=case when coalesce((select sum(p.amount) from charm.payments p where p.order_id=o.id and p.status='verified'),0)>=o.total then 'paid' when coalesce((select sum(p.amount) from charm.payments p where p.order_id=o.id and p.status='verified'),0)>0 then 'partial' else 'unpaid' end;

create or replace function charm.sync_sales_invoice_payment_status() returns trigger
language plpgsql security definer set search_path='' as $$
declare target_order bigint; invoice_total numeric; verified_total numeric;
begin
 target_order:=case when tg_op='DELETE' then old.order_id else new.order_id end;
 select i.total,coalesce(sum(p.amount) filter(where p.status='verified'),0) into invoice_total,verified_total
  from charm.finance_sales_invoices i left join charm.payments p on p.order_id=i.order_id
  where i.order_id=target_order and i.status<>'void' group by i.id;
 if invoice_total is not null then
  update charm.finance_sales_invoices set status=case when verified_total>=invoice_total then 'paid' else 'issued' end where order_id=target_order and status<>'void';
 end if;
 if tg_op='UPDATE' and new.order_id is distinct from old.order_id then
  select i.total,coalesce(sum(p.amount) filter(where p.status='verified'),0) into invoice_total,verified_total from charm.finance_sales_invoices i left join charm.payments p on p.order_id=i.order_id where i.order_id=old.order_id and i.status<>'void' group by i.id;
  if invoice_total is not null then update charm.finance_sales_invoices set status=case when verified_total>=invoice_total then 'paid' else 'issued' end where order_id=old.order_id and status<>'void'; end if;
 end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end$$;
drop trigger if exists sync_sales_invoice_payment_status on charm.payments;
create trigger sync_sales_invoice_payment_status after insert or update of order_id,status,amount or delete on charm.payments
for each row execute function charm.sync_sales_invoice_payment_status();
drop trigger if exists sync_invoice_after_creation on charm.finance_sales_invoices;
create trigger sync_invoice_after_creation after insert or update of order_id,total on charm.finance_sales_invoices
for each row execute function charm.sync_sales_invoice_payment_status();
update charm.finance_sales_invoices i set status=case when coalesce((select sum(p.amount) from charm.payments p where p.order_id=i.order_id and p.status='verified'),0)>=i.total then 'paid' else 'issued' end where i.status in ('issued','paid');

create or replace function charm.finance_assign_customer_payment_account(p_id bigint,p_account bigint,p_confirmed boolean) returns void
language plpgsql security definer set search_path='' as $$
declare actor_id bigint:=charm.require_finance(); payment_row charm.payments; ledger_id bigint;
begin
 if p_confirmed is distinct from true then raise exception 'paymentConfirmationRequired'; end if;
 if not exists(select 1 from charm.finance_accounts where id=p_account and active) then raise exception 'invalid'; end if;
 select * into payment_row from charm.payments where id=p_id for update;
 if payment_row.id is null or payment_row.status<>'verified' then raise exception 'financeLocked'; end if;
 if exists(select 1 from charm.finance_receipt_allocations where payment_id=p_id) then raise exception 'accountAlreadyAssigned'; end if;
 select id into ledger_id from charm.finance_ledger where customer_payment_id=p_id;
 if ledger_id is null then
  insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by,customer_payment_id)
  values(p_account,'in',payment_row.amount,'customer_receipt',left(payment_row.reference||'-PAY-'||p_id::text,200),coalesce(payment_row.received_at,now()),actor_id,p_id)
  on conflict(customer_payment_id) do nothing;
  select id into ledger_id from charm.finance_ledger where customer_payment_id=p_id;
 end if;
 insert into charm.finance_receipt_allocations(payment_id,ledger_id,account_id,reference,confirmed_by)
 values(p_id,ledger_id,p_account,left(payment_row.reference||'-PAY-'||p_id::text,200),actor_id);
 perform charm.audit('customerPaymentAccountAssigned','payments',p_id,jsonb_build_object('account_id',p_account,'amount',payment_row.amount,'reference',payment_row.reference));
end$$;

create or replace function charm.finance_customer_payment_register(p_from date,p_to date,p_status text default '',p_page integer default 1) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb; total bigint;
begin
 if not charm.finance_reader() or p_from is null or p_to is null or p_to<p_from or p_page is null or p_page<1 or p_page>10000 then raise exception 'invalid'; end if;
 select count(*) into total from charm.payments p where (p.received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or p.status=p_status);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]'::jsonb) into rows from (
  select p.id,p.order_id,c.name client_name,i.invoice_number,p.amount::text amount,p.reference,p.status,p.received_at,p.proof_path,p.verified_at,
   coalesce(a.account_id,e.account_id,l.account_id) account_id,a.payment_id is not null account_allocated,ac.name account_name,
   coalesce(e.entered_role,case when p.submitted_by=charm.actor() then charm.finance_role() else 'salesperson' end) entered_role,
   (p.status='pending' and p.submitted_by<>charm.actor() and (e.payment_id is null or ((e.entered_role='admin' and charm.finance_role()='finance_officer') or (e.entered_role='finance_officer' and charm.finance_role()='admin')))) can_verify
  from charm.payments p join charm.orders o on o.id=p.order_id join charm.clients c on c.id=o.client_id
  left join charm.finance_sales_invoices i on i.order_id=o.id
  left join charm.finance_receipt_allocations a on a.payment_id=p.id
  left join charm.finance_invoice_payment_entries e on e.payment_id=p.id
  left join charm.finance_ledger l on l.customer_payment_id=p.id
  left join charm.finance_accounts ac on ac.id=a.account_id
  where (p.received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or p.status=p_status)
  order by p.id desc limit 100 offset (p_page-1)*100
 ) x;
 return jsonb_build_object('rows',rows,'total',total);
end$$;

revoke execute on function charm.finance_assign_customer_payment_account(bigint,bigint,boolean) from public,anon;
grant execute on function charm.finance_assign_customer_payment_account(bigint,bigint,boolean) to authenticated;
notify pgrst,'reload schema';
commit;

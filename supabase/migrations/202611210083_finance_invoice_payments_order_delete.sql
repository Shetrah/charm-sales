begin;

-- A payment entered by one finance role must be verified by the other role.
create table if not exists charm.finance_invoice_payment_entries (
  payment_id bigint primary key references charm.payments(id),
  account_id bigint not null references charm.finance_accounts(id),
  entered_role text not null check (entered_role in ('admin','finance_officer')),
  created_at timestamptz not null default now()
);
alter table charm.finance_invoice_payment_entries enable row level security;
revoke all on charm.finance_invoice_payment_entries from public,anon,authenticated;
grant select on charm.finance_invoice_payment_entries to authenticated;
drop policy if exists finance_invoice_payment_entry_read on charm.finance_invoice_payment_entries;
create policy finance_invoice_payment_entry_read on charm.finance_invoice_payment_entries for select to authenticated using(charm.finance_reader());

create function charm.finance_customer_payment_options() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if charm.finance_role() not in ('admin','finance_officer') then raise exception 'forbidden'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('order_id',o.id,'client_name',c.name,'invoice_id',i.id,'invoice_number',i.invoice_number,'total',i.total::text,'paid',coalesce(p.paid,0)::text,'balance',greatest(i.total-coalesce(p.paid,0)-coalesce(p.pending,0),0)::text) order by o.id desc)
  from charm.finance_sales_invoices i join charm.orders o on o.id=i.order_id join charm.clients c on c.id=i.client_id
  left join lateral(select sum(amount) filter(where status='verified') paid,sum(amount) filter(where status='pending') pending from charm.payments where order_id=o.id) p on true
  where i.status in ('issued','paid') and i.total>coalesce(p.paid,0)+coalesce(p.pending,0)),'[]'::jsonb);
end$$;

create function charm.finance_invoice_payment_register(p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb; total bigint;
begin
 if not charm.finance_reader() or p_page is null or p_page<1 or p_page>10000 then raise exception 'forbidden'; end if;
 select count(*) into total from charm.finance_sales_invoices;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]'::jsonb) into rows from (
  select i.id,i.invoice_number,i.order_id,c.name client_name,i.batch_lot,i.subtotal::text subtotal,i.tax_amount::text tax_amount,i.total::text total,i.status,i.etims_status,i.due_date,
   coalesce(p.paid,0)::text paid,greatest(i.total-coalesce(p.paid,0),0)::text balance,greatest(i.total-coalesce(p.paid,0)-coalesce(p.pending,0),0)::text available_to_pay,
   case when i.status='void' then 'void' when coalesce(p.paid,0)>=i.total then 'paid' when coalesce(p.paid,0)>0 then 'partial' else i.status end payment_status,
   coalesce(p.pending,0)::text pending_payment
  from charm.finance_sales_invoices i join charm.clients c on c.id=i.client_id
  left join lateral(select sum(amount) filter(where status='verified') paid,sum(amount) filter(where status='pending') pending from charm.payments where order_id=i.order_id) p on true
  order by i.id desc limit 100 offset (p_page-1)*100
 ) x;
 return jsonb_build_object('rows',rows,'total',total);
end$$;

create function charm.finance_customer_payment_register(p_from date,p_to date,p_status text default '',p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb; total bigint;
begin
 if not charm.finance_reader() or p_from is null or p_to is null or p_to<p_from or p_page is null or p_page<1 or p_page>10000 then raise exception 'invalid'; end if;
 select count(*) into total from charm.payments p where (p.received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or p.status=p_status);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]'::jsonb) into rows from (
  select p.id,p.order_id,c.name client_name,i.invoice_number,p.amount::text amount,p.reference,p.status,p.received_at,p.proof_path,
   a.account_id,coalesce(e.entered_role,'') entered_role,
   (e.payment_id is not null and ((e.entered_role='admin' and charm.finance_role()='finance_officer') or (e.entered_role='finance_officer' and charm.finance_role()='admin'))) can_verify
  from charm.payments p join charm.orders o on o.id=p.order_id join charm.clients c on c.id=o.client_id
  left join charm.finance_sales_invoices i on i.order_id=o.id
  left join charm.finance_receipt_allocations a on a.payment_id=p.id
  left join charm.finance_invoice_payment_entries e on e.payment_id=p.id
  where (p.received_at at time zone 'Africa/Nairobi')::date between p_from and p_to and (p_status='' or p.status=p_status)
  order by p.id desc limit 100 offset (p_page-1)*100
 ) x;
 return jsonb_build_object('rows',rows,'total',total);
end$$;

create function charm.finance_record_invoice_payment(p_key uuid,p_invoice bigint,p_amount text,p_reference text,p_date date,p_account bigint,p_confirmed boolean) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); role_name text:=charm.finance_role(); inv charm.finance_sales_invoices; ord charm.orders; v numeric; paid numeric; pending numeric; id bigint; received timestamptz;
begin
 if role_name not in ('admin','finance_officer') then raise exception 'forbidden'; end if;
 if p_key is null or p_confirmed is distinct from true then raise exception 'paymentConfirmationRequired'; end if;
 if coalesce(p_amount,'') !~ '^\d{1,12}(\.\d{1,2})?$' or coalesce(length(trim(p_reference)),0) not between 1 and 200 or p_date is null or p_date>(now() at time zone 'Africa/Nairobi')::date then raise exception 'invalid'; end if;
 v:=p_amount::numeric;
 if v<=0 or not exists(select 1 from charm.finance_accounts where id=p_account and active) then raise exception 'invalid'; end if;
 select * into inv from charm.finance_sales_invoices where id=p_invoice for update;
 if inv.id is null or inv.status not in ('issued','paid') then raise exception 'invoiceLocked'; end if;
 select * into ord from charm.orders where id=inv.order_id for update;
 select coalesce(sum(amount) filter(where status='verified'),0),coalesce(sum(amount) filter(where status='pending'),0) into paid,pending from charm.payments where order_id=ord.id;
 if paid+pending+v>inv.total then raise exception 'overpayment'; end if;
 received:=p_date::timestamp at time zone 'Africa/Nairobi';
 insert into charm.payments(submission_key,order_id,submitted_by,amount,reference,status,received_at,created_at,updated_at)
 values(p_key,ord.id,a,v,trim(p_reference),'pending',received,now(),now()) returning payments.id into id;
 insert into charm.finance_invoice_payment_entries(payment_id,account_id,entered_role) values(id,p_account,role_name);
 perform charm.audit('invoicePaymentRecorded','payments',id,jsonb_build_object('invoice_id',inv.id,'order_id',ord.id,'amount',v,'reference',trim(p_reference),'received_at',received,'account_id',p_account,'entered_role',role_name));
 return id;
end$$;

create function charm.finance_verify_invoice_payment(p_id bigint,p_confirmed boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); role_name text:=charm.finance_role(); p charm.payments; inv charm.finance_sales_invoices; entry charm.finance_invoice_payment_entries; paid numeric;
begin
 select * into p from charm.payments where id=p_id for update;
 if p.id is null or p.status<>'pending' then raise exception 'financeLocked'; end if;
 select * into entry from charm.finance_invoice_payment_entries where payment_id=p_id;
 if entry.payment_id is null then raise exception 'financeLocked'; end if;
 if p_confirmed is distinct from true then raise exception 'paymentConfirmationRequired'; end if;
 if (entry.entered_role='admin' and role_name<>'finance_officer') or (entry.entered_role='finance_officer' and role_name<>'admin') then raise exception 'forbidden'; end if;
 select * into inv from charm.finance_sales_invoices where order_id=p.order_id for update;
 if inv.id is null then raise exception 'notFound'; end if;
 select coalesce(sum(amount),0) into paid from charm.payments where order_id=p.order_id and status='verified';
 if paid+p.amount>inv.total then raise exception 'overpayment'; end if;
 update charm.payments set status='verified',verified_by=a,verified_at=now(),updated_at=now() where id=p_id;
 insert into charm.finance_receipt_allocations(payment_id,ledger_id,account_id,reference,confirmed_by)
 select p_id,l.id,entry.account_id,p.reference,a from charm.finance_ledger l where l.customer_payment_id=p_id;
 if paid+p.amount>=inv.total then update charm.finance_sales_invoices set status='paid' where id=inv.id; end if;
 perform charm.audit('invoicePaymentVerified','payments',p_id,jsonb_build_object('invoice_id',inv.id,'account_id',entry.account_id,'amount',p.amount,'reference',p.reference,'entry_date',(p.received_at at time zone 'Africa/Nairobi')::date));
end$$;

create function charm.admin_order_file_delete(p_path text) returns boolean language sql stable security definer set search_path='' as $$
 select case when charm.finance_role()='admin' and p_path ~ '^orders/[0-9]+/' then
  exists(select 1 from charm.orders o where o.id=split_part(p_path,'/',2)::bigint
   and (o.contract_path=p_path or exists(select 1 from charm.order_documents d where d.order_id=o.id and d.storage_path=p_path))
   and not exists(select 1 from charm.payments p where p.order_id=o.id)
   and not exists(select 1 from charm.sales_returns r where r.order_id=o.id)
   and not exists(select 1 from charm.commission_entries c where c.order_id=o.id and (c.status in ('approved','paid') or c.commission_amount>0))
   and not exists(select 1 from charm.sales_deliveries d where d.order_id=o.id and d.status in ('dispatched','delivered'))
   and not exists(select 1 from charm.finance_sales_invoices i where i.order_id=o.id and i.etims_status in ('submitted','accepted')))
  else false end
$$;
revoke execute on function charm.admin_order_file_delete(text) from public,anon;
grant execute on function charm.admin_order_file_delete(text) to authenticated;
drop policy if exists charm_admin_order_file_delete on storage.objects;
create policy charm_admin_order_file_delete on storage.objects for delete to authenticated using(bucket_id='charm-private' and charm.admin_order_file_delete(name));

create function charm.admin_payment_file_delete(p_path text) returns boolean language sql stable security definer set search_path='' as $$
 select case when charm.finance_role()='admin' and p_path ~ '^payments/[0-9]+/' then
  exists(select 1 from charm.payments p where p.id=split_part(p_path,'/',2)::bigint and p.status in ('pending','rejected') and p.proof_path=p_path)
  else false end
$$;
revoke execute on function charm.admin_payment_file_delete(text) from public,anon;
grant execute on function charm.admin_payment_file_delete(text) to authenticated;
drop policy if exists charm_admin_payment_file_delete on storage.objects;
create policy charm_admin_payment_file_delete on storage.objects for delete to authenticated using(bucket_id='charm-private' and charm.admin_payment_file_delete(name));

create function charm.admin_delete_customer_payment(p_id bigint,p_prepare boolean default false) returns text language plpgsql security definer set search_path='' as $$
declare p charm.payments;
begin
 if charm.finance_role() is distinct from 'admin' then raise exception 'forbidden'; end if;
 select * into p from charm.payments where id=p_id for update;
 if p.id is null then raise exception 'notFound'; end if;
 if p.status not in ('pending','rejected')
  or exists(select 1 from charm.finance_ledger where customer_payment_id=p_id)
  or exists(select 1 from charm.finance_receipt_allocations where payment_id=p_id) then raise exception 'paymentImmutable'; end if;
 if p_prepare then return p.proof_path; end if;
 delete from charm.finance_invoice_payment_entries where payment_id=p_id;
 delete from charm.request_receipts where submission_key=p.submission_key;
 delete from charm.audit_logs where entity='payments' and entity_id=p_id;
 delete from charm.payments where id=p_id;
 perform charm.audit('paymentPermanentlyDeleted','payment_deletions',p_id,jsonb_build_object('order_id',p.order_id,'amount',p.amount,'reference',p.reference,'status',p.status));
 return p.proof_path;
end$$;

create function charm.admin_delete_order(p_id bigint,p_prepare boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare o charm.orders; paths jsonb;
begin
 if charm.finance_role() is distinct from 'admin' then raise exception 'forbidden'; end if;
 select * into o from charm.orders where id=p_id for update;
 if o.id is null then raise exception 'notFound'; end if;
 if exists(select 1 from charm.payments where order_id=p_id)
  or exists(select 1 from charm.sales_returns where order_id=p_id)
  or exists(select 1 from charm.commission_entries where order_id=p_id and (status in ('approved','paid') or commission_amount>0))
  or exists(select 1 from charm.sales_deliveries where order_id=p_id and status in ('dispatched','delivered'))
  or exists(select 1 from charm.finance_sales_invoices where order_id=p_id and etims_status in ('submitted','accepted')) then raise exception 'orderHasFinancialHistory'; end if;
 select coalesce(jsonb_agg(storage_path),'[]'::jsonb) into paths from charm.order_documents where order_id=p_id;
 if p_prepare then return paths; end if;
 delete from charm.sales_delivery_items where delivery_id in(select id from charm.sales_deliveries where order_id=p_id);
 delete from charm.sales_deliveries where order_id=p_id;
 delete from charm.commission_entries where order_id=p_id;
 delete from charm.order_documents where order_id=p_id;
 delete from charm.order_contract_versions where order_id=p_id;
 delete from charm.audit_logs where (entity='finance_sales_invoices' and entity_id in(select id from charm.finance_sales_invoices where order_id=p_id))
  or (entity='finance_operating_entries' and entity_id in(select id from charm.finance_operating_entries where invoice_id in(select id from charm.finance_sales_invoices where order_id=p_id)));
 delete from charm.finance_operating_entries where invoice_id in(select id from charm.finance_sales_invoices where order_id=p_id);
 delete from charm.finance_sales_invoices where order_id=p_id;
 update charm.chat_conversations set order_id=null where order_id=p_id;
 delete from charm.order_items where order_id=p_id;
 delete from charm.audit_logs where entity='orders' and entity_id=p_id;
 delete from charm.orders where id=p_id;
 perform charm.audit('orderPermanentlyDeleted','orders',p_id,jsonb_build_object('status',o.status,'documents_removed',jsonb_array_length(paths)));
 return paths;
end$$;

revoke execute on function charm.finance_customer_payment_options(),charm.finance_invoice_payment_register(integer),charm.finance_customer_payment_register(date,date,text,integer),charm.finance_record_invoice_payment(uuid,bigint,text,text,date,bigint,boolean),charm.finance_verify_invoice_payment(bigint,boolean),charm.admin_delete_customer_payment(bigint,boolean),charm.admin_delete_order(bigint,boolean) from public,anon;
grant execute on function charm.finance_customer_payment_options(),charm.finance_invoice_payment_register(integer),charm.finance_customer_payment_register(date,date,text,integer),charm.finance_record_invoice_payment(uuid,bigint,text,text,date,bigint,boolean),charm.finance_verify_invoice_payment(bigint,boolean),charm.admin_delete_customer_payment(bigint,boolean),charm.admin_delete_order(bigint,boolean) to authenticated;
notify pgrst,'reload schema';
commit;

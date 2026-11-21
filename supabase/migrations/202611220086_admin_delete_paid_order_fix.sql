begin;

-- Paid orders can own invoice, payment, delivery, return and linked finance-request
-- rows. Remove those dependent rows inside the same transaction before removing
-- the order, while keeping the destructive action restricted to administrators.
create or replace function charm.admin_delete_order(p_id bigint,p_prepare boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o charm.orders; paths jsonb; proof_paths jsonb; request_row record;
begin
 if charm.finance_role() is distinct from 'admin' then raise exception 'forbidden'; end if;
 select * into o from charm.orders where id=p_id for update;
 if o.id is null then raise exception 'notFound'; end if;

 select coalesce(jsonb_agg(storage_path),'[]'::jsonb) into paths
 from charm.order_documents where order_id=p_id;
 select coalesce(jsonb_agg(proof_path),'[]'::jsonb) into proof_paths
 from charm.payments where order_id=p_id and proof_path is not null;
 paths:=paths||proof_paths;
 if p_prepare then return paths; end if;

 perform set_config('charm.admin_order_delete','on',true);

 -- Remove delivery children and headers before order items.
 delete from charm.sales_delivery_items
 where order_item_id in(select id from charm.order_items where order_id=p_id);
 delete from charm.sales_delivery_items
 where delivery_id in(select id from charm.sales_deliveries where order_id=p_id);
 delete from charm.sales_deliveries where order_id=p_id;

 -- Unlink matched bank statement rows before deleting ledger entries.
 update charm.finance_statement_lines set ledger_id=null,matched_by=null,matched_at=null
 where ledger_id in(
  select id from charm.finance_ledger
  where customer_payment_id in(select id from charm.payments where order_id=p_id)
 );
 delete from charm.finance_receipt_allocations
 where payment_id in(select id from charm.payments where order_id=p_id);
 delete from charm.finance_ledger
 where customer_payment_id in(select id from charm.payments where order_id=p_id);
 delete from charm.finance_invoice_payment_entries
 where payment_id in(select id from charm.payments where order_id=p_id);
 delete from charm.request_receipts
 where submission_key in(select submission_key from charm.payments where order_id=p_id);
 delete from charm.audit_logs
 where entity='payments' and entity_id in(select id from charm.payments where order_id=p_id);
 delete from charm.payments where order_id=p_id;

 -- Finance requests may be linked to this order (for example a commission or
 -- an order-related expense). Delete each request's account postings and children
 -- before deleting the request so paid orders do not leave blocking foreign keys.
 for request_row in select id,source_expense_id from charm.finance_requests where order_id=p_id for update loop
  perform set_config('charm.admin_request_delete','on',true);
  update charm.finance_statement_lines set ledger_id=null,matched_by=null,matched_at=null
   where ledger_id in(select id from charm.finance_ledger where request_id=request_row.id);
  delete from charm.finance_ledger where request_id=request_row.id;
  delete from charm.finance_accountability where request_id=request_row.id;
  delete from charm.finance_disbursements where request_id=request_row.id;
  delete from charm.finance_notifications where request_id=request_row.id;
  delete from charm.finance_expense_items where request_id=request_row.id;
  delete from charm.finance_operating_entries where request_id=request_row.id;
  delete from charm.audit_logs where entity='finance_requests' and entity_id=request_row.id;
  delete from charm.finance_documents where request_id=request_row.id;
  delete from charm.finance_requests where id=request_row.id;
  if request_row.source_expense_id is not null then
   delete from charm.expenses where id=request_row.source_expense_id;
  end if;
  perform set_config('charm.admin_request_delete','off',true);
 end loop;

 delete from charm.commission_entries where order_id=p_id;
 delete from charm.order_documents where order_id=p_id;
 delete from charm.order_contract_versions where order_id=p_id;
 delete from charm.audit_logs
 where (entity='finance_sales_invoices' and entity_id in(select id from charm.finance_sales_invoices where order_id=p_id))
    or (entity='finance_operating_entries' and entity_id in(select id from charm.finance_operating_entries where invoice_id in(select id from charm.finance_sales_invoices where order_id=p_id)));
 delete from charm.finance_operating_entries
 where invoice_id in(select id from charm.finance_sales_invoices where order_id=p_id);
 delete from charm.finance_sales_invoices where order_id=p_id;
 delete from charm.sales_returns where order_id=p_id;
 update charm.chat_conversations set order_id=null where order_id=p_id;
 delete from charm.order_items where order_id=p_id;
 delete from charm.audit_logs where entity='orders' and entity_id=p_id;
 delete from charm.orders where id=p_id;
 perform charm.audit('orderPermanentlyDeleted','orders',p_id,
  jsonb_build_object('status',o.status,'documents_removed',jsonb_array_length(paths)));
 perform set_config('charm.admin_request_delete','off',true);
 perform set_config('charm.admin_order_delete','off',true);
 return paths;
end$$;

revoke execute on function charm.admin_delete_order(bigint,boolean) from public,anon;
grant execute on function charm.admin_delete_order(bigint,boolean) to authenticated;
notify pgrst,'reload schema';
commit;

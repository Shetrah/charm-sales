begin;

-- Return a precise validation error instead of reporting invalid decisions as
-- missing payment confirmation. Verification still requires explicit attestation.
create or replace function charm.finance_review_customer_payment(
 p_id bigint,p_decision text,p_confirmed boolean,p_account bigint default null
) returns void language plpgsql security definer set search_path='' as $$
declare
 a bigint:=charm.require_finance(); role_name text:=charm.finance_role();
 p charm.payments; o charm.orders; entry charm.finance_invoice_payment_entries;
 paid numeric; inv charm.finance_sales_invoices;
begin
 if p_decision is null or p_decision not in ('verify','reject') then raise exception 'invalidPaymentDecision'; end if;
 if p_confirmed is distinct from true then raise exception 'paymentConfirmationRequired'; end if;
 select * into p from charm.payments where id=p_id for update;
 if p.id is null or p.status<>'pending' then raise exception 'financeLocked'; end if;
 select * into o from charm.orders where id=p.order_id for update;
 if o.id is null or o.status<>'confirmed' then raise exception 'financeLocked'; end if;
 select * into entry from charm.finance_invoice_payment_entries where payment_id=p_id;
 if entry.payment_id is not null then
  if entry.entered_role=role_name then raise exception 'selfApproval'; end if;
  if p_decision='verify' and not exists(select 1 from charm.finance_accounts where id=entry.account_id and active) then raise exception 'invalid'; end if;
 else
  if p.submitted_by=a then raise exception 'selfApproval'; end if;
  if p_decision='verify' and not exists(select 1 from charm.finance_accounts where id=p_account and active) then raise exception 'invalid'; end if;
 end if;
 if p_decision='reject' then
  update charm.payments set status='rejected',verified_by=a,verified_at=now(),updated_at=now() where id=p_id;
  perform charm.audit('rejected','payments',p_id,jsonb_build_object('reference',p.reference,'amount',p.amount));
  return;
 end if;
 if entry.payment_id is null then
  insert into charm.finance_invoice_payment_entries(payment_id,account_id,entered_role)
  values(p_id,p_account,case when role_name='admin' then 'finance_officer' else 'admin' end);
  select * into entry from charm.finance_invoice_payment_entries where payment_id=p_id;
 end if;
 select coalesce(sum(amount),0) into paid from charm.payments where order_id=p.order_id and status='verified';
 if paid+p.amount>o.total then raise exception 'overpayment'; end if;
 update charm.payments set status='verified',verified_by=a,verified_at=now(),updated_at=now() where id=p_id;
 insert into charm.finance_receipt_allocations(payment_id,ledger_id,account_id,reference,confirmed_by)
 select p_id,l.id,coalesce(entry.account_id,p_account),p.reference,a
 from charm.finance_ledger l where l.customer_payment_id=p_id on conflict(payment_id) do nothing;
 select * into inv from charm.finance_sales_invoices where order_id=p.order_id for update;
 if inv.id is not null and paid+p.amount>=inv.total then
  update charm.finance_sales_invoices set status='paid' where id=inv.id;
 end if;
 perform charm.audit('verified','payments',p_id,jsonb_build_object(
  'account_id',coalesce(entry.account_id,p_account),'reference',p.reference,'amount',p.amount));
end$$;

revoke execute on function charm.finance_review_customer_payment(bigint,text,boolean,bigint) from public,anon;
grant execute on function charm.finance_review_customer_payment(bigint,text,boolean,bigint) to authenticated;
notify pgrst,'reload schema';
commit;

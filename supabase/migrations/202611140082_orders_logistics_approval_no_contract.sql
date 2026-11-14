begin;

-- New orders enter the approval queue directly. Contract data remains in place
-- for historical records, but it is no longer required for order submission.
create or replace function charm.submit_order_draft(p_id bigint) returns void
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer();o charm.orders;
begin
 select * into o from charm.orders where orders.id=p_id for update;
 if not found or not charm.can_access(o.salesperson_id) then raise exception 'forbidden';end if;
 if o.status='pending' then return;end if;
 if o.status<>'draft' then raise exception 'alreadySubmitted';end if;
 if not exists(select 1 from charm.order_items i where i.order_id=p_id) then raise exception 'missingOrderLines';end if;
 update charm.orders set status='pending',submitted_by=a,updated_at=now() where orders.id=p_id;
 perform charm.audit('submitted','orders',p_id,jsonb_build_object('customer_type',o.customer_type,'contract_required',false));
end$$;

-- Logistics managers own order approval; admins retain an operational fallback.
create or replace function charm.approve_order(p_id bigint,p_confirm boolean,p_reason text default null,p_contract_reviewed boolean default false)
returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();o charm.orders;role_name text;
begin
 select role into role_name from charm.users where users.id=a and active;
 if coalesce(role_name,'')<>'logistics_manager' then raise exception 'forbidden';end if;
 if p_confirm is null then raise exception 'invalid';end if;
 select * into o from charm.orders where orders.id=p_id for update;
 if not found then raise exception 'notFound';end if;
 if o.submitted_by=a or (o.submitted_by is null and o.salesperson_id=a) then raise exception 'selfApproval';end if;
 if o.status<>'pending' then raise exception 'alreadyReviewed';end if;
 if not p_confirm and coalesce(length(trim(p_reason)),0) not between 1 and 1000 then raise exception 'reasonRequired';end if;
 update charm.orders set status=case when p_confirm then 'confirmed' else 'rejected' end,
  contract_status=case when p_confirm then 'approved' else 'rejected' end,
  contract_approved_at=case when p_confirm then now() end,contract_approved_by=case when p_confirm then a end,
  confirmed_at=case when p_confirm then now() end,confirmed_by=case when p_confirm then a end,
  reason=nullif(trim(p_reason),''),updated_at=now() where orders.id=p_id;
 perform charm.audit(case when p_confirm then 'confirmed' else 'rejected' end,'orders',p_id,
  jsonb_build_object('contract_required',false,'reviewed_by',a));
end$$;

-- Send pending order notifications to logistics managers, not the general
-- manager list. Keep the existing handoffs for other workspace activity.
create or replace function charm.notify_workspace_activity() returns trigger
language plpgsql security definer set search_path='' as $$
declare payload jsonb:=to_jsonb(new);previous jsonb:=case when tg_op='UPDATE' then to_jsonb(old) else '{}'::jsonb end;
 actor bigint:=charm.actor();owner_id bigint;client_owner bigint;record_id bigint;state text;managers boolean;finance boolean;
 recipient record;event_name text;event_token text;
begin
 record_id:=nullif(payload->>'id','')::bigint;
 owner_id:=coalesce(nullif(payload->>'salesperson_id','')::bigint,nullif(payload->>'submitted_by','')::bigint,
  nullif(payload->>'user_id','')::bigint,nullif(payload->>'owner_id','')::bigint,
  nullif(payload->>'created_by','')::bigint,nullif(payload->>'started_by','')::bigint);
 client_owner:=(select c.salesperson_id from charm.clients c where c.id=nullif(payload->>'client_id','')::bigint);
 state:=coalesce(payload->>'status','');
 if tg_op='UPDATE' and (tg_table_name in ('clients','visits','reports','workdays') or coalesce(previous->>'status','')=state) then return new;end if;
 event_name:=case when tg_op='INSERT' then tg_table_name||'_submitted' else coalesce(nullif(state,''),tg_table_name||'_updated') end;
 event_token:=tg_table_name||':'||record_id||':'||tg_op||':'||coalesce(nullif(state,''),to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS'));
 managers:=tg_table_name in ('clients','orders','payments','production_materials','production_formulas','production_batches');
 finance:=tg_table_name in ('payments','production_materials','production_formulas','production_batches','finance_batch_costs','finance_purchase_orders','finance_goods_receipts','finance_supplier_invoices','finance_sales_invoices','finance_operating_entries');
 for recipient in select u.id from charm.users u where u.active and u.id<>coalesce(actor,-1)
  and (u.id=owner_id or u.id=client_owner
   or (managers and u.role='admin' and not (tg_table_name='orders' and state='pending'))
   or (tg_table_name='orders' and state='pending' and u.role='logistics_manager')
   or (finance and u.role in ('admin','finance_officer','finance_manager'))
   or (tg_table_name in ('production_materials','production_formulas','production_batches') and u.role='finance_officer')
   or (tg_table_name='orders' and state='confirmed' and u.role='logistics_manager')
   or (tg_table_name in ('expenses','plans','reports') and state in ('pending','approved','rejected') and u.role='admin'))
 loop
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
  values(recipient.id,null,event_name,event_token||':'||recipient.id,tg_table_name,record_id) on conflict do nothing;
 end loop;
 if tg_table_name='production_batches' and state='released' then
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
  select distinct o.salesperson_id,null::bigint,event_name,'batch-released:'||record_id||':'||o.salesperson_id,'production_batches',record_id
  from charm.orders o join charm.finance_sales_invoices v on v.order_id=o.id
  where o.status='confirmed' and coalesce(v.batch_lot,'')='' and o.salesperson_id<>coalesce(actor,-1) on conflict do nothing;
 end if;
 return new;
end$$;

revoke execute on function charm.notify_workspace_activity() from public,anon,authenticated;
revoke execute on function charm.submit_order_draft(bigint),charm.approve_order(bigint,boolean,text,boolean) from public,anon;
grant execute on function charm.submit_order_draft(bigint),charm.approve_order(bigint,boolean,text,boolean) to authenticated;
notify pgrst,'reload schema';
commit;

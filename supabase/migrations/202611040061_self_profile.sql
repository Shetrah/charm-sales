begin;
create or replace function charm.update_own_profile(p_name text,p_phone text,p_territory text) returns void
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); old charm.users;
begin
 select * into old from charm.users where id=a and active for update;
 if not found then raise exception 'notFound'; end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(p_phone),0)>40 or coalesce(length(p_territory),0)>200 then raise exception 'invalid'; end if;
 update charm.users set name=trim(p_name),phone=nullif(trim(p_phone),''),territory=nullif(trim(p_territory),''),updated_at=now() where id=a;
 perform charm.audit('ownProfileUpdated','users',a,jsonb_build_object('before',jsonb_build_object('name',old.name,'phone',old.phone,'territory',old.territory),'after',jsonb_build_object('name',trim(p_name),'phone',p_phone,'territory',p_territory)));
end $$;
revoke execute on function charm.update_own_profile(text,text,text) from public,anon;
grant execute on function charm.update_own_profile(text,text,text) to authenticated;
-- Explicit finance events target each role which owns a next action; a null role list never becomes a staff broadcast.
create or replace function charm.finance_notify(p_request bigint,p_event text,p_key text,p_roles text[] default '{}',p_owner boolean default true) returns void language sql security definer set search_path='' as $$
 insert into charm.finance_notifications(recipient_id,request_id,event,event_key)
 select u.id,p_request,p_event,p_key||':'||u.id from charm.users u where u.active and (u.role=any(coalesce(p_roles,'{}')) or (p_owner and cardinality(coalesce(p_roles,'{}'))>0 and u.id=(select owner_id from charm.finance_requests where id=p_request))) on conflict do nothing
$$;
-- Confirmed orders are a fulfilment handoff; finance only needs generated invoices and operational finance events.
create or replace function charm.notify_workspace_activity() returns trigger
language plpgsql security definer set search_path='' as $$
declare payload jsonb:=to_jsonb(new); previous jsonb:=case when tg_op='UPDATE' then to_jsonb(old) else '{}'::jsonb end; actor bigint:=charm.actor(); owner_id bigint; client_owner bigint; record_id bigint; state text; managers boolean; finance boolean; recipient record; event_name text; event_token text;
begin
 record_id:=nullif(payload->>'id','')::bigint;
 owner_id:=coalesce(nullif(payload->>'salesperson_id','')::bigint,nullif(payload->>'submitted_by','')::bigint,nullif(payload->>'user_id','')::bigint,nullif(payload->>'owner_id','')::bigint,nullif(payload->>'created_by','')::bigint,nullif(payload->>'started_by','')::bigint);
 client_owner:=(select c.salesperson_id from charm.clients c where c.id=nullif(payload->>'client_id','')::bigint);
 state:=coalesce(payload->>'status','');
 if tg_op='UPDATE' and (tg_table_name in ('clients','visits','reports','workdays') or coalesce(previous->>'status','')=state) then return new; end if;
 event_name:=case when tg_op='INSERT' then tg_table_name||'_submitted' else coalesce(nullif(state,''),tg_table_name||'_updated') end;
 event_token:=tg_table_name||':'||record_id||':'||tg_op||':'||coalesce(nullif(state,''),to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS'));
 managers:=tg_table_name in ('clients','orders','payments','production_materials','production_formulas','production_batches');
 finance:=tg_table_name in ('payments','production_materials','production_formulas','production_batches','finance_batch_costs','finance_purchase_orders','finance_goods_receipts','finance_supplier_invoices','finance_sales_invoices','finance_operating_entries');
 for recipient in select u.id from charm.users u where u.active and u.id<>coalesce(actor,-1)
  and (u.id=owner_id or u.id=client_owner or (managers and u.role='admin') or (finance and u.role in ('admin','finance_officer','finance_manager')) or (tg_table_name in ('production_materials','production_formulas','production_batches') and u.role='finance_officer') or (tg_table_name='orders' and state='confirmed' and u.role='logistics_manager') or (tg_table_name in ('expenses','plans','reports') and state in ('pending','approved','rejected') and u.role='admin'))
 loop
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) values(recipient.id,null,event_name,event_token||':'||recipient.id,tg_table_name,record_id) on conflict do nothing;
 end loop;
 if tg_table_name='production_batches' and state='released' then
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
  select distinct o.salesperson_id,null::bigint,event_name,'batch-released:'||record_id||':'||o.salesperson_id,'production_batches',record_id from charm.orders o join charm.finance_sales_invoices v on v.order_id=o.id where o.status='confirmed' and coalesce(v.batch_lot,'')='' and o.salesperson_id<>coalesce(actor,-1) on conflict do nothing;
 end if;
 return new;
end $$;
revoke execute on function charm.notify_workspace_activity() from public,anon,authenticated;
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='charm' and tablename='finance_notifications') then
  alter publication supabase_realtime add table charm.finance_notifications;
 end if;
end $$;
commit;

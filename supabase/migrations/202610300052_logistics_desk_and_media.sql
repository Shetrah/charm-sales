-- Logistics desk: a fulfilment role that receives confirmed orders, checks availability, plans delivery
-- or arranges production; plus staff identity photos and product imagery.
begin;

alter table charm.users drop constraint if exists users_finance_roles;
alter table charm.users add constraint users_finance_roles check(role in ('admin','salesperson','finance_officer','logistics_manager'));

create or replace function charm.logistics_desk() returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select role in ('admin','logistics_manager') from charm.users where id=charm.actor()),false)
$$;

-- Fulfilment signals live beside orders.status so a confirmed sale stays counted in finance and reporting.
alter table charm.orders add column if not exists production_required boolean not null default false;
alter table charm.orders add column if not exists production_ready_on date;
alter table charm.users add column if not exists photo_path text;
alter table charm.products add column if not exists image_path text;
grant select(photo_path) on charm.users to authenticated;

-- The fulfilment desk plans against the whole order book, so it reads orders, lines, clients, staff and deliveries.
create policy logistics_order_read on charm.orders for select to authenticated using(charm.logistics_desk());
create policy logistics_item_read on charm.order_items for select to authenticated using(charm.logistics_desk());
create policy logistics_client_read on charm.clients for select to authenticated using(charm.logistics_desk());
create policy logistics_user_read on charm.users for select to authenticated using(charm.logistics_desk());
create policy logistics_delivery_read on charm.sales_deliveries for select to authenticated using(charm.logistics_desk());
create policy logistics_delivery_item_read on charm.sales_delivery_items for select to authenticated using(charm.logistics_desk());

-- Identity photos: the person and administrators write; every signed-in colleague may read them.
create or replace function charm.file_access(path text,writing boolean default false) returns boolean
language plpgsql stable security definer set search_path='' as $$
declare kind text:=split_part(path,'/',1); record_id bigint; owner bigint; status text; contract text;
begin
 if charm.actor() is null or split_part(path,'/',2) !~ '^\d+$' then return false; end if;
 record_id:=split_part(path,'/',2)::bigint;
 if kind='visits' then select salesperson_id into owner from charm.visits where visits.id=record_id;
 elsif kind='payments' then select o.salesperson_id,p.status into owner,status from charm.payments p join charm.orders o on o.id=p.order_id where p.id=record_id;
 elsif kind='orders' then select salesperson_id,orders.status,orders.contract_path into owner,status,contract from charm.orders where orders.id=record_id;
 elsif kind='travel' then select salesperson_id,status into owner,status from charm.expenses where expenses.id=record_id;
 elsif kind='staff' then
  if not exists(select 1 from charm.users where id=record_id) then return false; end if;
  if writing and record_id<>charm.actor() and not charm.is_admin() then return false; end if;
  return true;
 elsif kind='products' then
  if not exists(select 1 from charm.products where id=record_id) then return false; end if;
  if writing and not charm.logistics_desk() then return false; end if;
  return true;
 elsif kind='leave' then
  owner:=record_id;
  if writing and owner<>charm.actor() and not charm.is_admin() then return false; end if;
  return owner=charm.actor() or charm.is_admin();
 else return false; end if;
 if kind='orders' then
  if writing then return status='draft' and owner is not null and coalesce(charm.can_access(owner),false); end if;
  return owner is not null and coalesce(charm.can_access(owner),false)
   and (contract=path or exists(select 1 from charm.order_documents d where d.order_id=record_id and d.storage_path=path));
 end if;
 if kind='travel' then
  if writing then return status in ('draft','returned') and owner is not null and coalesce(charm.can_access(owner),false); end if;
  return owner is not null and (coalesce(charm.can_access(owner),false)
   or (charm.finance_reader() and status in ('approved','finance_review','in_progress','completed')));
 end if;
 if writing and kind='payments' and status<>'pending' then return false; end if;
 return owner is not null and coalesce(charm.can_access(owner),false);
end $$;

create or replace function charm.save_staff_photo(p_id bigint,p_path text) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); path text:=coalesce(trim(p_path),'');
begin
 if p_id is null then raise exception 'invalid'; end if;
 if p_id<>a and not charm.is_admin() then raise exception 'forbidden'; end if;
 if not exists(select 1 from charm.users where id=p_id and active) then raise exception 'notFound'; end if;
 if path='' then
  update charm.users set photo_path=null,updated_at=now() where id=p_id;
  perform charm.audit('photoRemoved','users',p_id);
  return;
 end if;
 if path!~('^staff/'||p_id::text||'/[0-9a-z._-]+\.(jpg|jpeg|png|webp)$') or not charm.file_access(path,true)
  or not exists(select 1 from storage.objects where bucket_id='charm-private' and name=path) then raise exception 'mediaUploadRequired'; end if;
 update charm.users set photo_path=path,updated_at=now() where id=p_id;
 perform charm.audit('photoUpdated','users',p_id,jsonb_build_object('path',path));
end $$;

create or replace function charm.save_product_image(p_product bigint,p_path text) returns void language plpgsql security definer set search_path='' as $$
declare path text:=coalesce(trim(p_path),'');
begin
 perform charm.require_actor();
 if not charm.logistics_desk() then raise exception 'forbidden'; end if;
 if p_product is null or not exists(select 1 from charm.products where id=p_product) then raise exception 'notFound'; end if;
 if path='' then
  update charm.products set image_path=null,updated_at=now() where id=p_product;
  perform charm.audit('imageRemoved','products',p_product);
  return;
 end if;
 if path!~('^products/'||p_product::text||'/[0-9a-z._-]+\.(jpg|jpeg|png|webp)$') or not charm.file_access(path,true)
  or not exists(select 1 from storage.objects where bucket_id='charm-private' and name=path) then raise exception 'mediaUploadRequired'; end if;
 update charm.products set image_path=path,updated_at=now() where id=p_product;
 perform charm.audit('imageAttached','products',p_product,jsonb_build_object('path',path));
end $$;

-- Availability is proved per order line, oldest confirmed order first, so two orders never spend the same bottles.
create or replace function charm.logistics_order_intake() returns table(order_id bigint,client_id bigint,client_name text,salesperson_id bigint,salesperson_name text,
 order_total numeric,due_date date,delivery_id bigint,delivery_status text,production_required boolean,production_ready_on date,
 confirmed_at timestamptz,short_items jsonb,covered boolean) language sql stable security definer set search_path='' as $$
 with demand as (
  select i.product_id,o.id as wanted_by,sum(i.quantity*case when i.unit='carton' then p.carton else 1 end)::bigint as needed
  from charm.order_items i join charm.orders o on o.id=i.order_id join charm.products p on p.id=i.product_id
  where o.status='confirmed' and not exists(select 1 from charm.sales_deliveries d where d.order_id=o.id and d.status='delivered')
  group by i.product_id,o.id
 ),
 queue as (
  select cur.wanted_by,cur.product_id,cur.needed,coalesce(sum(older.needed),0)::bigint as earlier_needed
  from demand cur left join demand older on older.product_id=cur.product_id and older.wanted_by<cur.wanted_by
  group by cur.wanted_by,cur.product_id,cur.needed
 ),
 supply as (
  select p.id as product_id,
   coalesce((select sum(x.quantity) from charm.sales_finished_stock x where x.product_id=p.id and (x.expires_on is null or x.expires_on>=(now() at time zone 'Africa/Nairobi')::date)),0)::bigint as stock,
   coalesce((select sum(x.scheduled_quantity) from charm.sales_batch_schedule x where x.product_id=p.id and x.status in ('scheduled','ready') and x.ready_on>=(now() at time zone 'Africa/Nairobi')::date),0)::bigint as planned
  from charm.products p
 ),
 per_line as (
  select q.wanted_by,q.product_id,pr.category||' · '||pr.capacity as product,q.needed,
   greatest(q.needed-(s.stock+s.planned-q.earlier_needed),0) as short
  from queue q join supply s on s.product_id=q.product_id join charm.products pr on pr.id=q.product_id
 ),
 shortage as (
  select wanted_by,jsonb_agg(jsonb_build_object('product_id',product_id,'product',product,'needed',needed,'short',short) order by product_id) filter(where short>0) as gaps
  from per_line group by wanted_by
 )
 select o.id,o.client_id,c.name,o.salesperson_id,u.name,o.total,o.due_date,d.id,d.status,o.production_required,o.production_ready_on,o.confirmed_at,
  coalesce(g.gaps,'[]'::jsonb),g.gaps is null
 from charm.orders o
 join charm.clients c on c.id=o.client_id
 join charm.users u on u.id=o.salesperson_id
 left join charm.sales_deliveries d on d.order_id=o.id
 left join shortage g on g.wanted_by=o.id
 where o.status='confirmed' and (d.id is null or d.status='failed') and charm.logistics_desk()
 order by o.id
$$;

create or replace function charm.logistics_arrange_production(p_key uuid,p_order bigint,p_ready_on date) returns bigint
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); o charm.orders; intake record; scheduled bigint:=0; today date; existing bigint; recipient record;
begin
 if not charm.logistics_desk() then raise exception 'forbidden'; end if;
 today:=(now() at time zone 'Africa/Nairobi')::date;
 if p_ready_on is null or p_ready_on<today or p_ready_on>today+180 then raise exception 'invalid'; end if;
 existing:=charm.claim(p_key,'logistics_production',jsonb_build_object('order',p_order,'ready_on',p_ready_on));
 if existing is not null then return existing; end if;
 select * into o from charm.orders where id=p_order for update;
 if not found or o.status<>'confirmed' then raise exception 'confirmedOrderRequired'; end if;
 if exists(select 1 from charm.sales_deliveries d where d.order_id=o.id and d.status in ('planned','dispatched')) then raise exception 'deliveryInProgress'; end if;
 select * into intake from charm.logistics_order_intake() where order_id=o.id;
 if not found then raise exception 'notFound'; end if;
 if intake.covered then raise exception 'stockAvailable'; end if;
 insert into charm.sales_batch_schedule(product_id,scheduled_quantity,ready_on,created_by)
  select (item->>'product_id')::bigint,(item->>'short')::integer,p_ready_on,a from jsonb_array_elements(intake.short_items) item;
 get diagnostics scheduled=row_count;
 if scheduled=0 then raise exception 'invalid'; end if;
 update charm.orders set production_required=true,production_ready_on=p_ready_on,updated_at=now() where id=o.id;
 perform charm.audit('productionArranged','orders',o.id,jsonb_build_object('ready_on',p_ready_on,'lines',scheduled));
 for recipient in select id from charm.users where active and id<>a and (role='admin' or id=o.salesperson_id) loop
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
   values(recipient.id,null,'productionArranged','production-arranged:'||o.id||':'||p_ready_on||':'||recipient.id,'orders',o.id) on conflict do nothing;
 end loop;
 return charm.finish(p_key,scheduled);
end $$;

-- Deliveries may be planned by the desk as well as by the owning salesperson; planning clears the production flag.
create or replace function charm.sales_create_delivery(p_key uuid,p_order bigint,p_scheduled date,p_driver text,p_phone text,p_vehicle text,p_notes text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();o charm.orders;existing bigint;did bigint;d charm.sales_deliveries;recipient record;
begin
 existing:=charm.claim(p_key,'sales_delivery',jsonb_build_object('order',p_order,'scheduled',p_scheduled,'driver',coalesce(p_driver,''),'phone',coalesce(p_phone,''),'vehicle',coalesce(p_vehicle,''),'notes',coalesce(p_notes,'')));
 if existing is not null then return existing;end if;
 select * into o from charm.orders where id=p_order and status='confirmed';
 if not found then raise exception 'confirmedOrderRequired';end if;
 if not (charm.can_access(o.salesperson_id) or charm.logistics_desk()) then raise exception 'forbidden';end if;
 if p_scheduled is null or p_scheduled<(now() at time zone 'Africa/Nairobi')::date-1 then raise exception 'invalid';end if;
 if coalesce(length(trim(p_driver)),0)>120 or coalesce(length(trim(p_phone)),0)>40 or coalesce(length(trim(p_vehicle)),0)>80 or coalesce(length(p_notes),0)>1000 then raise exception 'invalid';end if;
 select * into d from charm.sales_deliveries where order_id=p_order for update;
 if found then
  if d.status<>'failed' then raise exception 'deliveryExists';end if;
  update charm.sales_deliveries set status='planned',scheduled_on=p_scheduled,driver_name=trim(coalesce(p_driver,'')),driver_phone=trim(coalesce(p_phone,'')),vehicle=trim(coalesce(p_vehicle,'')),notes=trim(coalesce(p_notes,'')),failure_reason='',dispatched_at=null,delivered_at=null,updated_at=now() where id=d.id;
  update charm.orders set production_required=false,updated_at=now() where id=p_order and production_required;
  perform charm.audit('deliveryRescheduled','sales_deliveries',d.id,jsonb_build_object('order_id',p_order,'scheduled_on',p_scheduled));
  perform charm.finish(p_key,d.id);
  return d.id;
 end if;
 insert into charm.sales_deliveries(delivery_number,order_id,client_id,salesperson_id,scheduled_on,driver_name,driver_phone,vehicle,notes,created_by)
 values('',p_order,o.client_id,o.salesperson_id,p_scheduled,trim(coalesce(p_driver,'')),trim(coalesce(p_phone,'')),trim(coalesce(p_vehicle,'')),trim(coalesce(p_notes,'')),a) returning id into did;
 insert into charm.sales_delivery_items(delivery_id,order_item_id,product_id,quantity,unit) select did,id,product_id,quantity,unit from charm.order_items where order_id=p_order;
 if not found then raise exception 'invalid';end if;
 update charm.orders set production_required=false,updated_at=now() where id=p_order and production_required;
 perform charm.audit('deliveryPlanned','sales_deliveries',did,jsonb_build_object('order_id',p_order,'scheduled_on',p_scheduled,'driver',p_driver));
 for recipient in select id from charm.users where active and id<>a and (role in ('admin','logistics_manager') or id=o.salesperson_id) loop
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) values(recipient.id,null,'deliveryPlanned','delivery-planned:'||did||':'||recipient.id,'sales_deliveries',did) on conflict do nothing;
 end loop;
 perform charm.finish(p_key,did);
 return did;
end$$;

create or replace function charm.sales_update_delivery(p_id bigint,p_status text,p_note text default '') returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();d charm.sales_deliveries;target text:=coalesce(p_status,'');reason text:=trim(coalesce(p_note,''));recipient record;action_name text;
begin
 select * into d from charm.sales_deliveries where id=p_id for update;
 if not found or d.status in ('delivered','failed') then raise exception 'alreadyClosed';end if;
 if not (charm.can_access(d.salesperson_id) or charm.logistics_desk()) then raise exception 'forbidden';end if;
 if target not in ('dispatched','delivered','failed') then raise exception 'invalid';end if;
 if (d.status='planned' and target not in ('dispatched','failed')) or (d.status='dispatched' and target not in ('delivered','failed')) then raise exception 'invalidTransition';end if;
 if target='failed' and length(reason)<3 then raise exception 'reasonRequired';end if;
 if length(reason)>1000 then raise exception 'invalid';end if;
 action_name:=case target when 'dispatched' then 'deliveryDispatched' when 'delivered' then 'deliveryDelivered' else 'deliveryFailed' end;
 update charm.sales_deliveries set status=target,
  dispatched_at=case when target='dispatched' then now() else dispatched_at end,
  delivered_at=case when target='delivered' then now() else delivered_at end,
  failure_reason=case when target='failed' then reason else failure_reason end,
  updated_at=now() where id=d.id;
 perform charm.audit(action_name,'sales_deliveries',d.id,jsonb_build_object('order_id',d.order_id,'status',target,'note',reason));
 for recipient in select id from charm.users where active and id<>a and (role in ('admin','logistics_manager') or id=d.salesperson_id) loop
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) values(recipient.id,null,action_name,'delivery-'||target||':'||d.id||':'||recipient.id,'sales_deliveries',d.id) on conflict do nothing;
 end loop;
end$$;

create or replace function charm.sales_order_documents(p_order bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;begin
 if charm.actor() is null then raise exception 'unauthorized';end if;
 select jsonb_build_object(
  'order',jsonb_build_object('id',o.id,'status',o.status,'total',o.total,'due_date',o.due_date,'confirmed_at',o.confirmed_at,'customer_type',o.customer_type),
  'client',jsonb_build_object('id',c.id,'name',c.name,'contact',c.contact,'phone',c.phone,'location',c.location),
  'salesperson',u.name,
  'items',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'description',i.product_description,'sku',pr.sku,'quantity',i.quantity,'unit',i.unit,'unit_price',i.unit_price,'line_total',i.line_total) order by i.id),'[]') from charm.order_items i left join charm.products pr on pr.id=i.product_id where i.order_id=o.id),
  'invoice',(select jsonb_build_object('invoice_number',v.invoice_number,'status',v.status,'subtotal',v.subtotal,'tax_amount',v.tax_amount,'total',v.total,'due_date',v.due_date,'issued_at',v.issued_at,'etims_status',v.etims_status,'etims_control',v.etims_control) from charm.finance_sales_invoices v where v.order_id=o.id),
  'delivery',(select jsonb_build_object('id',d.id,'delivery_number',d.delivery_number,'status',d.status,'scheduled_on',d.scheduled_on,'driver_name',d.driver_name,'driver_phone',d.driver_phone,'vehicle',d.vehicle,'notes',d.notes,'failure_reason',d.failure_reason,'dispatched_at',d.dispatched_at,'delivered_at',d.delivered_at,
    'items',(select coalesce(jsonb_agg(jsonb_build_object('description',i.product_description,'sku',pr.sku,'quantity',x.quantity,'unit',x.unit,'unit_price',i.unit_price,'line_total',i.line_total) order by x.id),'[]') from charm.sales_delivery_items x join charm.order_items i on i.id=x.order_item_id left join charm.products pr on pr.id=x.product_id where x.delivery_id=d.id)
   ) from charm.sales_deliveries d where d.order_id=o.id),
  'credit_notes',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'credit_note',r.credit_note,'amount',r.credit_amount,'quantity',r.quantity,'reason',r.reason,'created_at',r.updated_at) order by r.id desc),'[]') from charm.sales_returns r where r.order_id=o.id and r.status='credited')
 ) into result
 from charm.orders o join charm.clients c on c.id=o.client_id join charm.users u on u.id=o.salesperson_id
 where o.id=p_order and (charm.can_access(o.salesperson_id) or charm.logistics_desk());
 if result is null then raise exception 'notFound';end if;
 return result;
end$$;

create or replace function charm.sales_inventory_ledger(p_limit integer default 60) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if charm.actor() is null then raise exception 'unauthorized';end if;
 if p_limit is null or p_limit not between 1 and 200 then raise exception 'invalid';end if;
 return jsonb_build_object('rows',(
  select coalesce(jsonb_agg(jsonb_build_object('occurred_at',y.occurred_at,'kind',y.kind,'reference',y.reference,'sku',y.sku,'product',y.product,'quantity',y.quantity,'unit',y.unit,'detail',y.detail) order by y.occurred_at desc,y.sort desc),'[]')
  from(
   select x.* from(
    select s.created_at occurred_at,'receipt'::text kind,s.lot_number reference,p.sku,p.category||' · '||p.capacity product,s.quantity,''::text unit,coalesce(nullif(s.reference,''),'Finished goods') detail,0 sort
    from charm.sales_finished_stock s join charm.products p on p.id=s.product_id
    union all
    select d.delivered_at,'dispatch',d.delivery_number,p.sku,p.category||' · '||p.capacity,sum(-(i.quantity*case when i.unit='carton' then p.carton else 1 end))::integer,'bottles',c.name,1
    from charm.sales_delivery_items i join charm.sales_deliveries d on d.id=i.delivery_id join charm.products p on p.id=i.product_id join charm.clients c on c.id=d.client_id
    where d.status='delivered' and (charm.is_admin() or charm.logistics_desk() or d.salesperson_id=charm.actor())
    group by d.delivered_at,d.delivery_number,p.sku,p.category,p.capacity,c.name
   )x order by x.occurred_at desc,x.sort desc limit p_limit
  )y
 ));
end$$;

-- The desk may be assigned like any other staff role.
create or replace function charm.update_staff(p_id bigint,p_name text,p_phone text,p_territory text,p_role text,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint; u charm.users; caller charm.users;
begin
 a:=charm.require_admin();
 perform pg_advisory_xact_lock(817201008);
 select * into caller from charm.users where id=a for update;
 if caller.role<>'admin' or not caller.active then raise exception 'forbidden'; end if;
 select * into u from charm.users where id=p_id for update;
 if not found then raise exception 'notFound'; end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(p_phone),0)>40 or coalesce(length(p_territory),0)>200 or p_role is null or p_role not in ('admin','salesperson','finance_officer','logistics_manager') or p_active is null then raise exception 'invalid'; end if;
 if p_id=a and (p_role<>u.role or p_active<>u.active) then raise exception 'selfRoleChange'; end if;
 if u.role='admin' and u.active and (p_role<>'admin' or not p_active) and (select count(*) from charm.users where role='admin' and active)<=1 then raise exception 'lastAdmin'; end if;
 update charm.users set name=trim(p_name),phone=nullif(trim(p_phone),''),territory=nullif(trim(p_territory),''),role=p_role,active=p_active,updated_at=now() where id=p_id;
 perform charm.audit('staffUpdated','users',p_id,jsonb_build_object('before',jsonb_build_object('name',u.name,'phone',u.phone,'territory',u.territory,'role',u.role,'active',u.active),'after',jsonb_build_object('name',trim(p_name),'phone',p_phone,'territory',p_territory,'role',p_role,'active',p_active)));
end $$;

create or replace function charm.link_staff(p_actor uuid,p_auth uuid,p_email text,p_name text,p_role text) returns bigint language plpgsql security definer set search_path='' as $$
declare admin_id bigint; staff_id bigint; existing_auth uuid; canonical_email text;
begin
 perform pg_advisory_xact_lock(817201008);
 select u.id into admin_id from charm.auth_accounts a join charm.users u on u.id=a.salesperson_id where a.auth_user_id=p_actor and u.active and u.role='admin';
 if admin_id is null or p_actor=p_auth then raise exception 'forbidden'; end if;
 select email into canonical_email from auth.users where id=p_auth;
 if canonical_email is null or lower(canonical_email)<>lower(trim(p_email)) or p_role not in ('admin','salesperson','finance_officer','logistics_manager') or coalesce(length(trim(p_name)),0) not between 1 and 200 then raise exception 'invalid'; end if;
 perform pg_advisory_xact_lock(hashtextextended(lower(trim(p_email)),1));
 if (select count(*) from charm.users where lower(email)=lower(trim(p_email)))>1 then raise exception 'duplicateConflict'; end if;
 select id into staff_id from charm.users where lower(email)=lower(trim(p_email)) for update;
 if staff_id=admin_id then raise exception 'forbidden'; end if;
 if staff_id is null then
  -- Unusable legacy password; Supabase reset/invite establishes the real credential.
  insert into charm.users(name,email,password,role,active,created_at,updated_at) values(p_name,lower(trim(p_email)),'!supabase-auth-only!',p_role,true,now(),now()) returning id into staff_id;
 end if;
 select auth_user_id into existing_auth from charm.auth_accounts where salesperson_id=staff_id;
 if existing_auth is not null and existing_auth<>p_auth then raise exception 'duplicateConflict'; end if;
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values(p_auth,staff_id) on conflict(auth_user_id) do nothing;
 if not exists(select 1 from charm.auth_accounts where auth_user_id=p_auth and salesperson_id=staff_id) then raise exception 'duplicateConflict'; end if;
 insert into charm.audit_logs(actor_id,action,entity,entity_id,details,created_at) values(admin_id,'invited','users',staff_id,jsonb_build_object('auth_user_id',p_auth),now());
 return staff_id;
end $$;

-- Confirming an order is now also work for the fulfilment desk, and only for it.
create or replace function charm.sales_credit_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare lim numeric;used numeric;begin
 if charm.finance_role() not in ('admin','salesperson','logistics_manager') then raise exception 'forbidden';end if;
 if tg_op='UPDATE' and old.status='confirmed' then return new;end if;
 if new.status<>'confirmed' then return new;end if;
 perform 1 from charm.clients where id=new.client_id for update;
 select credit_limit into lim from charm.clients where id=new.client_id;
 select coalesce(sum(o.total-coalesce(paid.amount,0)-coalesce(credit.amount,0)),0) into used from charm.orders o left join lateral(select sum(amount) amount from charm.payments where order_id=o.id and status='verified') paid on true left join lateral(select sum(credit_amount) amount from charm.sales_returns where order_id=o.id and status='credited') credit on true where o.client_id=new.client_id and o.status='confirmed' and o.id<>new.id;
 if lim>0 and used+new.total>lim then raise exception 'creditLimitExceeded';end if;
 return new;
end $$;

-- Identity and imagery reach the directory the same way names do.
create or replace view charm.team_directory with(security_invoker=true) as
 select u.id,u.name,u.email,u.role,u.active,u.staff_code,u.phone,u.territory,u.photo_path from charm.users u
 where not exists(select 1 from charm.staff_archives a where a.staff_id=u.id);
grant select on charm.team_directory to authenticated;

create or replace function charm.staff_profile(p_id bigint,p_month date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u charm.users; start_at timestamptz; end_at timestamptz; result jsonb;
begin
 perform charm.require_admin();
 select * into u from charm.users where id=p_id;
 if not found then raise exception 'notFound'; end if;
 if p_month is null then raise exception 'invalid'; end if;
 start_at:=date_trunc('month',p_month::timestamp) at time zone 'Africa/Nairobi';
 end_at:=(date_trunc('month',p_month::timestamp)+interval '1 month') at time zone 'Africa/Nairobi';
 select jsonb_build_object(
 'person',jsonb_build_object('id',u.id,'name',u.name,'email',u.email,'phone',u.phone,'territory',u.territory,'role',u.role,'active',u.active,'created_at',u.created_at,'staff_code',u.staff_code,'photo_path',u.photo_path,'linked',exists(select 1 from charm.auth_accounts where salesperson_id=u.id)),
 'monthly_sales',coalesce((select sum(total)::text from charm.orders where salesperson_id=p_id and status='confirmed' and confirmed_at>=start_at and confirmed_at<end_at),'0.00'),
 'lifetime_sales',coalesce((select sum(total)::text from charm.orders where salesperson_id=p_id and status='confirmed'),'0.00'),
 'outstanding',coalesce((select sum(o.total-coalesce((select sum(p.amount) from charm.payments p where p.order_id=o.id and p.status='verified'),0))::text from charm.orders o where o.salesperson_id=p_id and o.status='confirmed'),'0.00'),
 'clients',(select count(*) from charm.clients where salesperson_id=p_id),
 'pending_orders',(select count(*) from charm.orders where salesperson_id=p_id and status='pending'),
 'pending_payments',(select count(*) from charm.payments p join charm.orders o on o.id=p.order_id where o.salesperson_id=p_id and p.status='pending'),
 'visits',(select count(*) from charm.visits where salesperson_id=p_id),
 'reports',(select count(*) from charm.reports where salesperson_id=p_id),
 'approved_travel',coalesce((select sum(budget)::text from charm.expenses where salesperson_id=p_id and status='approved'),'0.00'),
 'trend',coalesce((select jsonb_agg(jsonb_build_object('month',to_char(m,'YYYY-MM'),'sales',coalesce((select sum(o.total)::text from charm.orders o where o.salesperson_id=p_id and o.status='confirmed' and o.confirmed_at>=m at time zone 'Africa/Nairobi' and o.confirmed_at<(m+interval '1 month') at time zone 'Africa/Nairobi'),'0.00')) order by m) from generate_series(date_trunc('month',p_month::timestamp)-interval '5 months',date_trunc('month',p_month::timestamp),interval '1 month') m),'[]'),
 'latest_location',(select jsonb_build_object('latitude',p.latitude,'longitude',p.longitude,'accuracy_m',p.accuracy_m,'recorded_at',p.recorded_at,'workday_id',w.id,'ended_at',w.ended_at) from charm.location_points p join charm.workdays w on w.id=p.workday_id where w.salesperson_id=p_id order by p.recorded_at desc,p.id desc limit 1)
 ) into result; return result;
end $$;

-- Confirmed orders belong to the fulfilment desk, not to everybody.
create or replace function charm.notify_workspace_activity() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  payload jsonb := to_jsonb(new);
  previous jsonb := case when tg_op='UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  actor bigint := charm.actor();
  owner_id bigint;
  client_owner bigint;
  record_id bigint;
  state text;
  managers boolean;
  finance boolean;
  recipient record;
  event_name text;
  event_token text;
begin
  record_id := nullif(payload->>'id','')::bigint;
  owner_id := coalesce(nullif(payload->>'salesperson_id','')::bigint,
                       nullif(payload->>'submitted_by','')::bigint,
                       nullif(payload->>'user_id','')::bigint,
                       nullif(payload->>'owner_id','')::bigint,
                       nullif(payload->>'created_by','')::bigint,
                       nullif(payload->>'started_by','')::bigint);
  client_owner := (select c.salesperson_id from charm.clients c where c.id=nullif(payload->>'client_id','')::bigint);
  state := coalesce(payload->>'status','');
  if tg_op='UPDATE' and (tg_table_name in ('clients','visits','reports','workdays') or coalesce(previous->>'status','')=state) then
    return new;
  end if;

  event_name := case
    when tg_op='INSERT' then tg_table_name||'_submitted'
    else coalesce(nullif(state,''),tg_table_name||'_updated') end;
  event_token := tg_table_name||':'||record_id||':'||tg_op||':'||coalesce(nullif(state,''),to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS'));

  managers := tg_table_name in ('clients','orders','payments','production_materials','production_formulas','production_batches');
  finance := tg_table_name in ('payments','production_materials','production_formulas','production_batches') or (tg_table_name='orders' and state='confirmed');

  for recipient in
    select u.id, u.role::text as role from charm.users u
    where u.active and u.id<>coalesce(actor,-1)
      and (u.id=owner_id or u.id=client_owner
           or (managers and u.role='admin')
           or (finance and u.role='finance_officer')
           or (tg_table_name='orders' and state='confirmed' and u.role='logistics_manager'))
  loop
    insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
      values(recipient.id,null,event_name,event_token||':'||recipient.id,tg_table_name,record_id)
      on conflict do nothing;
  end loop;

  if tg_table_name='production_batches' and state='released' then
    insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
      select distinct o.salesperson_id,null::bigint,event_name,'batch-released:'||record_id||':'||o.salesperson_id,'production_batches',record_id
      from charm.orders o join charm.finance_sales_invoices v on v.order_id=o.id
      where o.status='confirmed' and coalesce(v.batch_lot,'')='' and o.salesperson_id<>coalesce(actor,-1)
      on conflict do nothing;
  end if;

  return new;
end $$;

do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='charm' and tablename='orders') then execute 'alter publication supabase_realtime add table charm.orders';end if;
 end if;
end$$;

revoke execute on function charm.logistics_desk(),charm.file_access(text,boolean),charm.save_staff_photo(bigint,text),charm.save_product_image(bigint,text),charm.logistics_order_intake(),charm.logistics_arrange_production(uuid,bigint,date),charm.sales_create_delivery(uuid,bigint,date,text,text,text,text),charm.sales_update_delivery(bigint,text,text),charm.sales_order_documents(bigint),charm.sales_inventory_ledger(integer),charm.update_staff(bigint,text,text,text,text,boolean),charm.link_staff(uuid,uuid,text,text,text),charm.sales_credit_guard(),charm.staff_profile(bigint,date),charm.notify_workspace_activity() from public,anon,authenticated;
grant execute on function charm.logistics_desk(),charm.file_access(text,boolean),charm.save_staff_photo(bigint,text),charm.save_product_image(bigint,text),charm.logistics_order_intake(),charm.logistics_arrange_production(uuid,bigint,date),charm.sales_create_delivery(uuid,bigint,date,text,text,text,text),charm.sales_update_delivery(bigint,text,text),charm.sales_order_documents(bigint),charm.sales_inventory_ledger(integer),charm.update_staff(bigint,text,text,text,text,boolean),charm.staff_profile(bigint,date) to authenticated;
notify pgrst,'reload schema';
commit;

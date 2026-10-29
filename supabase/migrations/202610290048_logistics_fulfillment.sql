-- Order logistics: delivery planning, dispatch, delivery notes and a finished-goods ledger.
begin;
create sequence charm.sales_delivery_seq;

create table charm.sales_deliveries(
 id bigserial primary key,
 delivery_number text not null unique,
 order_id bigint not null unique references charm.orders(id),
 client_id bigint not null references charm.clients(id),
 salesperson_id bigint not null references charm.users(id),
 status text not null default 'planned' check(status in ('planned','dispatched','delivered','failed')),
 scheduled_on date not null,
 driver_name text not null default '',
 driver_phone text not null default '',
 vehicle text not null default '',
 notes text not null default '',
 failure_reason text not null default '',
 dispatched_at timestamptz,
 delivered_at timestamptz,
 created_by bigint not null references charm.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table charm.sales_delivery_items(
 id bigserial primary key,
 delivery_id bigint not null references charm.sales_deliveries(id) on delete cascade,
 order_item_id bigint not null references charm.order_items(id),
 product_id bigint not null references charm.products(id),
 quantity integer not null check(quantity between 1 and 100000),
 unit text not null check(unit in ('bottle','carton')),
 unique(delivery_id,order_item_id)
);
create index sales_delivery_status on charm.sales_deliveries(status,scheduled_on,id desc);
create index sales_delivery_owner on charm.sales_deliveries(salesperson_id,status,id desc);
create index sales_delivery_item_order on charm.sales_delivery_items(order_item_id);

create function charm.sales_delivery_number() returns trigger language plpgsql set search_path='' as $$begin
 if coalesce(trim(new.delivery_number),'')='' then
  new.delivery_number:='DN-'||to_char(now() at time zone 'Africa/Nairobi','YYYYMMDD')||'-'||lpad(nextval('charm.sales_delivery_seq')::text,5,'0');
 end if;
 return new;
end$$;
create trigger sales_delivery_number_assign before insert on charm.sales_deliveries for each row execute function charm.sales_delivery_number();

create function charm.sales_create_delivery(p_key uuid,p_order bigint,p_scheduled date,p_driver text,p_phone text,p_vehicle text,p_notes text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();o charm.orders;existing bigint;did bigint;d charm.sales_deliveries;recipient record;
begin
 existing:=charm.claim(p_key,'sales_delivery',jsonb_build_object('order',p_order,'scheduled',p_scheduled,'driver',coalesce(p_driver,''),'phone',coalesce(p_phone,''),'vehicle',coalesce(p_vehicle,''),'notes',coalesce(p_notes,'')));
 if existing is not null then return existing;end if;
 select * into o from charm.orders where id=p_order and status='confirmed';
 if not found then raise exception 'confirmedOrderRequired';end if;
 if not charm.can_access(o.salesperson_id) then raise exception 'forbidden';end if;
 if p_scheduled is null or p_scheduled<(now() at time zone 'Africa/Nairobi')::date-1 then raise exception 'invalid';end if;
 if coalesce(length(trim(p_driver)),0)>120 or coalesce(length(trim(p_phone)),0)>40 or coalesce(length(trim(p_vehicle)),0)>80 or coalesce(length(p_notes),0)>1000 then raise exception 'invalid';end if;
 select * into d from charm.sales_deliveries where order_id=p_order for update;
 if found then
  if d.status<>'failed' then raise exception 'deliveryExists';end if;
  update charm.sales_deliveries set status='planned',scheduled_on=p_scheduled,driver_name=trim(coalesce(p_driver,'')),driver_phone=trim(coalesce(p_phone,'')),vehicle=trim(coalesce(p_vehicle,'')),notes=trim(coalesce(p_notes,'')),failure_reason='',dispatched_at=null,delivered_at=null,updated_at=now() where id=d.id;
  perform charm.audit('deliveryRescheduled','sales_deliveries',d.id,jsonb_build_object('order_id',p_order,'scheduled_on',p_scheduled));
  perform charm.finish(p_key,d.id);
  return d.id;
 end if;
 insert into charm.sales_deliveries(delivery_number,order_id,client_id,salesperson_id,scheduled_on,driver_name,driver_phone,vehicle,notes,created_by)
 values('',p_order,o.client_id,o.salesperson_id,p_scheduled,trim(coalesce(p_driver,'')),trim(coalesce(p_phone,'')),trim(coalesce(p_vehicle,'')),trim(coalesce(p_notes,'')),a) returning id into did;
 insert into charm.sales_delivery_items(delivery_id,order_item_id,product_id,quantity,unit) select did,id,product_id,quantity,unit from charm.order_items where order_id=p_order;
 if not found then raise exception 'invalid';end if;
 perform charm.audit('deliveryPlanned','sales_deliveries',did,jsonb_build_object('order_id',p_order,'scheduled_on',p_scheduled,'driver',p_driver));
 for recipient in select id from charm.users where active and id<>a and (role='admin' or id=o.salesperson_id) loop
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) values(recipient.id,null,'deliveryPlanned','delivery-planned:'||did||':'||recipient.id,'sales_deliveries',did) on conflict do nothing;
 end loop;
 perform charm.finish(p_key,did);
 return did;
end$$;

create function charm.sales_update_delivery(p_id bigint,p_status text,p_note text default '') returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();d charm.sales_deliveries;target text:=coalesce(p_status,'');reason text:=trim(coalesce(p_note,''));recipient record;action_name text;
begin
 select * into d from charm.sales_deliveries where id=p_id for update;
 if not found or d.status in ('delivered','failed') then raise exception 'alreadyClosed';end if;
 if not charm.can_access(d.salesperson_id) then raise exception 'forbidden';end if;
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
 for recipient in select id from charm.users where active and id<>a and (role='admin' or id=d.salesperson_id) loop
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) values(recipient.id,null,action_name,'delivery-'||target||':'||d.id||':'||recipient.id,'sales_deliveries',d.id) on conflict do nothing;
 end loop;
end$$;

create function charm.sales_order_documents(p_order bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
 where o.id=p_order and charm.can_access(o.salesperson_id);
 if result is null then raise exception 'notFound';end if;
 return result;
end$$;

create or replace function charm.sales_atp() returns table(product_id bigint,sku text,packaging_type text,finished_stock bigint,scheduled_stock bigint,available_quantity bigint,next_ready_on date) language sql stable security definer set search_path='' as $$
 select p.id,p.sku,p.packaging_type,
  coalesce(s.qty,0)::bigint-coalesce(dv.qty,0)::bigint,
  coalesce(b.qty,0)::bigint,
  greatest(coalesce(s.qty,0)-coalesce(dv.qty,0)+coalesce(b.qty,0)-coalesce(c.qty,0),0)::bigint,
  b.next_on
 from charm.products p
 left join lateral(select sum(quantity) qty from charm.sales_finished_stock x where x.product_id=p.id and (x.expires_on is null or x.expires_on>=(now() at time zone 'Africa/Nairobi')::date)) s on true
 left join lateral(select sum(i.quantity*case when i.unit='carton' then p.carton else 1 end) qty from charm.sales_delivery_items i join charm.sales_deliveries d on d.id=i.delivery_id where i.product_id=p.id and d.status='delivered') dv on true
 left join lateral(select sum(scheduled_quantity) qty,min(ready_on) filter(where ready_on>=(now() at time zone 'Africa/Nairobi')::date) next_on from charm.sales_batch_schedule x where x.product_id=p.id and x.status in ('scheduled','ready') and ready_on>=(now() at time zone 'Africa/Nairobi')::date) b on true
 left join lateral(select sum(i.quantity*case when i.unit='carton' then p.carton else 1 end) qty from charm.order_items i join charm.orders o on o.id=i.order_id where i.product_id=p.id and o.status='confirmed' and not exists(select 1 from charm.sales_deliveries d where d.order_id=o.id and d.status='delivered')) c on true
 where p.active and charm.actor() is not null
$$;

create function charm.sales_inventory_ledger(p_limit integer default 60) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
    where d.status='delivered' and (charm.is_admin() or d.salesperson_id=charm.actor())
    group by d.delivered_at,d.delivery_number,p.sku,p.category,p.capacity,c.name
   )x order by x.occurred_at desc,x.sort desc limit p_limit
  )y
 ));
end$$;

do $$ declare t text;begin
 foreach t in array array['sales_deliveries','sales_delivery_items'] loop
  execute format('alter table charm.%I enable row level security',t);
  execute format('revoke all on charm.%I from public,anon,authenticated',t);
  execute format('grant select on charm.%I to authenticated',t);
 end loop;
end$$;
create policy sales_delivery_read on charm.sales_deliveries for select to authenticated using(charm.can_access(salesperson_id));
create policy sales_delivery_item_read on charm.sales_delivery_items for select to authenticated using(exists(select 1 from charm.sales_deliveries d where d.id=delivery_id and charm.can_access(d.salesperson_id)));

do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='charm' and tablename='sales_deliveries') then execute 'alter publication supabase_realtime add table charm.sales_deliveries';end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='charm' and tablename='sales_delivery_items') then execute 'alter publication supabase_realtime add table charm.sales_delivery_items';end if;
 end if;
end$$;

revoke execute on function charm.sales_create_delivery(uuid,bigint,date,text,text,text,text),charm.sales_update_delivery(bigint,text,text),charm.sales_order_documents(bigint),charm.sales_inventory_ledger(integer),charm.sales_delivery_number() from public,anon,authenticated;
grant execute on function charm.sales_create_delivery(uuid,bigint,date,text,text,text,text),charm.sales_update_delivery(bigint,text,text),charm.sales_order_documents(bigint),charm.sales_inventory_ledger(integer) to authenticated;
notify pgrst,'reload schema';
commit;

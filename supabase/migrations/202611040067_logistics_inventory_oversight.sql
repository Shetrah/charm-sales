begin;

-- Finished-goods inventory is an auditable ledger. Logistics records physical
-- counts; deliveries and quality-released production create stock movements.
alter table charm.production_formulas
 add column if not exists product_id bigint references charm.products(id) on delete set null;
create index if not exists production_formulas_product on charm.production_formulas(product_id,status);

-- Backfill only unambiguous formula-to-catalogue matches. Unmatched formulas
-- are linked explicitly by an administrator before the next production run.
with candidates as (
 select f.id formula_id,p.id product_id,
  count(*) over(partition by f.id) matches
 from charm.production_formulas f
 join charm.products p on p.active and (
  lower(trim(f.product_name))=lower(trim(p.sku)) or
  lower(trim(f.product_name))=lower(trim(p.category||' '||p.capacity||' '||p.fragrance)) or
  (nullif(trim(p.formula_name),'') is not null and lower(trim(f.product_name))=lower(trim(p.formula_name)))
 )
 where f.product_id is null
)
update charm.production_formulas f set product_id=c.product_id
from candidates c where c.formula_id=f.id and c.matches=1;

create or replace function charm.logistics_link_formula_product(p_formula bigint,p_product bigint)
returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin();f charm.production_formulas;p charm.products;
begin
 select * into f from charm.production_formulas where id=p_formula for update;
 if not found then raise exception 'notFound';end if;
 select * into p from charm.products where id=p_product and active for share;
 if not found or coalesce(p.volume_ml,0)<=0 then raise exception 'invalid';end if;
 if exists(select 1 from charm.production_batches b where b.formula_id=f.id and b.status='mixing') then raise exception 'batchLocked';end if;
 update charm.production_formulas set product_id=p.id where id=f.id;
 perform charm.audit('productionFormulaProductLinked','production_formulas',f.id,jsonb_build_object('product_id',p.id,'sku',p.sku));
end$$;

-- Force each new batch to identify the exact sellable SKU whose stock it can
-- replenish. This avoids guessing from product names when a QC release lands.
create or replace function charm.production_start_batch(p_formula bigint,p_target numeric) returns bigint
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();batch_id bigint;item record;
begin
 if not charm.production_admin() then raise exception 'forbidden';end if;
 if p_target is null or p_target<=0 then raise exception 'invalid';end if;
 if not exists(select 1 from charm.production_formulas f join charm.products p on p.id=f.product_id and p.active and p.volume_ml>0 where f.id=p_formula and f.status='approved') then raise exception 'productionProductMappingRequired';end if;
 for item in select distinct b.material_id from charm.production_scaled_bom(p_formula,p_target) b order by b.material_id loop perform pg_advisory_xact_lock(item.material_id);end loop;
 if not exists(select 1 from charm.production_formula_items where formula_id=p_formula) then raise exception 'formulaEmpty';end if;
 for item in select * from charm.production_scaled_bom(p_formula,p_target) order by material_id loop
  if charm.production_stock_balance(item.material_id)<item.quantity then raise exception 'insufficientStock';end if;
 end loop;
 insert into charm.production_batches(formula_id,target_liters,started_by) values(p_formula,p_target,a) returning id into batch_id;
 for item in select * from charm.production_scaled_bom(p_formula,p_target) order by material_id loop
  declare lot record;remaining numeric:=item.quantity;take_quantity numeric;
  begin
   for lot in select receipt.id,receipt.reference,receipt.supplier_lot,receipt.expiry_date,receipt.retest_date,
      receipt.quantity_base+coalesce(sum(consume.quantity_base),0) available
     from charm.production_stock_movements receipt left join charm.production_stock_movements consume on consume.reference='receipt:'||receipt.id::text and consume.kind='consumption'
     where receipt.material_id=item.material_id and receipt.kind='receipt'
      and (receipt.expiry_date is null or receipt.expiry_date>=(now() at time zone 'Africa/Nairobi')::date)
      and (receipt.retest_date is null or receipt.retest_date>=(now() at time zone 'Africa/Nairobi')::date)
     group by receipt.id,receipt.reference,receipt.supplier_lot,receipt.expiry_date,receipt.retest_date,receipt.quantity_base
     having receipt.quantity_base+coalesce(sum(consume.quantity_base),0)>0
     order by receipt.expiry_date nulls last,receipt.retest_date nulls last,receipt.id loop
    exit when remaining<=0;take_quantity:=least(remaining,lot.available);
    insert into charm.production_stock_movements(material_id,batch_id,kind,quantity_base,reference,supplier_lot,expiry_date,retest_date,notes,actor_id)
    values(item.material_id,batch_id,'consumption',-take_quantity,'receipt:'||lot.id::text,lot.supplier_lot,lot.expiry_date,lot.retest_date,'Batch '||batch_id||' FIFO lot consumption',a);
    remaining:=remaining-take_quantity;
   end loop;
   if remaining>0 then raise exception 'insufficientValidStock';end if;
  end;
 end loop;
 return batch_id;
end $$;

-- Associate open fulfillment schedules when a mapped batch starts. On release,
-- the schedule is retired and actual units are received exactly once.
create or replace function charm.link_batch_to_finished_schedules() returns trigger
language plpgsql security definer set search_path='' as $$
declare pid bigint;
begin
 select product_id into pid from charm.production_formulas where id=new.formula_id;
 if pid is not null then
  update charm.sales_batch_schedule set production_batch_id=new.id
  where product_id=pid and production_batch_id is null and status in ('scheduled','ready');
 end if;
 return new;
end$$;
drop trigger if exists production_batch_link_sales_schedules on charm.production_batches;
create trigger production_batch_link_sales_schedules after insert on charm.production_batches
for each row execute function charm.link_batch_to_finished_schedules();

create or replace function charm.receive_released_finished_batch() returns trigger
language plpgsql security definer set search_path='' as $$
declare p charm.products;units integer;recipient record;
begin
 if new.status='released' and old.status is distinct from new.status then
  select prod.* into p from charm.production_formulas f join charm.products prod on prod.id=f.product_id where f.id=new.formula_id and prod.active;
  if p.id is null or coalesce(p.volume_ml,0)<=0 then raise exception 'productionProductMappingRequired';end if;
  units:=floor(new.actual_liters*1000/p.volume_ml)::integer;
  if units<1 then raise exception 'productionOutputBelowOneUnit';end if;
  insert into charm.sales_finished_stock(product_id,lot_number,quantity,expires_on,reference,created_by)
   values(p.id,new.lot_number,units,null,'production-batch:'||new.id,new.started_by);
  update charm.sales_batch_schedule set status='cancelled'
   where production_batch_id=new.id and status in ('scheduled','ready');
  insert into charm.audit_logs(actor_id,action,entity,entity_id,details,created_at)
   values(charm.require_actor(),'productionStockReceived','production_batches',new.id,
    jsonb_build_object('product_id',p.id,'sku',p.sku,'quantity',units,'lot',new.lot_number),now());
  for recipient in select id from charm.users where active and role in ('admin','logistics_manager') and id<>charm.actor() loop
   insert into charm.finance_notifications(recipient_id,event,event_key,entity,entity_id)
    values(recipient.id,'finishedStockReceived','production-stock:'||new.id||':'||recipient.id,'production_batches',new.id)
    on conflict do nothing;
  end loop;
 end if;
 return new;
end$$;
drop trigger if exists production_finished_stock_receipt on charm.production_batches;
create trigger production_finished_stock_receipt after update of status on charm.production_batches
for each row execute function charm.receive_released_finished_batch();

-- Let Logistics inspect the finance-issued invoice and delivery receipt for
-- the confirmed order being fulfilled.
create or replace function charm.sales_document_payload(p_order bigint) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if charm.actor() is null then raise exception 'unauthorized';end if;
 select jsonb_build_object(
  'company',(select to_jsonb(cp) from charm.company_profile cp where cp.id=true),
  'order',jsonb_build_object('id',o.id,'status',o.status,'total',o.total,'due_date',o.due_date,'confirmed_at',o.confirmed_at,'created_at',o.created_at,'customer_type',o.customer_type,'contract_reference',o.contract_reference,'contract_signed_by',o.contract_signed_by),
  'client',jsonb_build_object('id',c.id,'name',c.name,'contact',c.contact,'phone',c.phone,'location',c.location,'customer_segment',c.customer_segment,'credit_limit',c.credit_limit),
  'salesperson',jsonb_build_object('id',u.id,'name',u.name,'phone',u.phone,'email',u.email,'staff_code',u.staff_code),
  'items',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'description',i.product_description,'sku',pr.sku,'barcode',pr.barcode,'variant',trim(pr.category||' '||pr.capacity||coalesce(' '||pr.fragrance,'')),'quantity',i.quantity,'unit',i.unit,'unit_price',i.unit_price,'line_total',i.line_total) order by i.id),'[]') from charm.order_items i left join charm.products pr on pr.id=i.product_id where i.order_id=o.id),
  'invoice',(select jsonb_build_object('id',v.id,'invoice_number',v.invoice_number,'status',v.status,'subtotal',v.subtotal,'tax_rate',v.tax_rate,'tax_amount',v.tax_amount,'total',v.total,'batch_lot',v.batch_lot,'credit_terms_days',v.credit_terms_days,'due_date',v.due_date,'issued_at',v.issued_at,'etims_status',v.etims_status,'etims_control',v.etims_control) from charm.finance_sales_invoices v where v.order_id=o.id),
  'payments',jsonb_build_object('verified',coalesce((select sum(p.amount) from charm.payments p where p.order_id=o.id and p.status='verified'),0),'pending',coalesce((select sum(p.amount) from charm.payments p where p.order_id=o.id and p.status='pending'),0),'lines',coalesce((select jsonb_agg(jsonb_build_object('reference',p.reference,'amount',p.amount,'received_at',p.received_at) order by p.received_at desc) from charm.payments p where p.order_id=o.id and p.status='verified'),'[]')),
  'delivery',(select jsonb_build_object('id',d.id,'delivery_number',d.delivery_number,'status',d.status,'scheduled_on',d.scheduled_on,'driver_name',d.driver_name,'driver_phone',d.driver_phone,'vehicle',d.vehicle,'notes',d.notes,'failure_reason',d.failure_reason,'dispatched_at',d.dispatched_at,'delivered_at',d.delivered_at,'created_by_name',cb.name,'items',(select coalesce(jsonb_agg(jsonb_build_object('description',i.product_description,'sku',pr.sku,'barcode',pr.barcode,'quantity',x.quantity,'unit',x.unit,'unit_price',i.unit_price,'line_total',i.line_total,'bottles',x.quantity*case when x.unit='carton' then coalesce(pr.carton,1) else 1 end) order by x.id),'[]') from charm.sales_delivery_items x join charm.order_items i on i.id=x.order_item_id left join charm.products pr on pr.id=x.product_id where x.delivery_id=d.id)) from charm.sales_deliveries d left join charm.users cb on cb.id=d.created_by where d.order_id=o.id),
  'credit_notes',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'credit_note',r.credit_note,'amount',r.credit_amount,'quantity',r.quantity,'reason',r.reason,'lot',r.batch_lot,'created_at',r.updated_at) order by r.id desc),'[]') from charm.sales_returns r where r.order_id=o.id and r.status='credited')
 ) into result
 from charm.orders o join charm.clients c on c.id=o.client_id join charm.users u on u.id=o.salesperson_id
 where o.id=p_order and (charm.can_access(o.salesperson_id) or charm.finance_reader() or charm.logistics_desk());
 if result is null then raise exception 'notFound';end if;
 return result;
end$$;

create or replace function charm.logistics_inventory_summary() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not charm.logistics_desk() then raise exception 'forbidden';end if;
 select jsonb_build_object(
  'rows',coalesce(jsonb_agg(to_jsonb(x) order by x.category,x.capacity,x.sku),'[]'::jsonb),
  'updated_at',now()
 ) into result
 from (
  select p.id product_id,p.sku,p.category,p.capacity,p.fragrance,p.packaging_type,p.volume_ml,p.carton,
   coalesce(s.on_hand,0)::bigint on_hand,coalesce(s.saleable,0)::bigint saleable,
   coalesce(r.reserved,0)::bigint reserved,
   greatest(coalesce(s.saleable,0)-coalesce(r.reserved,0),0)::bigint available,
   coalesce(q.scheduled,0)::bigint scheduled
  from charm.products p
  left join lateral (
   select coalesce(sum(x.quantity),0)-coalesce((
     select sum(i.quantity*case when i.unit='carton' then p.carton else 1 end)
     from charm.sales_delivery_items i join charm.sales_deliveries d on d.id=i.delivery_id
     where i.product_id=p.id and d.status='delivered'
    ),0) on_hand,
    coalesce(sum(x.quantity) filter(where x.expires_on is null or x.expires_on>=(now() at time zone 'Africa/Nairobi')::date),0)-coalesce((
     select sum(i.quantity*case when i.unit='carton' then p.carton else 1 end)
     from charm.sales_delivery_items i join charm.sales_deliveries d on d.id=i.delivery_id
     where i.product_id=p.id and d.status='delivered'
    ),0) saleable
   from charm.sales_finished_stock x where x.product_id=p.id
  ) s on true
  left join lateral (
   select coalesce(sum(i.quantity*case when i.unit='carton' then p.carton else 1 end),0) reserved
   from charm.order_items i join charm.orders o on o.id=i.order_id
   where i.product_id=p.id and o.status='confirmed'
    and not exists(select 1 from charm.sales_deliveries d where d.order_id=o.id and d.status='delivered')
  ) r on true
  left join lateral (
   select coalesce(sum(sc.scheduled_quantity),0) scheduled from charm.sales_batch_schedule sc
   where sc.product_id=p.id and sc.status in ('scheduled','ready')
    and sc.ready_on>=(now() at time zone 'Africa/Nairobi')::date
  ) q on true
  where p.active
 ) x;
 return result;
end$$;

create or replace function charm.sales_inventory_ledger(p_limit integer default 60) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if charm.actor() is null then raise exception 'unauthorized';end if;
 if p_limit is null or p_limit not between 1 and 200 then raise exception 'invalid';end if;
 return jsonb_build_object('rows',(
  select coalesce(jsonb_agg(jsonb_build_object('occurred_at',y.occurred_at,'kind',y.kind,'reference',y.reference,'sku',y.sku,'product',y.product,'quantity',y.quantity,'unit',y.unit,'detail',y.detail) order by y.occurred_at desc,y.sort desc),'[]')
  from (
   select x.* from (
    select s.created_at occurred_at,case when s.reference like 'manual-count:%' then 'adjustment' else 'receipt' end::text kind,
     s.lot_number reference,p.sku,p.category||' · '||p.capacity product,s.quantity,''::text unit,
     coalesce(nullif(s.reference,''),'Finished goods') detail,0 sort
    from charm.sales_finished_stock s join charm.products p on p.id=s.product_id
    union all
    select d.delivered_at,'dispatch',d.delivery_number,p.sku,p.category||' · '||p.capacity,
     sum(-(i.quantity*case when i.unit='carton' then p.carton else 1 end))::integer,'units',c.name,1
    from charm.sales_delivery_items i join charm.sales_deliveries d on d.id=i.delivery_id
    join charm.products p on p.id=i.product_id join charm.clients c on c.id=d.client_id
    where d.status='delivered' and (charm.is_admin() or charm.logistics_desk() or d.salesperson_id=charm.actor())
    group by d.delivered_at,d.delivery_number,p.sku,p.category,p.capacity,c.name
   ) x order by x.occurred_at desc,x.sort desc limit p_limit
  ) y
 ));
end$$;

create or replace function charm.logistics_set_finished_stock(p_key uuid,p_product bigint,p_count integer,p_reason text,p_lot text default '') returns bigint
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();p charm.products;current_count bigint;delta integer;movement_id bigint;old bigint;
begin
 if not charm.logistics_desk() then raise exception 'forbidden';end if;
 if p_product is null or p_count is null or p_count<0 or coalesce(length(trim(p_reason)),0) not between 3 and 500 or coalesce(length(trim(p_lot)),0)>120 then raise exception 'invalid';end if;
 old:=charm.claim(p_key,'logistics_stock_count',jsonb_build_object('product',p_product,'count',p_count,'reason',trim(p_reason),'lot',trim(coalesce(p_lot,''))));
 if old is not null then return old;end if;
 perform pg_advisory_xact_lock(hashtextextended('finished-stock:'||p_product::text,0));
 select * into p from charm.products where id=p_product and active for update;
 if not found then raise exception 'notFound';end if;
 select coalesce(sum(s.quantity),0)-coalesce((
  select sum(i.quantity*case when i.unit='carton' then p.carton else 1 end)
  from charm.sales_delivery_items i join charm.sales_deliveries d on d.id=i.delivery_id
  where i.product_id=p.id and d.status='delivered'
 ),0) into current_count from charm.sales_finished_stock s where s.product_id=p.id;
 delta:=p_count-current_count;
 if delta=0 then return charm.finish(p_key,0);end if;
 insert into charm.sales_finished_stock(product_id,lot_number,quantity,expires_on,reference,created_by)
  values(p.id,coalesce(nullif(trim(p_lot),''),'COUNT-'||to_char(now() at time zone 'Africa/Nairobi','YYYYMMDD')||'-'||substr(replace(p_key::text,'-',''),1,8)),delta,null,
   'manual-count:'||trim(p_reason),a) returning id into movement_id;
 perform charm.audit('finishedStockCounted','sales_finished_stock',movement_id,jsonb_build_object('product_id',p.id,'sku',p.sku,'before',current_count,'counted',p_count,'delta',delta,'reason',trim(p_reason),'lot',trim(coalesce(p_lot,''))));
 return charm.finish(p_key,movement_id);
end$$;

revoke execute on function charm.logistics_link_formula_product(bigint,bigint),charm.logistics_inventory_summary(),charm.logistics_set_finished_stock(uuid,bigint,integer,text,text),charm.link_batch_to_finished_schedules(),charm.receive_released_finished_batch() from public,anon;
grant execute on function charm.logistics_link_formula_product(bigint,bigint),charm.logistics_inventory_summary(),charm.logistics_set_finished_stock(uuid,bigint,integer,text,text) to authenticated;
grant execute on function charm.sales_document_payload(bigint) to authenticated;
revoke execute on function charm.sales_inventory_ledger(integer) from public,anon,authenticated;
grant execute on function charm.sales_inventory_ledger(integer) to authenticated;
revoke execute on function charm.production_start_batch(bigint,numeric) from public,anon,authenticated;
grant execute on function charm.production_start_batch(bigint,numeric) to authenticated;

notify pgrst,'reload schema';
commit;

-- Quotation price book. The quotation sheet is the authoritative source for
-- bottle/carton wholesaler and retailer prices. Every price carries an
-- effective date, so historical order values are never recalculated.
-- The sheet's printed gross profit margin is a commercial margin, not a
-- commission rate and is never used by the commission engine.
begin;

alter table charm.products add column if not exists pricing_flags text[] not null default '{}';

create table if not exists charm.product_prices(
  id bigserial primary key,
  product_id bigint not null references charm.products(id),
  customer_type text not null check(customer_type in ('wholesaler','retailer')),
  unit text not null check(unit in ('bottle','carton')),
  price numeric(14,2) not null check(price>0),
  effective_from date not null default (now() at time zone 'Africa/Nairobi')::date,
  source text not null default 'manual' check(source in ('quotation','manual','contract')),
  source_ref text not null default '',
  created_by bigint references charm.users(id),
  created_at timestamptz not null default now(),
  unique(product_id,customer_type,unit,effective_from)
);
alter table charm.product_prices enable row level security;
create index if not exists product_prices_lookup on charm.product_prices(product_id,customer_type,unit,effective_from desc,id desc);
create policy product_price_read on charm.product_prices for select to authenticated using(charm.actor() is not null);
grant select on charm.product_prices to authenticated;

create table if not exists charm.quotation_batches(
  id bigserial primary key,
  file_name text not null,
  effective_from date not null,
  imported_by bigint references charm.users(id),
  imported_at timestamptz not null default now(),
  row_count integer not null default 0,
  flag_count integer not null default 0,
  price_count integer not null default 0,
  notes text not null default '',
  unique(file_name,effective_from)
);
create table if not exists charm.quotation_rows(
  id bigserial primary key,
  batch_id bigint not null references charm.quotation_batches(id),
  line_no integer not null,
  product_id bigint references charm.products(id),
  category text not null,
  capacity text not null,
  barcode text,
  fragrance text not null,
  wholesale_bottle numeric(14,2) not null check(wholesale_bottle>0),
  carton_quantity integer not null check(carton_quantity>0),
  wholesale_carton numeric(14,2) not null check(wholesale_carton>0),
  retail_bottle numeric(14,2) not null check(retail_bottle>0),
  margin_percent numeric(6,2) not null,
  flags text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique(batch_id,line_no)
);
alter table charm.quotation_batches enable row level security;
alter table charm.quotation_rows enable row level security;
create index if not exists quotation_rows_batch on charm.quotation_rows(batch_id,line_no);
create index if not exists quotation_rows_barcode on charm.quotation_rows(batch_id,barcode);
create policy quotation_batch_admin on charm.quotation_batches for select to authenticated using(charm.is_admin());
create policy quotation_row_admin on charm.quotation_rows for select to authenticated using(charm.is_admin());
grant select on charm.quotation_batches,charm.quotation_rows to authenticated;

insert into charm.quotation_batches(file_name,effective_from,notes)
values('Store - Quotation for all specifications.pdf',(now() at time zone 'Africa/Nairobi')::date,
       'Imported from docs/Store - Quotation for all specifications.pdf. Source anomalies are preserved and flagged for review.')
on conflict(file_name,effective_from) do nothing;

insert into charm.quotation_rows(batch_id,line_no,product_id,category,capacity,barcode,fragrance,wholesale_bottle,carton_quantity,wholesale_carton,retail_bottle,margin_percent)
select b.id,v.line_no,v.product_id,v.category,v.capacity,v.barcode,v.fragrance,v.wholesale_bottle,v.carton_quantity,v.wholesale_carton,v.retail_bottle,v.margin_percent
from charm.quotation_batches b
cross join (values
 (1,1,'Handwash','500ml','0721688311874','YLANG-YLANG',133.00,20,2660.00,190.00,30.0),
 (2,2,'Handwash','500ml','0724133585417','AZURE BREEZE',133.00,20,2660.00,190.00,30.0),
 (3,3,'Handwash','500ml','0724133585424','PENINSULA DEW',133.00,20,2660.00,190.00,30.0),
 (4,4,'Handwash','500ml','0724133585431','ROSE SCENT',133.00,20,2660.00,190.00,30.0),
 (5,5,'Handwash','5L','0724133585615','YLANG-YLANG',826.00,4,3304.00,1180.00,30.0),
 (6,6,'Handwash','5L','0724133585608','AZURE BREEZE',826.00,4,3304.00,1180.00,30.0),
 (7,7,'Handwash','5L','0724133585653','PENINSULA DEW',826.00,4,3304.00,1180.00,30.0),
 (8,8,'Handwash','5L','0724133585530','ROSE SCENT',826.00,4,3304.00,1180.00,30.0),
 (9,9,'Shampoo','200ml','0745760226535','SILENT AROMA',122.50,36,4410.00,175.00,30.0),
 (10,10,'Shampoo','200ml','0745760226511','AMBER BOMB',122.50,36,4410.00,175.00,30.0),
 (11,11,'Shampoo','200ml','0745760226528','NEON DREAM',122.50,36,4410.00,175.00,30.0),
 (12,12,'Shampoo','750ml','0721688311850','SILENT AROMA',364.00,12,4368.00,520.00,30.0),
 (13,13,'Shampoo','750ml','0724133585455','AMBER BOMB',364.00,12,4368.00,520.00,30.0),
 (14,14,'Shampoo','750ml','0724133585462','NEON DREAM',364.00,12,4368.00,520.00,30.0),
 (15,15,'Shampoo','5L','0724133585684','SILENT AROMA',1386.00,4,5544.00,1980.00,30.0),
 (16,16,'Shampoo','5L','0724133585677','AMBER BOMB',1386.00,4,5544.00,1980.00,30.0),
 (17,17,'Shampoo','5L','0724133585622','NEON DREAM',1386.00,4,5544.00,1980.00,30.0),
 (18,18,'Shower Gel','200ml','0745760226559','PHEROMONE',116.20,36,4183.20,166.00,30.0),
 (19,19,'Shower Gel','200ml','0745760226504','HEARTBEAT / WHISPER',116.20,36,4183.20,166.00,30.0),
 (20,20,'Shower Gel','200ml','0745760226559','MILAN FOGLAND',116.20,36,4183.20,166.00,30.0),
 (21,21,'Shower Gel','200ml','0745760226542','SILENT AROMA',116.20,36,4183.20,166.00,30.0),
 (22,22,'Shower Gel','750ml','0721688311843','PHEROMONE',339.50,12,4074.00,485.00,30.0),
 (23,23,'Shower Gel','750ml','0724133585479','HEARTBEAT / WHISPER',339.50,12,4074.00,485.00,30.0),
 (24,24,'Shower Gel','751ml','0724133585554','MILAN FOGLAND',339.50,12,4074.00,485.00,30.0),
 (25,25,'Shower Gel','750ml','0724133585486','SILENT AROMA',339.50,12,4074.00,485.00,30.0),
 (26,26,'Shower Gel','5L','0724133585639','PHEROMONE',1246.00,4,4984.00,1780.00,30.0),
 (27,27,'Shower Gel','5L','0724133585509','HEARTBEAT / WHISPER',1246.00,4,4984.00,1780.00,30.0),
 (28,28,'Shower Gel','5L','0724133585646','MILAN FOGLAND',1246.00,4,4984.00,1780.00,30.0),
 (29,29,'Shower Gel','5L','0724133585523','SILENT AROMA',1246.00,4,4984.00,1780.00,30.0),
 (30,30,'Laundry Detergent','750ml','0745760226573','FRAGANT YLANG-YLANG',231.00,24,5544.00,330.00,30.0),
 (31,31,'Laundry Detergent','750ml','0725765720740','ROSE',231.00,24,5544.00,330.00,30.0),
 (32,32,'Laundry Detergent','1500ml','0721688311829','FRAGANT YLANG-YLANG',369.60,12,4435.20,528.00,30.0),
 (33,33,'Laundry Detergent','1500ml','0724133585448','ROSE',369.60,12,4435.20,528.00,30.0),
 (34,34,'Laundry Detergent','5L','0724133585493','FRAGANT YLANG-YLANG',1036.00,4,4144.00,1480.00,30.0),
 (35,35,'Laundry Detergent','5L','0724133585516','ROSE',1036.00,4,4144.00,1480.00,30.0),
 (36,36,'Dish Washing Liquid','500ml','0745760226566','LEMON',132.30,24,3175.20,189.00,30.0),
 (37,37,'Dish Washing Liquid','500ml','0745760226580','GINGER',132.30,24,3175.20,189.00,30.0),
 (38,38,'Dish Washing Liquid','1500ml','0721688311836','LEMON',277.10,12,3325.20,396.00,30.0),
 (39,39,'Dish Washing Liquid','1500ml','0724133585400','GINGER',277.10,12,3325.20,396.00,30.0),
 (40,40,'Dish Washing Liquid','5L','0724133585592','LEMON',770.00,4,3080.00,1100.00,30.0),
 (41,41,'Dish Washing Liquid','5L','0724133585660','GINGER',770.00,4,3080.00,1100.00,30.0),
 (42,42,'Windshield & Glass Cleaner','1600ml','0745760226597','ORANGE',203.00,12,2436.00,290.00,30.0),
 (43,43,'Windshield & Glass Cleaner','2000ml','0721688311867','ORANGE',245.00,6,1470.00,350.00,30.0),
 (44,44,'Windshield & Glass Cleaner','5L','0724133585585','ORANGE',490.00,4,1960.00,700.00,30.0),
 (45,45,'Automotive Interior Cleaner','950ml','0721688311812','ROME',276.50,12,3318.00,395.00,30.0),
 (46,46,'Automotive Interior Cleaner','5L','0724133585578','ROME',882.00,4,3528.00,1260.00,30.0),
 (47,47,'Tire Shine','950ml','0721688311805','NONE',294.70,12,3536.40,421.00,30.0),
 (48,48,'Tire Shine','5L','0724133585561','NONE',966.00,4,3864.00,1380.00,30.0)
) as v(line_no,product_id,category,capacity,barcode,fragrance,wholesale_bottle,carton_quantity,wholesale_carton,retail_bottle,margin_percent)
where b.file_name='Store - Quotation for all specifications.pdf'
  and b.effective_from=(now() at time zone 'Africa/Nairobi')::date
on conflict(batch_id,line_no) do nothing;

do $$
declare b bigint; d date:=(now() at time zone 'Africa/Nairobi')::date;
begin
 select id into b from charm.quotation_batches where file_name='Store - Quotation for all specifications.pdf' and effective_from=d;
 if b is null then return; end if;

 update charm.quotation_rows q set flags=array_append(flags,'duplicate_barcode')
 where q.batch_id=b and q.barcode is not null and exists(
  select 1 from charm.quotation_rows x where x.batch_id=b and x.barcode=q.barcode group by x.barcode having count(*)>1);

 update charm.quotation_rows set flags=array_append(flags,'ambiguous_fragrance')
 where batch_id=b and (fragrance like '%/%' or fragrance like '% WHISPER%');

 update charm.quotation_rows set flags=array_append(flags,'capacity_typo')
 where batch_id=b and capacity not in ('200ml','500ml','750ml','950ml','1500ml','1600ml','2000ml','5L');

 update charm.quotation_rows set flags=array_append(flags,'verify_barcode')
 where batch_id=b and barcode like '072576%';

 update charm.quotation_rows set flags=array_append(flags,'missing_barcode')
 where batch_id=b and coalesce(trim(barcode),'')='';

 update charm.quotation_rows q set flags=array_append(flags,'product_mismatch')
 where q.batch_id=b and (q.product_id is null or not exists(
  select 1 from charm.products p where p.id=q.product_id
   and lower(trim(p.category))=lower(trim(q.category))
   and lower(trim(p.capacity))=lower(trim(q.capacity))
   and p.barcode=q.barcode and p.carton=q.carton_quantity));

 update charm.quotation_rows set flags=array_append(flags,'margin_mismatch')
 where batch_id=b and abs(round((retail_bottle-wholesale_bottle)/retail_bottle*100,1)-margin_percent)>0.05;

 update charm.quotation_rows set flags=array_append(flags,'carton_total_mismatch')
 where batch_id=b and abs(wholesale_bottle*carton_quantity-wholesale_carton)>0.01;

 update charm.quotation_rows set flags=array_append(flags,'retail_below_wholesale')
 where batch_id=b and retail_bottle<=wholesale_bottle;

 update charm.products p set pricing_flags=q.flags,
  needs_review=(p.needs_review or coalesce(cardinality(q.flags),0)>0), updated_at=now()
 from charm.quotation_rows q where q.batch_id=b and q.product_id=p.id;

 insert into charm.product_prices(product_id,customer_type,unit,price,effective_from,source,source_ref)
 select q.product_id,'wholesaler','bottle',q.wholesale_bottle,d,'quotation','Quotation line '||q.line_no
 from charm.quotation_rows q where q.batch_id=b and q.product_id is not null
 union all
 select q.product_id,'wholesaler','carton',q.wholesale_carton,d,'quotation','Quotation line '||q.line_no
 from charm.quotation_rows q where q.batch_id=b and q.product_id is not null
 union all
 select q.product_id,'retailer','bottle',q.retail_bottle,d,'quotation','Quotation line '||q.line_no
 from charm.quotation_rows q where q.batch_id=b and q.product_id is not null
 union all
 select q.product_id,'retailer','carton',round(q.retail_bottle*q.carton_quantity,2),d,'quotation','Quotation line '||q.line_no
 from charm.quotation_rows q where q.batch_id=b and q.product_id is not null
 on conflict(product_id,customer_type,unit,effective_from) do update
  set price=excluded.price,source=excluded.source,source_ref=excluded.source_ref;

 update charm.quotation_batches set
  row_count=(select count(*) from charm.quotation_rows where batch_id=b),
  flag_count=(select count(*) from charm.quotation_rows where batch_id=b and cardinality(flags)>0),
  price_count=(select count(*) from charm.product_prices where source='quotation' and effective_from=(select effective_from from charm.quotation_batches where id=b))
 where id=b;
end $$;

create function charm.product_price_on(p_product bigint,p_customer_type text,p_unit text,p_on date default null) returns numeric
language plpgsql stable security definer set search_path='' as $$
declare d date:=coalesce(p_on,(now() at time zone 'Africa/Nairobi')::date); result numeric;
begin
 if charm.actor() is null then raise exception 'unauthorized'; end if;
 if p_customer_type not in ('wholesaler','retailer') or p_unit not in ('bottle','carton') then raise exception 'invalid'; end if;
 select pp.price into result from charm.product_prices pp
  where pp.product_id=p_product and pp.customer_type=p_customer_type and pp.unit=p_unit and pp.effective_from<=d
  order by pp.effective_from desc,pp.id desc limit 1;
 return result;
end $$;

create function charm.product_price_book(p_on date default null)
returns table(product_id bigint,sku text,category text,capacity text,fragrance text,barcode text,carton_quantity integer,
 wholesale_bottle numeric,wholesale_carton numeric,retail_bottle numeric,retail_carton numeric,margin_percent numeric,
 wholesale_effective_from date,retail_effective_from date,needs_review boolean,pricing_flags text[])
language sql stable security definer set search_path='' as $$
with d as (select coalesce(p_on,(now() at time zone 'Africa/Nairobi')::date) as on_date)
select p.id,p.sku::text,p.category::text,p.capacity::text,p.fragrance::text,p.barcode::text,p.carton,
 wb.price,wc.price,rb.price,rc.price,
 round((rb.price-wb.price)/nullif(rb.price,0)*100,1),
 wb.effective_from,rb.effective_from,p.needs_review,p.pricing_flags
from charm.products p cross join d
left join lateral(select pp.price,pp.effective_from from charm.product_prices pp where pp.product_id=p.id and pp.customer_type='wholesaler' and pp.unit='bottle' and pp.effective_from<=d.on_date order by pp.effective_from desc,pp.id desc limit 1) wb on true
left join lateral(select pp.price from charm.product_prices pp where pp.product_id=p.id and pp.customer_type='wholesaler' and pp.unit='carton' and pp.effective_from<=d.on_date order by pp.effective_from desc,pp.id desc limit 1) wc on true
left join lateral(select pp.price,pp.effective_from from charm.product_prices pp where pp.product_id=p.id and pp.customer_type='retailer' and pp.unit='bottle' and pp.effective_from<=d.on_date order by pp.effective_from desc,pp.id desc limit 1) rb on true
left join lateral(select pp.price from charm.product_prices pp where pp.product_id=p.id and pp.customer_type='retailer' and pp.unit='carton' and pp.effective_from<=d.on_date order by pp.effective_from desc,pp.id desc limit 1) rc on true
where p.active and charm.actor() is not null
order by p.category,p.volume_ml nulls last,p.capacity,p.fragrance
$$;

create function charm.product_price_history(p_product bigint)
returns table(customer_type text,unit text,price numeric,effective_from date,source text,source_ref text,created_by bigint,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
 perform charm.require_admin();
 return query select pp.customer_type::text,pp.unit::text,pp.price,pp.effective_from,pp.source::text,pp.source_ref,pp.created_by,pp.created_at
  from charm.product_prices pp where pp.product_id=p_product order by pp.customer_type,pp.unit,pp.effective_from desc,pp.id desc;
end $$;

create function charm.set_product_price(p_key uuid,p_product bigint,p_customer_type text,p_unit text,p_price numeric,p_effective_from date default null,p_note text default '') returns bigint
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); d date:=coalesce(p_effective_from,(now() at time zone 'Africa/Nairobi')::date); old bigint; pid bigint;
begin
 if p_customer_type not in ('wholesaler','retailer') or p_unit not in ('bottle','carton') or p_price is null or p_price<=0 or p_price>999999999999.99 then raise exception 'invalid'; end if;
 if not exists(select 1 from charm.products where id=p_product and active) then raise exception 'notFound'; end if;
 old:=charm.claim(p_key,'product_price',jsonb_build_object('product',p_product,'customer_type',p_customer_type,'unit',p_unit,'price',p_price,'effective_from',d,'note',coalesce(p_note,'')));
 if old is not null then return old; end if;
 insert into charm.product_prices(product_id,customer_type,unit,price,effective_from,source,source_ref,created_by)
 values(p_product,p_customer_type,p_unit,p_price,d,'manual',left(coalesce(p_note,''),500),a)
 on conflict(product_id,customer_type,unit,effective_from) do update
  set price=excluded.price,source='manual',source_ref=excluded.source_ref,created_by=excluded.created_by,created_at=now()
 returning id into pid;
 perform charm.audit('priced','products',p_product,jsonb_build_object('customer_type',p_customer_type,'unit',p_unit,'price',p_price,'effective_from',d));
 update charm.products set updated_at=now() where id=p_product;
 return charm.finish(p_key,pid);
end $$;

-- Missing order-line prices resolve from the price book for the order's
-- customer classification. Explicit prices remain available for approved
-- negotiated contracts and are still audited through the order.
create or replace function charm.save_order_draft(p_key uuid,p_id bigint,p_client bigint,p_due date,p_items jsonb,p_customer_type text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); c charm.clients; p charm.products; item jsonb; v_id bigint; old bigint; qty integer; price numeric; raw_price text; v_total numeric:=0; locked boolean:=false;
begin
 if p_id is null then old:=charm.claim(p_key,'order_draft',jsonb_build_object('client',p_client,'due',p_due,'items',p_items,'customer_type',p_customer_type));if old is not null then return old;end if;end if;
 if p_customer_type not in ('wholesaler','retailer') or p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 100 then raise exception 'invalid';end if;
 select * into c from charm.clients where clients.id=p_client for share;
 if not found or not charm.can_access(c.salesperson_id) then raise exception 'forbidden';end if;
 if p_id is not null then
  select contract_status='submitted' into locked from charm.orders where orders.id=p_id and charm.can_access(orders.salesperson_id);
  if locked then raise exception 'contractLocked';end if;
 end if;
 for item in select value from jsonb_array_elements(p_items) loop
  select * into p from charm.products where products.id=(item->>'product_id')::bigint and active;
  if not found or item->>'unit' not in ('bottle','carton') then raise exception 'invalid';end if;
  if coalesce(item->>'quantity','') !~ '^\d+$' then raise exception 'invalidQuantity';end if;
  qty:=(item->>'quantity')::integer;if qty not between 1 and 100000 then raise exception 'invalidQuantity';end if;
  raw_price:=nullif(trim(coalesce(item->>'unit_price','')),'');
  if raw_price is null then price:=charm.product_price_on(p.id,p_customer_type,item->>'unit');if price is null then raise exception 'priceRequired';end if;
  else price:=charm.money(raw_price);end if;
  v_total:=v_total+qty*price;
 end loop;
 if p_id is null then
  insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,customer_type,created_at,updated_at)
  values(p_key,p_client,c.salesperson_id,a,v_total,p_due,'draft',p_customer_type,now(),now()) returning orders.id into v_id;
 else
  select orders.id into v_id from charm.orders where orders.id=p_id and orders.status='draft' and charm.can_access(orders.salesperson_id) for update;
  if v_id is null then raise exception 'forbidden';end if;
  update charm.orders set client_id=p_client,total=v_total,due_date=p_due,customer_type=p_customer_type,updated_at=now() where orders.id=v_id;
  delete from charm.order_items where order_items.order_id=v_id;
 end if;
 for item in select value from jsonb_array_elements(p_items) loop
  select * into p from charm.products where products.id=(item->>'product_id')::bigint;
  raw_price:=nullif(trim(coalesce(item->>'unit_price','')),'');
  if raw_price is null then price:=charm.product_price_on(p.id,p_customer_type,item->>'unit');if price is null then raise exception 'priceRequired';end if;
  else price:=charm.money(raw_price);end if;
  insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total)
  values(v_id,p.id,concat(p.category,' ',p.capacity,' ',p.fragrance),item->>'unit',(item->>'quantity')::integer,price,(item->>'quantity')::integer*price);
 end loop;
 perform charm.audit(case when p_id is null then 'draft_created' else 'draft_updated' end,'orders',v_id);
 if p_id is null then return charm.finish(p_key,v_id);end if;return v_id;
end $$;

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

revoke execute on function charm.product_price_on(bigint,text,text,date),charm.product_price_book(date),charm.product_price_history(bigint),charm.set_product_price(uuid,bigint,text,text,numeric,date,text) from public,anon,authenticated;
grant execute on function charm.product_price_on(bigint,text,text,date),charm.product_price_book(date),charm.product_price_history(bigint),charm.set_product_price(uuid,bigint,text,text,numeric,date,text) to authenticated;
commit;

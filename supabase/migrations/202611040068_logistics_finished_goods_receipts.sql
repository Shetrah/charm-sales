begin;

-- Add received finished goods as a positive inventory-ledger movement.
-- The product lock keeps receipts serialized with physical counts, and the
-- request receipt makes retries safe if a client loses the response.
create or replace function charm.logistics_receive_finished_stock(
 p_key uuid,
 p_product bigint,
 p_quantity integer,
 p_lot text default '',
 p_expiry date default null,
 p_reference text default ''
) returns bigint
language plpgsql security definer set search_path='' as $$
declare
 a bigint:=charm.require_actor();
 p charm.products;
 movement_id bigint;
 old bigint;
 lot_value text;
 reference_value text;
begin
 if not charm.logistics_desk() then raise exception 'forbidden'; end if;
 if p_key is null or p_product is null or p_quantity is null or p_quantity not between 1 and 1000000 or
    coalesce(length(trim(p_lot)),0)>120 or coalesce(length(trim(p_reference)),0)>160 or
    (p_expiry is not null and p_expiry<(now() at time zone 'Africa/Nairobi')::date) then
  raise exception 'invalid';
 end if;

 old:=charm.claim(p_key,'logistics_finished_goods_receipt',jsonb_build_object(
  'product',p_product,'quantity',p_quantity,'lot',trim(coalesce(p_lot,'')),
  'expiry',p_expiry,'reference',trim(coalesce(p_reference,''))));
 if old is not null then return old; end if;

 perform pg_advisory_xact_lock(hashtextextended('finished-stock:'||p_product::text,0));
 select * into p from charm.products where id=p_product and active for update;
 if not found then raise exception 'notFound'; end if;

 lot_value:=coalesce(nullif(trim(p_lot),''),'RECEIPT-'||to_char(now() at time zone 'Africa/Nairobi','YYYYMMDDHH24MISS')||'-'||substr(replace(p_key::text,'-',''),1,8));
 reference_value:=coalesce(nullif(trim(p_reference),''),'manual-receipt:'||p_key::text);
 insert into charm.sales_finished_stock(product_id,lot_number,quantity,expires_on,reference,created_by)
 values(p.id,lot_value,p_quantity,p_expiry,reference_value,a)
 returning id into movement_id;

 perform charm.audit('finishedGoodsReceived','sales_finished_stock',movement_id,jsonb_build_object(
  'product_id',p.id,'sku',p.sku,'quantity',p_quantity,'lot',lot_value,
  'expires_on',p_expiry,'reference',reference_value));
 return charm.finish(p_key,movement_id);
end $$;

revoke execute on function charm.logistics_receive_finished_stock(uuid,bigint,integer,text,date,text) from public,anon;
grant execute on function charm.logistics_receive_finished_stock(uuid,bigint,integer,text,date,text) to authenticated;

notify pgrst,'reload schema';
commit;

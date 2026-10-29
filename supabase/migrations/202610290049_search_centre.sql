-- Global search centre: role-scoped lookup across clients, orders, deliveries and products.
begin;
create function charm.search_centre(p_query text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare needle text;begin
 if charm.actor() is null then raise exception 'unauthorized';end if;
 needle=lower(btrim(coalesce(p_query,'')));
 if length(needle)<2 or length(needle)>60 then raise exception 'invalid';end if;
 return jsonb_build_object(
  'clients',(select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'name',x.name,'contact',x.contact,'phone',x.phone,'location',x.location) order by x.name),'[]') from(
   select c.id,c.name,c.contact,c.phone,c.location from charm.clients c
   where charm.can_access(c.salesperson_id) and (
    position(needle in lower(c.name))>0
    or position(needle in lower(coalesce(c.contact,'')))>0
    or position(needle in coalesce(c.phone,''))>0
    or position(needle in lower(coalesce(c.location,'')))>0)
   order by c.name limit 6) x),
  'orders',(select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'status',x.status,'total',x.total,'due_date',x.due_date,'client',x.client,'contract_reference',x.contract_reference) order by x.id desc),'[]') from(
   select o.id,o.status,o.total,o.due_date,cl.name client,o.contract_reference from charm.orders o join charm.clients cl on cl.id=o.client_id
   where charm.can_access(o.salesperson_id) and (
    o.id::text=needle
    or position(needle in lower(coalesce(o.contract_reference,'')))>0
    or position(needle in lower(cl.name))>0)
   order by o.id desc limit 6) x),
  'deliveries',(select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'delivery_number',x.delivery_number,'status',x.status,'scheduled_on',x.scheduled_on,'client',x.client) order by x.id desc),'[]') from(
   select d.id,d.delivery_number,d.status,d.scheduled_on,cl.name client from charm.sales_deliveries d join charm.clients cl on cl.id=d.client_id
   where charm.can_access(d.salesperson_id) and (
    position(needle in lower(d.delivery_number))>0
    or position(needle in lower(cl.name))>0
    or d.order_id::text=needle)
   order by d.id desc limit 6) x),
  'products',(select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'sku',x.sku,'category',x.category,'capacity',x.capacity,'fragrance',x.fragrance,'barcode',x.barcode) order by x.sku),'[]') from(
   select p.id,p.sku,p.category,p.capacity,p.fragrance,p.barcode from charm.products p
   where p.active and (
    position(needle in lower(coalesce(p.sku,'')))>0
    or position(needle in lower(p.category))>0
    or position(needle in lower(coalesce(p.fragrance,'')))>0
    or position(needle in lower(coalesce(p.barcode,'')))>0
    or position(needle in lower(p.capacity))>0)
   order by p.sku limit 6) x)
 );
end$$;
revoke execute on function charm.search_centre(text) from public,anon,authenticated;
grant execute on function charm.search_centre(text) to authenticated;
notify pgrst,'reload schema';
commit;

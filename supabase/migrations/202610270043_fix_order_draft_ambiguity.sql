-- Fix ambiguous plpgsql variable in the draft-update path:
-- `delete from charm.order_items where order_id=id` resolved `id` against
-- order_items.id as well as the local variable when p_id was supplied.
create or replace function charm.save_order_draft(p_key uuid,p_id bigint,p_client bigint,p_due date,p_items jsonb,p_customer_type text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); c charm.clients; p charm.products; item jsonb; v_id bigint; old bigint; qty integer; price numeric; v_total numeric:=0; locked boolean:=false;
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
  price:=charm.money(item->>'unit_price');v_total:=v_total+qty*price;
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
  insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total)
  values(v_id,p.id,concat(p.category,' ',p.capacity,' ',p.fragrance),item->>'unit',(item->>'quantity')::integer,(item->>'unit_price')::numeric,(item->>'quantity')::integer*(item->>'unit_price')::numeric);
 end loop;
 perform charm.audit(case when p_id is null then 'draft_created' else 'draft_updated' end,'orders',v_id);
 if p_id is null then return charm.finish(p_key,v_id);end if;return v_id;
end $$;

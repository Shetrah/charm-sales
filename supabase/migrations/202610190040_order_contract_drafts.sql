begin;
alter table charm.orders add column if not exists contract_path text;
alter table charm.orders add column if not exists customer_type text not null default 'retailer';
alter table charm.orders drop constraint if exists orders_customer_type_check;
alter table charm.orders add constraint orders_customer_type_check check(customer_type in ('wholesaler','retailer'));
alter table charm.orders drop constraint if exists orders_status_check;
alter table charm.orders add constraint orders_status_check check(status in ('draft','pending','confirmed','rejected','cancelled'));
create or replace function charm.save_order_draft(p_key uuid,p_id bigint,p_client bigint,p_due date,p_items jsonb,p_customer_type text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); c charm.clients; p charm.products; item jsonb; id bigint; old bigint; qty integer; price numeric; v_total numeric:=0;
begin
 if p_id is null then old:=charm.claim(p_key,'order_draft',jsonb_build_object('client',p_client,'due',p_due,'items',p_items,'customer_type',p_customer_type));if old is not null then return old;end if;end if;
 if p_customer_type not in ('wholesaler','retailer') or p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 100 then raise exception 'invalid';end if;
 select * into c from charm.clients where clients.id=p_client for share;
 if not found or not charm.can_access(c.salesperson_id) then raise exception 'forbidden';end if;
 for item in select value from jsonb_array_elements(p_items) loop
  select * into p from charm.products where products.id=(item->>'product_id')::bigint and active;
  if not found or item->>'unit' not in ('bottle','carton') then raise exception 'invalid';end if;
  if coalesce(item->>'quantity','') !~ '^\d+$' then raise exception 'invalidQuantity';end if;
  qty:=(item->>'quantity')::integer;if qty not between 1 and 100000 then raise exception 'invalidQuantity';end if;
  price:=charm.money(item->>'unit_price');v_total:=v_total+qty*price;
 end loop;
 if p_id is null then
  insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,customer_type,created_at,updated_at)
  values(p_key,p_client,c.salesperson_id,a,v_total,p_due,'draft',p_customer_type,now(),now()) returning orders.id into id;
 else
  select orders.id into id from charm.orders where orders.id=p_id and orders.status='draft' and charm.can_access(orders.salesperson_id) for update;
  if id is null then raise exception 'forbidden';end if;
  update charm.orders set client_id=p_client,total=v_total,due_date=p_due,customer_type=p_customer_type,updated_at=now() where orders.id=id;
  delete from charm.order_items where order_id=id;
 end if;
 for item in select value from jsonb_array_elements(p_items) loop
  select * into p from charm.products where products.id=(item->>'product_id')::bigint;
  insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total)
  values(id,p.id,concat(p.category,' ',p.capacity,' ',p.fragrance),item->>'unit',(item->>'quantity')::integer,(item->>'unit_price')::numeric,(item->>'quantity')::integer*(item->>'unit_price')::numeric);
 end loop;
 perform charm.audit(case when p_id is null then 'draft_created' else 'draft_updated' end,'orders',id);
 if p_id is null then return charm.finish(p_key,id);end if;return id;
end $$;
create function charm.attach_order_contract(p_id bigint,p_path text) returns void language plpgsql security definer set search_path='' as $$
declare o charm.orders;
begin
 perform charm.require_sales_writer();select * into o from charm.orders where id=p_id for update;
 if not found or o.status<>'draft' or not charm.can_access(o.salesperson_id) or p_path not like 'orders/'||p_id||'/%' or not exists(select 1 from storage.objects where bucket_id='charm-private' and name=p_path) then raise exception 'forbidden';end if;
 update charm.orders set contract_path=p_path,updated_at=now() where id=p_id;perform charm.audit('contract_attached','orders',p_id,jsonb_build_object('path',p_path));
end $$;
create function charm.submit_order_draft(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare o charm.orders;
begin
 perform charm.require_sales_writer();select * into o from charm.orders where id=p_id for update;
 if not found or o.status<>'draft' or not charm.can_access(o.salesperson_id) then raise exception 'forbidden';end if;
 if o.contract_path is null then raise exception 'contractRequired';end if;
 if not exists(select 1 from storage.objects where bucket_id='charm-private' and name=o.contract_path) then raise exception 'contractRequired';end if;
 update charm.orders set status='pending',updated_at=now() where id=p_id;perform charm.audit('submitted','orders',p_id,jsonb_build_object('customer_type',o.customer_type,'contract',true));
end $$;
revoke execute on function charm.submit_order(uuid,bigint,date,jsonb),charm.save_order_draft(uuid,bigint,bigint,date,jsonb,text),charm.attach_order_contract(bigint,text),charm.submit_order_draft(bigint) from public,anon,authenticated;
grant execute on function charm.save_order_draft(uuid,bigint,bigint,date,jsonb,text),charm.attach_order_contract(bigint,text),charm.submit_order_draft(bigint) to authenticated;
create or replace function charm.file_access(path text,writing boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare kind text:=split_part(path,'/',1); record_id bigint; owner bigint; status text; contract text;
begin
 if charm.actor() is null or split_part(path,'/',2) !~ '^\d+$' then return false; end if;
 record_id:=split_part(path,'/',2)::bigint;
 if kind='visits' then select salesperson_id into owner from charm.visits where visits.id=record_id;
 elsif kind='payments' then select o.salesperson_id,p.status into owner,status from charm.payments p join charm.orders o on o.id=p.order_id where p.id=record_id;
 elsif kind='orders' then select salesperson_id,orders.status,orders.contract_path into owner,status,contract from charm.orders where orders.id=record_id;
 else return false;end if;
 if writing and kind='payments' and status<>'pending' then return false;end if;
 if kind='orders' and ((writing and status<>'draft') or (not writing and contract is distinct from path)) then return false;end if;
 return owner is not null and coalesce(charm.can_access(owner),false);
end $$;
create or replace function charm.attach_file(p_kind text,p_id bigint,p_path text) returns void language plpgsql security definer set search_path='' as $$
declare p charm.payments;
begin
 perform charm.require_actor();
 if p_kind='payments' then select * into p from charm.payments where id=p_id for update;if p.status<>'pending' then raise exception 'alreadyReviewed';end if;end if;
 if p_kind not in ('visits','payments') or p_path not like p_kind||'/'||p_id||'/%' or not charm.file_access(p_path,true) or not exists(select 1 from storage.objects where bucket_id='charm-private' and name=p_path) then raise exception 'forbidden';end if;
 if p_kind='visits' then update charm.visits set photo_path=p_path where id=p_id;else update charm.payments set proof_path=p_path where id=p_id;end if;
 perform charm.audit('attached',p_kind,p_id,jsonb_build_object('path',p_path));
end $$;
update storage.buckets set file_size_limit=20971520,allowed_mime_types=array['image/jpeg','image/png','image/webp','application/pdf'] where id='charm-private';
drop policy if exists charm_files_read on storage.objects;drop policy if exists charm_files_insert on storage.objects;
create policy charm_files_read on storage.objects for select to authenticated using(bucket_id='charm-private' and charm.file_access(name));
create policy charm_files_insert on storage.objects for insert to authenticated with check(bucket_id='charm-private' and charm.file_access(name,true));
commit;

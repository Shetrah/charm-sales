begin;
create function charm.money(value text) returns numeric language plpgsql immutable set search_path='' as $$
begin
 if value is null or value !~ '^\d{1,12}(\.\d{1,2})?$' or value::numeric<=0 then raise exception 'invalidMoney'; end if;
 return value::numeric;
end $$;

create function charm.submit_order(p_key uuid,p_client bigint,p_due date,p_items jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); c charm.clients; p charm.products; item jsonb; total numeric:=0; id bigint; old bigint; qty integer; price numeric;
begin
 old:=charm.claim(p_key,'order',jsonb_build_object('client',p_client,'due',p_due,'items',p_items)); if old is not null then return old; end if;
 select * into c from charm.clients where clients.id=p_client for share;
 if not found or not charm.can_access(c.salesperson_id) then raise exception 'forbidden'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'invalid'; end if;
 if jsonb_array_length(p_items) not between 1 and 100 then raise exception 'invalid'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  select * into p from charm.products where products.id=(item->>'product_id')::bigint and active;
  if not found or item->>'unit' not in ('bottle','carton') or item->>'unit' is null then raise exception 'invalid'; end if;
  if coalesce(item->>'quantity','') !~ '^\d+$' then raise exception 'invalidQuantity'; end if;
  qty:=(item->>'quantity')::integer; if qty not between 1 and 100000 then raise exception 'invalidQuantity'; end if;
  price:=charm.money(item->>'unit_price'); total:=total+qty*price;
 end loop;
 if total>999999999999.99 then raise exception 'invalidMoney'; end if;
 insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at)
 values(p_key,p_client,c.salesperson_id,a,total,p_due,'pending',now(),now()) returning orders.id into id;
 for item in select value from jsonb_array_elements(p_items) loop
  select * into p from charm.products where products.id=(item->>'product_id')::bigint;
  insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total)
  values(id,p.id,concat(p.category,' ',p.capacity,' ',p.fragrance),item->>'unit',(item->>'quantity')::integer,(item->>'unit_price')::numeric,(item->>'quantity')::integer*(item->>'unit_price')::numeric);
 end loop;
 perform charm.audit('submitted','orders',id); return charm.finish(p_key,id);
end $$;

create function charm.approve_order(p_id bigint,p_confirm boolean,p_reason text default null) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); o charm.orders;
begin
 if p_confirm is null then raise exception 'invalid'; end if;
 select * into o from charm.orders where id=p_id for update;
 if not found then raise exception 'notFound'; end if;
 if o.submitted_by=a or (o.submitted_by is null and o.salesperson_id=a) then raise exception 'selfApproval'; end if;
 if o.status<>'pending' then raise exception 'alreadyReviewed'; end if;
 if not p_confirm and coalesce(length(trim(p_reason)),0) not between 1 and 1000 then raise exception 'reasonRequired'; end if;
 update charm.orders set status=case when p_confirm then 'confirmed' else 'rejected' end,
 confirmed_at=case when p_confirm then now() end,confirmed_by=case when p_confirm then a end,reason=p_reason,updated_at=now() where id=p_id;
 perform charm.audit(case when p_confirm then 'confirmed' else 'rejected' end,'orders',p_id);
end $$;

create function charm.submit_payment(p_key uuid,p_order bigint,p_amount text,p_reference text,p_received timestamptz,p_notes text default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); o charm.orders; id bigint; old bigint; amount numeric:=charm.money(p_amount);
begin
 old:=charm.claim(p_key,'payment',jsonb_build_object('order',p_order,'amount',p_amount,'reference',p_reference,'received',p_received,'notes',p_notes)); if old is not null then return old; end if;
 select * into o from charm.orders where orders.id=p_order;
 if not found or not charm.can_access(o.salesperson_id) then raise exception 'forbidden'; end if;
 if o.status<>'confirmed' or p_received is null or p_received>now() or coalesce(length(trim(p_reference)),0) not between 1 and 200 or coalesce(length(p_notes),0)>10000 then raise exception 'invalid'; end if;
 insert into charm.payments(submission_key,order_id,submitted_by,amount,reference,received_at,follow_up_notes,status,created_at,updated_at)
 values(p_key,p_order,a,amount,p_reference,p_received,p_notes,'pending',now(),now()) returning payments.id into id;
 perform charm.audit('submitted','payments',id); return charm.finish(p_key,id);
end $$;

create function charm.review_payment(p_id bigint,p_verify boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); p charm.payments; o charm.orders; paid numeric;
begin
 if p_verify is null then raise exception 'invalid'; end if;
 select * into p from charm.payments where id=p_id;
 if not found then raise exception 'notFound'; end if;
 -- Always lock parent order first: serializes competing partial-payment approvals.
 select * into o from charm.orders where id=p.order_id for update;
 select * into p from charm.payments where id=p_id for update;
 if p.submitted_by=a then raise exception 'selfApproval'; end if;
 if p.status<>'pending' or o.status<>'confirmed' then raise exception 'alreadyReviewed'; end if;
 select coalesce(sum(amount),0) into paid from charm.payments where order_id=o.id and status='verified';
 if p_verify and paid+p.amount>o.total then raise exception 'overpayment'; end if;
 update charm.payments set status=case when p_verify then 'verified' else 'rejected' end,verified_by=a,verified_at=now(),updated_at=now() where id=p_id;
 perform charm.audit(case when p_verify then 'verified' else 'rejected' end,'payments',p_id);
end $$;

create view charm.order_balances with(security_invoker=true) as
 select o.id,o.client_id,o.salesperson_id,o.total,o.due_date,o.confirmed_at,
 coalesce(sum(p.amount) filter(where p.status='verified'),0) as paid,
 o.total-coalesce(sum(p.amount) filter(where p.status='verified'),0) as balance
 from charm.orders o left join charm.payments p on p.order_id=o.id where o.status='confirmed'
 group by o.id;
grant select on charm.order_balances to authenticated;

create function charm.monthly_summary(p_month date) returns jsonb language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); start_at timestamptz; end_at timestamptz; result jsonb;
begin
 start_at:=date_trunc('month',p_month::timestamp) at time zone 'Africa/Nairobi';
 end_at:=(date_trunc('month',p_month::timestamp)+interval '1 month') at time zone 'Africa/Nairobi';
 if p_month is null then raise exception 'invalid'; end if;
 select jsonb_build_object(
  'monthly_sales',coalesce((select sum(total)::text from charm.orders where status='confirmed' and confirmed_at>=start_at and confirmed_at<end_at and charm.can_access(salesperson_id)),'0.00'),
  'outstanding',coalesce((select sum(o.total-coalesce((select sum(p.amount) from charm.payments p where p.order_id=o.id and p.status='verified'),0))::text from charm.orders o where o.status='confirmed' and charm.can_access(o.salesperson_id)),'0.00'),
  'pending_orders',(select count(*) from charm.orders where status='pending' and charm.can_access(salesperson_id)),
  'clients',(select count(*) from charm.clients where charm.can_access(salesperson_id)),
  'team',coalesce((select jsonb_agg(t) from (select u.id,u.name,coalesce(sum(o.total),0)::text as sales from charm.users u left join charm.orders o on o.salesperson_id=u.id and o.status='confirmed' and o.confirmed_at>=start_at and o.confirmed_at<end_at where charm.can_access(u.id) group by u.id order by sum(o.total) desc nulls last) t),'[]'::jsonb)
 ) into result; return result;
end $$;

create function charm.save_client(p_key uuid,p_name text,p_contact text,p_phone text,p_location text,p_owner bigint) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); old bigint; id bigint;
begin
 if p_owner is null or (p_owner<>a and not charm.is_admin()) then raise exception 'forbidden'; end if;
 old:=charm.claim(p_key,'client',jsonb_build_array(p_name,p_contact,p_phone,p_location,p_owner)); if old is not null then return old; end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(trim(p_contact)),0) not between 1 and 200 or coalesce(length(trim(p_location)),0) not between 1 and 255 or coalesce(length(p_phone),0)>40 or not exists(select 1 from charm.users where users.id=p_owner and active) then raise exception 'invalid'; end if;
 insert into charm.clients(salesperson_id,name,contact,phone,location,created_at,updated_at) values(p_owner,p_name,p_contact,p_phone,p_location,now(),now()) returning clients.id into id;
 perform charm.audit('created','clients',id); return charm.finish(p_key,id);
end $$;
create function charm.assign_client(p_id bigint,p_owner bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 perform charm.require_admin();
 if not exists(select 1 from charm.users where id=p_owner and active) then raise exception 'invalid'; end if;
 update charm.clients set salesperson_id=p_owner,updated_at=now() where id=p_id;
 if not found then raise exception 'notFound'; end if;
 -- Existing orders retain their original salesperson attribution.
 perform charm.audit('assigned','clients',p_id,jsonb_build_object('owner',p_owner));
end $$;
create function charm.set_price(p_id bigint,p_price text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform charm.require_admin(); update charm.products set unit_price=charm.money(p_price),updated_at=now() where id=p_id;
 if not found then raise exception 'notFound'; end if;
 perform charm.audit('priced','products',p_id,jsonb_build_object('price',p_price));
end $$;
revoke execute on all functions in schema charm from public,anon,authenticated;
grant execute on function charm.actor(),charm.is_admin(),charm.can_access(bigint),charm.submit_order(uuid,bigint,date,jsonb),charm.approve_order(bigint,boolean,text),charm.submit_payment(uuid,bigint,text,text,timestamptz,text),charm.review_payment(bigint,boolean),charm.monthly_summary(date),charm.save_client(uuid,text,text,text,text,bigint),charm.assign_client(bigint,bigint),charm.set_price(bigint,text) to authenticated;
commit;

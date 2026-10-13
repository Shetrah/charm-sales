begin;
create function charm.require_sales_writer() returns bigint language plpgsql stable security definer set search_path='' as $$begin if charm.finance_role() not in ('admin','salesperson') then raise exception 'forbidden';end if;return charm.require_actor();end$$;
revoke execute on function charm.require_sales_writer() from public,anon,authenticated;
create or replace function charm.submit_order(p_key uuid,p_client bigint,p_due date,p_items jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); c charm.clients; p charm.products; item jsonb; total numeric:=0; id bigint; old bigint; qty integer; price numeric;
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
create or replace function charm.submit_payment(p_key uuid,p_order bigint,p_amount text,p_reference text,p_received timestamptz,p_notes text default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); o charm.orders; id bigint; old bigint; amount numeric:=charm.money(p_amount);
begin
 old:=charm.claim(p_key,'payment',jsonb_build_object('order',p_order,'amount',p_amount,'reference',p_reference,'received',p_received,'notes',p_notes)); if old is not null then return old; end if;
 select * into o from charm.orders where orders.id=p_order;
 if not found or not charm.can_access(o.salesperson_id) then raise exception 'forbidden'; end if;
 if o.status<>'confirmed' or p_received is null or p_received>now() or coalesce(length(trim(p_reference)),0) not between 1 and 200 or coalesce(length(p_notes),0)>10000 then raise exception 'invalid'; end if;
 insert into charm.payments(submission_key,order_id,submitted_by,amount,reference,received_at,follow_up_notes,status,created_at,updated_at)
 values(p_key,p_order,a,amount,p_reference,p_received,p_notes,'pending',now(),now()) returning payments.id into id;
 perform charm.audit('submitted','payments',id); return charm.finish(p_key,id);
end $$;
create or replace function charm.save_client(p_key uuid,p_name text,p_contact text,p_phone text,p_location text,p_owner bigint) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); old bigint; id bigint;
begin
 if p_owner is null or (p_owner<>a and not charm.is_admin()) then raise exception 'forbidden'; end if;
 old:=charm.claim(p_key,'client',jsonb_build_array(p_name,p_contact,p_phone,p_location,p_owner)); if old is not null then return old; end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(trim(p_contact)),0) not between 1 and 200 or coalesce(length(trim(p_location)),0) not between 1 and 255 or coalesce(length(p_phone),0)>40 or not exists(select 1 from charm.users where users.id=p_owner and active) then raise exception 'invalid'; end if;
 insert into charm.clients(salesperson_id,name,contact,phone,location,created_at,updated_at) values(p_owner,p_name,p_contact,p_phone,p_location,now(),now()) returning clients.id into id;
 perform charm.audit('created','clients',id); return charm.finish(p_key,id);
end $$;
create or replace function charm.submit_record(p_key uuid,p_kind text,p_date date,p_client bigint,p_budget text,p_notes text,p_follow_up date default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); old bigint; id bigint; budget numeric;
begin
 if p_kind not in ('plans','expenses','reports') or p_kind is null then raise exception 'invalid'; end if;
 old:=charm.claim(p_key,p_kind,jsonb_build_array(p_date,p_client,p_budget,p_notes,p_follow_up)); if old is not null then return old; end if;
 if p_date is null or coalesce(length(trim(p_notes)),0) not between 1 and 10000 then raise exception 'invalid'; end if;
 if p_kind in ('plans','expenses') and p_date<=(now() at time zone 'Africa/Nairobi')::date then raise exception 'advanceRequired'; end if;
 if p_client is not null and not exists(select 1 from charm.clients where clients.id=p_client and charm.can_access(salesperson_id)) then raise exception 'forbidden'; end if;
 if p_kind='expenses' and p_client is null then raise exception 'clientRequired'; end if;
 if p_follow_up is not null and p_follow_up<p_date then raise exception 'invalid'; end if;
 if p_budget is not null and p_budget<>'' then
  if p_budget !~ '^\d{1,8}(\.\d{1,2})?$' then raise exception 'invalidMoney'; end if;
  budget:=p_budget::numeric;
 end if;
 execute format('insert into charm.%I(submission_key,salesperson_id,date,client_id,budget,notes,status,created_at,updated_at) values($1,$2,$3,$4,$5,$6,''pending'',now(),now()) returning id',p_kind)
 into id using p_key,a,p_date,p_client,budget,p_notes;
 if p_kind='reports' then update charm.reports set follow_up_date=p_follow_up where reports.id=id; end if;
 perform charm.audit('submitted',p_kind,id); return charm.finish(p_key,id);
end $$;
create or replace function charm.submit_visit(p_key uuid,p_client bigint,p_lat numeric,p_lng numeric,p_accuracy numeric,p_outcome text,p_notes text,p_reason text,p_next text,p_follow_up date) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); id bigint; old bigint;
begin
 old:=charm.claim(p_key,'visit',jsonb_build_array(p_client,p_lat,p_lng,p_accuracy,p_outcome,p_notes,p_reason,p_next,p_follow_up)); if old is not null then return old; end if;
 if not exists(select 1 from charm.clients where clients.id=p_client and charm.can_access(salesperson_id)) then raise exception 'forbidden'; end if;
 if p_lat is null or p_lng is null or p_accuracy is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy not between 0 and 100000 then raise exception 'invalidLocation'; end if;
 if p_outcome is null or p_outcome not in ('order','follow-up','no-sale','payment-follow-up') or coalesce(length(trim(p_notes)),0) not between 1 and 10000 or coalesce(length(p_next),0)>1000 then raise exception 'invalid'; end if;
 if p_outcome='no-sale' and coalesce(length(trim(p_reason)),0) not between 1 and 1000 then raise exception 'reasonRequired'; end if;
 insert into charm.visits(submission_key,salesperson_id,client_id,check_in_at,latitude,longitude,accuracy_m,outcome,notes,unsuccessful_reason,next_action,follow_up_date,created_at,updated_at)
 values(p_key,a,p_client,now(),p_lat,p_lng,p_accuracy,p_outcome,p_notes,p_reason,p_next,p_follow_up,now(),now()) returning visits.id into id;
 perform charm.audit('checkedIn','visits',id); return charm.finish(p_key,id);
end $$;
create or replace function charm.checkout_visit(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); v charm.visits;
begin
 select * into v from charm.visits where id=p_id for update;
 if not found or v.salesperson_id<>a then raise exception 'forbidden'; end if;
 if v.check_out_at is null then update charm.visits set check_out_at=now(),updated_at=now() where id=p_id; perform charm.audit('checkedOut','visits',p_id); end if;
end $$;
create or replace function charm.start_workday() returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); id bigint; w charm.workdays;
begin
 perform 1 from charm.users where users.id=a for update;
 select * into w from charm.workdays where salesperson_id=a and (ended_at is null or date=(now() at time zone 'Africa/Nairobi')::date) order by id desc limit 1;
 if found then if w.ended_at is not null then raise exception 'alreadyReviewed'; end if; return w.id; end if;
 insert into charm.workdays(salesperson_id,date,started_at) values(a,(now() at time zone 'Africa/Nairobi')::date,now()) returning workdays.id into id;
 return id;
end $$;
create or replace function charm.end_workday(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 update charm.workdays set ended_at=coalesce(ended_at,now()) where id=p_id and salesperson_id=charm.require_sales_writer();
 if not found then raise exception 'forbidden'; end if;
end $$;
create or replace function charm.location_batch(p_workday bigint,p_points jsonb) returns integer language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); w charm.workdays; point jsonb; at timestamptz; key uuid; old bigint; id bigint; lat numeric; lng numeric; accuracy numeric;
begin
 select * into w from charm.workdays where workdays.id=p_workday for update;
 if not found or w.salesperson_id<>a then raise exception 'forbidden'; end if;
 if p_points is null or jsonb_typeof(p_points)<>'array' then raise exception 'invalid'; end if;
 if jsonb_array_length(p_points) not between 1 and 200 then raise exception 'invalid'; end if;
 for point in select value from jsonb_array_elements(p_points) loop
  key:=(point->>'submission_key')::uuid; at:=(point->>'recorded_at')::timestamptz;
  lat:=(point->>'latitude')::numeric; lng:=(point->>'longitude')::numeric; accuracy:=(point->>'accuracy_m')::numeric;
  if at is null or at<w.started_at or at>coalesce(w.ended_at,now()) or lat is null or lng is null or accuracy is null or lat not between -90 and 90 or lng not between -180 and 180 or accuracy not between 0 and 100000 then raise exception 'invalidLocation'; end if;
  old:=charm.claim(key,'location',jsonb_build_object('workday',p_workday,'point',point));
  if old is null then
   insert into charm.location_points(submission_key,workday_id,latitude,longitude,accuracy_m,recorded_at,received_at) values(key,p_workday,lat,lng,accuracy,at,now()) returning location_points.id into id;
   perform charm.finish(key,id);
  end if;
 end loop;
 return jsonb_array_length(p_points);
end $$;
create or replace function charm.set_client_location(p_id bigint,p_lat numeric,p_lng numeric,p_accuracy numeric) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); c charm.clients;
begin
 select * into c from charm.clients where id=p_id for update;
 if not found or not charm.can_access(c.salesperson_id) then raise exception 'forbidden'; end if;
 if p_lat is null or p_lng is null or p_accuracy is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy not between 0 and 100000 then raise exception 'invalidLocation'; end if;
 update charm.clients set latitude=p_lat,longitude=p_lng,location_accuracy_m=p_accuracy,location_captured_at=now(),updated_at=now() where id=p_id;
 perform charm.audit('locationUpdated','clients',p_id,jsonb_build_object('accuracy_m',p_accuracy));
end $$;
create policy finance_customer_proof_read on storage.objects for select to authenticated using(bucket_id='charm-private' and charm.finance_reader() and split_part(name,'/',1)='payments' and split_part(name,'/',2) ~ '^\d+$' and exists(select 1 from charm.payments where id=split_part(name,'/',2)::bigint));
create or replace function charm.file_access(path text,writing boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare kind text:=split_part(path,'/',1); record_id bigint; owner bigint; status text;
begin
 if writing and charm.finance_role() not in ('admin','salesperson') then return false;end if;
 if charm.actor() is null or split_part(path,'/',2) !~ '^\d+$' then return false; end if;
 record_id:=split_part(path,'/',2)::bigint;
 if kind='visits' then select salesperson_id into owner from charm.visits where visits.id=record_id;
 elsif kind='payments' then select o.salesperson_id,p.status into owner,status from charm.payments p join charm.orders o on o.id=p.order_id where p.id=record_id;
 else return false; end if;
 if writing and kind='payments' and status<>'pending' then return false; end if;
 return owner is not null and coalesce(charm.can_access(owner),false);
end $$;
create or replace function charm.review_record(p_kind text,p_id bigint,p_approve boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor(); r record;
begin
 perform charm.require_admin();
 if p_approve is null then raise exception 'invalid'; end if;
 if p_kind not in ('plans','expenses','reports') or p_kind is null then raise exception 'invalid'; end if;
 execute format('select * from charm.%I where id=$1 for update',p_kind) into r using p_id;
 if r.id is null then raise exception 'notFound'; end if;
 if r.salesperson_id=a then raise exception 'selfApproval'; end if;
 if r.status<>'pending' then raise exception 'alreadyReviewed'; end if;
 execute format('update charm.%I set status=$1,reviewed_by=$2,reviewed_at=now(),updated_at=now() where id=$3',p_kind) using case when p_approve then 'approved' else 'rejected' end,a,p_id;
 perform charm.audit(case when p_approve then 'approved' else 'rejected' end,p_kind,p_id);
end $$;
create or replace function charm.approve_order(p_id bigint,p_confirm boolean,p_reason text default null) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor(); o charm.orders;
begin
 perform charm.require_admin();
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
create or replace function charm.review_payment(p_id bigint,p_verify boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor(); p charm.payments; o charm.orders; paid numeric;
begin
 perform charm.require_admin();
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
notify pgrst,'reload schema';
commit;

-- Sales catalogue, pricing, availability, sampling, returns and credit controls.
begin;
alter table charm.products add column if not exists sku text;
alter table charm.products add column if not exists packaging_type text not null default 'bottle';
alter table charm.products add column if not exists formula_name text not null default '';
alter table charm.products add column if not exists volume_ml integer;
alter table charm.products add column if not exists sort_order integer not null default 0;
create function charm.sales_product_sku() returns trigger language plpgsql set search_path='' as $$begin if new.sku is null or trim(new.sku)='' then new.sku:='CHM-'||lpad(new.id::text,6,'0');end if;return new;end$$;
create trigger sales_product_sku before insert or update on charm.products for each row execute function charm.sales_product_sku();
alter table charm.clients add column if not exists customer_segment text not null default 'retail';
alter table charm.clients add column if not exists credit_limit numeric(14,2) not null default 0 check(credit_limit>=0);
update charm.products set sku=coalesce(nullif(sku,''),'CHM-'||lpad(id::text,6,'0')),volume_ml=case when capacity ~* '[0-9]+([.][0-9]+)?\s*l' then round((substring(capacity from '([0-9]+([.][0-9]+)?)'))::numeric*1000)::integer when capacity ~* '[0-9]+([.][0-9]+)?\s*ml' then round((substring(capacity from '([0-9]+([.][0-9]+)?)'))::numeric)::integer else volume_ml end where sku is null or volume_ml is null;
alter table charm.products alter column sku set not null;
create unique index if not exists products_sku_unique on charm.products(sku);
alter table charm.clients drop constraint if exists clients_customer_segment_check;
alter table charm.clients add constraint clients_customer_segment_check check(customer_segment in ('retail','distributor','key_account','institutional'));

create table charm.sales_price_rules(id bigserial primary key,product_id bigint not null references charm.products(id),client_id bigint references charm.clients(id),customer_segment text not null check(customer_segment in ('retail','distributor','key_account','institutional')),unit text not null check(unit in ('bottle','carton')),min_quantity integer not null default 1 check(min_quantity>0),unit_price numeric(14,2) not null check(unit_price>0),starts_on date,ends_on date,active boolean not null default true,created_by bigint not null references charm.users(id),created_at timestamptz not null default now(),check(ends_on is null or starts_on is null or ends_on>=starts_on));
create table charm.sales_promotions(id bigserial primary key,name text not null,product_id bigint references charm.products(id),customer_segment text check(customer_segment is null or customer_segment in ('retail','distributor','key_account','institutional')),buy_quantity integer not null check(buy_quantity>0),free_quantity integer not null check(free_quantity>0),unit text not null check(unit in ('bottle','carton')),starts_on date not null,ends_on date not null,active boolean not null default true,created_by bigint not null references charm.users(id),created_at timestamptz not null default now(),check(ends_on>=starts_on));
create table charm.sales_finished_stock(id bigserial primary key,product_id bigint not null references charm.products(id),lot_number text not null,quantity integer not null check(quantity<>0),expires_on date,reference text not null default '',created_by bigint not null references charm.users(id),created_at timestamptz not null default now());
create table charm.sales_batch_schedule(id bigserial primary key,product_id bigint not null references charm.products(id),production_batch_id bigint references charm.production_batches(id),scheduled_quantity integer not null check(scheduled_quantity>0),ready_on date not null,status text not null default 'scheduled' check(status in ('scheduled','ready','cancelled')),created_by bigint not null references charm.users(id),created_at timestamptz not null default now());
create table charm.sales_sample_requests(id bigserial primary key,client_id bigint not null references charm.clients(id),product_id bigint not null references charm.products(id),quantity integer not null check(quantity between 1 and 1000),requested_for text not null default '',status text not null default 'requested' check(status in ('requested','approved','sent','feedback_received','closed','rejected')),feedback text not null default '',requested_by bigint not null references charm.users(id),reviewed_by bigint references charm.users(id),sent_at timestamptz,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table charm.sales_returns(id bigserial primary key,client_id bigint not null references charm.clients(id),order_id bigint not null references charm.orders(id),order_item_id bigint not null references charm.order_items(id),production_batch_id bigint not null references charm.production_batches(id),batch_lot text not null,quantity integer not null check(quantity between 1 and 100000),reason text not null check(reason in ('damaged_packaging','leaking','quality_complaint','other')),notes text not null default '',status text not null default 'submitted' check(status in ('submitted','investigating','approved','rejected','credited')),credit_amount numeric(14,2),credit_note text,submitted_by bigint not null references charm.users(id),reviewed_by bigint references charm.users(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create index sales_schedule_ready on charm.sales_batch_schedule(product_id,ready_on) where status in ('scheduled','ready');
create index sales_stock_product on charm.sales_finished_stock(product_id,created_at);
create index sales_samples_owner on charm.sales_sample_requests(requested_by,status,created_at desc);
create index sales_returns_status on charm.sales_returns(status,created_at desc);

create function charm.sales_atp() returns table(product_id bigint,sku text,packaging_type text,finished_stock bigint,scheduled_stock bigint,available_quantity bigint,next_ready_on date) language sql stable security definer set search_path='' as $$
 select p.id,p.sku,p.packaging_type,coalesce(s.qty,0)::bigint,coalesce(b.qty,0)::bigint,greatest(coalesce(s.qty,0)+coalesce(b.qty,0)-coalesce(c.qty,0),0)::bigint,b.next_on
 from charm.products p left join lateral(select sum(quantity) qty from charm.sales_finished_stock x where x.product_id=p.id and (x.expires_on is null or x.expires_on>=(now() at time zone 'Africa/Nairobi')::date)) s on true
 left join lateral(select sum(scheduled_quantity) qty,min(ready_on) filter(where ready_on>=(now() at time zone 'Africa/Nairobi')::date) next_on from charm.sales_batch_schedule x where x.product_id=p.id and x.status in ('scheduled','ready') and ready_on>=(now() at time zone 'Africa/Nairobi')::date) b on true
 left join lateral(select sum(i.quantity*case when i.unit='carton' then p.carton else 1 end) qty from charm.order_items i join charm.orders o on o.id=i.order_id where i.product_id=p.id and o.status='confirmed') c on true
 where p.active and charm.actor() is not null
$$;
create function charm.sales_credit_status(p_client bigint) returns table(credit_limit numeric,used_credit numeric,available_credit numeric) language sql stable security definer set search_path='' as $$
 select c.credit_limit,coalesce(sum(o.total-coalesce(pay.paid,0)-coalesce(cr.amount,0)) filter(where o.status='confirmed'),0),c.credit_limit-coalesce(sum(o.total-coalesce(pay.paid,0)-coalesce(cr.amount,0)) filter(where o.status='confirmed'),0)
 from charm.clients c left join charm.orders o on o.client_id=c.id left join lateral(select sum(amount) paid from charm.payments where order_id=o.id and status='verified') pay on true left join lateral(select sum(credit_amount) amount from charm.sales_returns where order_id=o.id and status='credited') cr on true where c.id=p_client and charm.can_access(c.salesperson_id) group by c.credit_limit
$$;
alter table charm.orders add column if not exists confirmed_by bigint references charm.users(id);
create function charm.sales_credit_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare lim numeric;used numeric;begin
 if charm.finance_role() not in ('admin','salesperson') then raise exception 'forbidden';end if;
 if tg_op='UPDATE' and old.status='confirmed' then return new;end if;
 if new.status<>'confirmed' then return new;end if;
 perform 1 from charm.clients where id=new.client_id for update;
 select credit_limit into lim from charm.clients where id=new.client_id;
 select coalesce(sum(o.total-coalesce(paid.amount,0)-coalesce(credit.amount,0)),0) into used from charm.orders o left join lateral(select sum(amount) amount from charm.payments where order_id=o.id and status='verified') paid on true left join lateral(select sum(credit_amount) amount from charm.sales_returns where order_id=o.id and status='credited') credit on true where o.client_id=new.client_id and o.status='confirmed' and o.id<>new.id;
 if lim>0 and used+new.total>lim then raise exception 'creditLimitExceeded';end if;
 return new;
end $$;

create function charm.create_product_variant(p_sku text,p_category text,p_capacity text,p_fragrance text,p_barcode text,p_carton integer,p_unit_price numeric,p_packaging text,p_formula text,p_volume_ml integer) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin();pid bigint;begin
 if coalesce(length(trim(p_sku)),0) not between 1 and 80 or coalesce(length(trim(p_category)),0) not between 1 and 255 or coalesce(length(trim(p_capacity)),0) not between 1 and 80 or p_packaging not in ('bottle','jerrycan','drum','pouch','other') or p_carton not between 1 and 10000 or p_unit_price<0 or p_volume_ml<0 then raise exception 'invalid';end if;
 insert into charm.products(sku,category,capacity,fragrance,barcode,carton,unit_price,packaging_type,formula_name,volume_ml,active,needs_review,created_at,updated_at) values(trim(p_sku),trim(p_category),trim(p_capacity),coalesce(p_fragrance,''),coalesce(p_barcode,''),p_carton,p_unit_price,p_packaging,coalesce(p_formula,''),p_volume_ml,true,false,now(),now()) returning id into pid;
 perform charm.audit('created','products',pid,jsonb_build_object('sku',p_sku,'packaging_type',p_packaging,'volume_ml',p_volume_ml));return pid;
end $$;
create function charm.sales_update_client_terms(p_client bigint,p_segment text,p_limit numeric) returns void language plpgsql security definer set search_path='' as $$
begin
 perform charm.require_admin();if p_segment not in ('retail','distributor','key_account','institutional') or p_limit<0 then raise exception 'invalid';end if;
 update charm.clients set customer_segment=p_segment,credit_limit=p_limit,updated_at=now() where id=p_client;if not found then raise exception 'notFound';end if;
 perform charm.audit('salesTermsUpdated','clients',p_client,jsonb_build_object('segment',p_segment,'credit_limit',p_limit));
end $$;
create function charm.sales_ops_notify() returns trigger language plpgsql security definer set search_path='' as $$
declare rid bigint;who bigint;rec record;ev text;begin
 if tg_op='UPDATE' and coalesce(to_jsonb(old)->>'status','')=coalesce(to_jsonb(new)->>'status','') and coalesce(to_jsonb(old)->>'feedback','')=coalesce(to_jsonb(new)->>'feedback','') then return new;end if;
 rid:=new.id;who:=coalesce(nullif(to_jsonb(new)->>'requested_by','')::bigint,nullif(to_jsonb(new)->>'submitted_by','')::bigint);ev:=case when tg_table_name='sales_sample_requests' then 'sampleNeedsAttention' else 'returnNeedsAttention' end;
 for rec in select id from charm.users where active and id<>coalesce(charm.actor(),-1) and (role='admin' or id=who) loop
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) values(rec.id,null,ev,tg_table_name||':'||rid||':'||ev||':'||rec.id,tg_table_name,rid) on conflict do nothing;
 end loop;return new;
end $$;
create trigger sales_sample_notify after insert or update on charm.sales_sample_requests for each row execute function charm.sales_ops_notify();
create trigger sales_return_notify after insert or update on charm.sales_returns for each row execute function charm.sales_ops_notify();
create trigger sales_credit_check before insert or update of status on charm.orders for each row execute function charm.sales_credit_guard();

create function charm.sales_credit_note(p_id bigint,p_decision text,p_amount numeric default null,p_note text default '') returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin();r charm.sales_returns;begin
 select * into r from charm.sales_returns where id=p_id for update;
 if not found or r.status not in ('submitted','investigating') then raise exception 'alreadyReviewed';end if;
 if p_decision not in ('investigating','approved','rejected') then raise exception 'invalid';end if;
 if p_decision='approved' and (p_amount is null or p_amount<=0 or p_amount>r.quantity*(select unit_price from charm.order_items where id=r.order_item_id)) then raise exception 'invalidMoney';end if;
 update charm.sales_returns set status=case when p_decision='approved' then 'credited' else p_decision end,credit_amount=case when p_decision='approved' then p_amount end,credit_note=case when p_decision='approved' then coalesce(nullif(trim(p_note),''),'CN-'||id::text) end,reviewed_by=a,updated_at=now() where id=p_id;
 perform charm.audit(case when p_decision='approved' then 'creditNoteIssued' else p_decision end,'sales_returns',p_id,jsonb_build_object('order_id',r.order_id,'batch_lot',r.batch_lot,'amount',p_amount,'note',p_note));
end $$;

do $$ declare t text;begin
 foreach t in array array['sales_price_rules','sales_promotions','sales_finished_stock','sales_batch_schedule','sales_sample_requests','sales_returns'] loop
  execute format('alter table charm.%I enable row level security',t);
  execute format('revoke all on charm.%I from public,anon,authenticated',t);
  execute format('grant select on charm.%I to authenticated',t);
 end loop;
end $$;
create policy sales_price_read on charm.sales_price_rules for select to authenticated using(charm.is_admin() or client_id is null or exists(select 1 from charm.clients c where c.id=sales_price_rules.client_id and charm.can_access(c.salesperson_id)));
create policy sales_promos_read on charm.sales_promotions for select to authenticated using(charm.actor() is not null);
create policy sales_stock_read on charm.sales_finished_stock for select to authenticated using(charm.actor() is not null);
create policy sales_schedule_read on charm.sales_batch_schedule for select to authenticated using(charm.actor() is not null);
create policy sales_sample_read on charm.sales_sample_requests for select to authenticated using(charm.is_admin() or requested_by=charm.actor() or exists(select 1 from charm.clients c where c.id=sales_sample_requests.client_id and charm.can_access(c.salesperson_id)));
create policy sales_sample_write on charm.sales_sample_requests for insert to authenticated with check(requested_by=charm.actor() and exists(select 1 from charm.clients c where c.id=client_id and charm.can_access(c.salesperson_id)));
create policy sales_sample_admin_update on charm.sales_sample_requests for update to authenticated using(charm.is_admin()) with check(charm.is_admin());
create policy sales_return_read on charm.sales_returns for select to authenticated using(charm.is_admin() or submitted_by=charm.actor() or exists(select 1 from charm.clients c where c.id=sales_returns.client_id and charm.can_access(c.salesperson_id)));
create policy sales_return_write on charm.sales_returns for insert to authenticated with check(submitted_by=charm.actor() and exists(select 1 from charm.clients c where c.id=sales_returns.client_id and charm.can_access(c.salesperson_id)) and exists(select 1 from charm.orders o join charm.order_items i on i.order_id=o.id where o.id=sales_returns.order_id and i.id=sales_returns.order_item_id and o.client_id=sales_returns.client_id and o.status='confirmed') and exists(select 1 from charm.production_batches b where b.id=sales_returns.production_batch_id and b.lot_number=sales_returns.batch_lot and b.status='released'));
create policy sales_return_admin_update on charm.sales_returns for update to authenticated using(charm.is_admin()) with check(charm.is_admin());
grant insert,update,delete on charm.sales_price_rules,charm.sales_promotions,charm.sales_finished_stock,charm.sales_batch_schedule,charm.sales_sample_requests,charm.sales_returns to authenticated;
create policy sales_prices_admin on charm.sales_price_rules for all to authenticated using(charm.is_admin()) with check(charm.is_admin());
create policy sales_promos_admin on charm.sales_promotions for all to authenticated using(charm.is_admin()) with check(charm.is_admin());
create policy sales_stock_admin on charm.sales_finished_stock for all to authenticated using(charm.is_admin()) with check(charm.is_admin());
create policy sales_schedule_admin on charm.sales_batch_schedule for all to authenticated using(charm.is_admin()) with check(charm.is_admin());
grant usage,select on sequence charm.sales_price_rules_id_seq,charm.sales_promotions_id_seq,charm.sales_finished_stock_id_seq,charm.sales_batch_schedule_id_seq,charm.sales_sample_requests_id_seq,charm.sales_returns_id_seq to authenticated;
revoke execute on function charm.sales_atp(),charm.sales_credit_status(bigint),charm.sales_credit_guard(),charm.sales_credit_note(bigint,text,numeric,text),charm.sales_update_client_terms(bigint,text,numeric),charm.create_product_variant(text,text,text,text,text,integer,numeric,text,text,integer),charm.sales_ops_notify() from public,anon,authenticated;
grant execute on function charm.sales_atp(),charm.sales_credit_status(bigint),charm.sales_credit_note(bigint,text,numeric,text),charm.sales_update_client_terms(bigint,text,numeric),charm.create_product_variant(text,text,text,text,text,integer,numeric,text,text,integer) to authenticated;
commit;

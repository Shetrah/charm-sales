-- Charm React setup: review and apply to STAGING first, never an unapproved live cutover.
-- One-time bundle of the versioned migrations. Existing business rows/IDs are preserved.
-- Do not rerun this bundle if React migrations have already been partially applied;
-- inspect the database and apply only the missing versioned files instead.
-- Auth account mappings must be established separately after identity verification.

-- FILE: 202610120001_baseline.sql
-- Additive baseline. Existing charm tables and records are never replaced.
begin;
create schema if not exists charm;
create table if not exists charm.users (id bigserial primary key,name varchar(255) not null,email varchar(255) unique not null,password varchar(255) not null,role varchar(255) not null default 'salesperson' check(role in ('admin','salesperson')),active boolean not null default true,remember_token varchar(100),created_at timestamp,updated_at timestamp);
alter table charm.users enable row level security;
create table if not exists charm.products (id bigserial primary key,category varchar(255) not null,capacity varchar(255) not null,fragrance varchar(255) not null,barcode varchar(255) not null,carton integer not null,unit_price numeric(14,2),active boolean not null default true,needs_review boolean not null default false,created_at timestamp,updated_at timestamp);
alter table charm.products enable row level security;
create table if not exists charm.clients (id bigserial primary key,salesperson_id bigint not null references charm.users(id),name varchar(255) not null,contact varchar(255) not null,phone varchar(255),location varchar(255) not null,latitude numeric(10,7),longitude numeric(10,7),created_at timestamp,updated_at timestamp);
alter table charm.clients enable row level security;
create table if not exists charm.orders (id bigserial primary key,submission_key uuid not null unique,client_id bigint not null references charm.clients(id),salesperson_id bigint not null references charm.users(id),status varchar(255) not null default 'pending' check(status in ('pending','confirmed','rejected','cancelled')),total numeric(14,2) not null,confirmed_at timestamptz,due_date date,confirmed_by bigint references charm.users(id),reason text,created_at timestamptz,updated_at timestamptz);
alter table charm.orders enable row level security;
create table if not exists charm.order_items (id bigserial primary key,order_id bigint not null references charm.orders(id),product_id bigint not null references charm.products(id),product_description varchar(255) not null,unit varchar(255) not null check(unit in ('bottle','carton')),quantity integer not null,unit_price numeric(14,2) not null,line_total numeric(14,2) not null);
alter table charm.order_items enable row level security;
create table if not exists charm.payments (id bigserial primary key,submission_key uuid not null unique,order_id bigint not null references charm.orders(id),submitted_by bigint not null references charm.users(id),amount numeric(14,2) not null,reference varchar(255) not null,proof_path varchar(255),status varchar(255) not null default 'pending' check(status in ('pending','verified','rejected')),received_at timestamptz not null,verified_at timestamptz,verified_by bigint references charm.users(id),created_at timestamptz,updated_at timestamptz);
alter table charm.payments enable row level security;
create table if not exists charm.workdays (id bigserial primary key,salesperson_id bigint not null references charm.users(id),date date not null,started_at timestamptz not null,ended_at timestamptz,unique(salesperson_id,date));
alter table charm.workdays enable row level security;
create table if not exists charm.location_points (id bigserial primary key,submission_key uuid not null unique,workday_id bigint not null references charm.workdays(id),latitude numeric(10,7) not null,longitude numeric(10,7) not null,accuracy_m numeric(10,2) not null,recorded_at timestamptz not null,received_at timestamptz not null);
alter table charm.location_points enable row level security;
create table if not exists charm.visits (id bigserial primary key,submission_key uuid not null unique,salesperson_id bigint not null references charm.users(id),client_id bigint not null references charm.clients(id),check_in_at timestamptz not null,check_out_at timestamptz,latitude numeric(10,7) not null,longitude numeric(10,7) not null,accuracy_m numeric(10,2) not null,photo_path varchar(255),outcome varchar(255) not null,notes text not null,next_action text,follow_up_date date,created_at timestamptz,updated_at timestamptz);
alter table charm.visits enable row level security;
create table if not exists charm.audit_logs (id bigserial primary key,actor_id bigint not null references charm.users(id),action varchar(255) not null,entity varchar(255) not null,entity_id bigint not null,details jsonb not null,created_at timestamptz not null);
alter table charm.audit_logs enable row level security;
create table if not exists charm.plans (id bigserial primary key,submission_key uuid not null unique,salesperson_id bigint not null references charm.users(id),date date not null,client_id bigint references charm.clients(id),budget numeric(14,2),notes text not null,status varchar(255) not null default 'pending' check(status in ('pending','approved','rejected')),reviewed_by bigint references charm.users(id),reviewed_at timestamptz,created_at timestamptz,updated_at timestamptz);
alter table charm.plans enable row level security;
create table if not exists charm.expenses (id bigserial primary key,submission_key uuid not null unique,salesperson_id bigint not null references charm.users(id),date date not null,client_id bigint references charm.clients(id),budget numeric(14,2),notes text not null,status varchar(255) not null default 'pending' check(status in ('pending','approved','rejected')),reviewed_by bigint references charm.users(id),reviewed_at timestamptz,created_at timestamptz,updated_at timestamptz);
alter table charm.expenses enable row level security;
create table if not exists charm.reports (id bigserial primary key,submission_key uuid not null unique,salesperson_id bigint not null references charm.users(id),date date not null,client_id bigint references charm.clients(id),budget numeric(14,2),notes text not null,status varchar(255) not null default 'pending' check(status in ('pending','approved','rejected')),reviewed_by bigint references charm.users(id),reviewed_at timestamptz,created_at timestamptz,updated_at timestamptz,follow_up_date date);
alter table charm.reports enable row level security;
commit;

-- FILE: 202610120002_catalogue.sql
-- No quotation prices. Existing product rows and approved prices stay untouched.
begin;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (1,'Handwash','500ml','Ylang-Ylang','0721688311874',20,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (2,'Handwash','500ml','Azure Breeze','0724133585417',20,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (3,'Handwash','500ml','Peninsula Dew','0724133585424',20,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (4,'Handwash','500ml','Rose Scent','0724133585431',20,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (5,'Handwash','5L','Ylang-Ylang','0724133585615',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (6,'Handwash','5L','Azure Breeze','0724133585608',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (7,'Handwash','5L','Peninsula Dew','0724133585653',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (8,'Handwash','5L','Rose Scent','0724133585530',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (9,'Shampoo','200ml','Silent Aroma','0745760226535',36,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (10,'Shampoo','200ml','Amber Bomb','0745760226511',36,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (11,'Shampoo','200ml','Neon Dream','0745760226528',36,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (12,'Shampoo','750ml','Silent Aroma','0721688311850',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (13,'Shampoo','750ml','Amber Bomb','0724133585455',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (14,'Shampoo','750ml','Neon Dream','0724133585462',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (15,'Shampoo','5L','Silent Aroma','0724133585684',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (16,'Shampoo','5L','Amber Bomb','0724133585677',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (17,'Shampoo','5L','Neon Dream','0724133585622',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (18,'Shower Gel','200ml','Pheromone','0745760226559',36,true) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (19,'Shower Gel','200ml','Heartbeat Whisper','0745760226504',36,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (20,'Shower Gel','200ml','Milan Fogland','0745760226559',36,true) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (21,'Shower Gel','200ml','Silent Aroma','0745760226542',36,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (22,'Shower Gel','750ml','Pheromone','0721688311843',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (23,'Shower Gel','750ml','Heartbeat Whisper','0724133585479',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (24,'Shower Gel','751ml','Milan Fogland','0724133585554',12,true) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (25,'Shower Gel','750ml','Silent Aroma','0724133585486',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (26,'Shower Gel','5L','Pheromone','0724133585639',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (27,'Shower Gel','5L','Heartbeat Whisper','0724133585509',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (28,'Shower Gel','5L','Milan Fogland','0724133585646',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (29,'Shower Gel','5L','Silent Aroma','0724133585523',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (30,'Laundry Detergent','750ml','Fragrant Ylang-Ylang','0745760226573',24,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (31,'Laundry Detergent','750ml','Rose','0725765720740',24,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (32,'Laundry Detergent','1500ml','Fragrant Ylang-Ylang','0721688311829',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (33,'Laundry Detergent','1500ml','Rose','0724133585448',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (34,'Laundry Detergent','5L','Fragrant Ylang-Ylang','0724133585493',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (35,'Laundry Detergent','5L','Rose','0724133585516',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (36,'Dish Washing Liquid','500ml','Lemon','0745760226566',24,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (37,'Dish Washing Liquid','500ml','Ginger','0745760226580',24,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (38,'Dish Washing Liquid','1500ml','Lemon','0721688311836',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (39,'Dish Washing Liquid','1500ml','Ginger','0724133585400',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (40,'Dish Washing Liquid','5L','Lemon','0724133585592',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (41,'Dish Washing Liquid','5L','Ginger','0724133585660',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (42,'Windshield & Glass Cleaner','1600ml','Orange','0745760226597',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (43,'Windshield & Glass Cleaner','2000ml','Orange','0721688311867',6,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (44,'Windshield & Glass Cleaner','5L','Orange','0724133585585',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (45,'Automotive Interior Cleaner','950ml','Rome','0721688311812',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (46,'Automotive Interior Cleaner','5L','Rome','0724133585578',4,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (47,'Tire Shine','950ml','None','0721688311805',12,false) on conflict(id) do nothing;
insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values (48,'Tire Shine','5L','None','0724133585561',4,false) on conflict(id) do nothing;
select setval(pg_get_serial_sequence('charm.products','id'),greatest((select coalesce(max(id),1) from charm.products),1));
commit;

-- FILE: 202610120003_identity_and_rls.sql
begin;
-- Passwords and Laravel tokens remain private and are never imported into auth.users.
create table charm.auth_accounts (
 auth_user_id uuid primary key references auth.users(id),
 salesperson_id bigint unique not null references charm.users(id),
 linked_at timestamptz not null default now()
);
alter table charm.auth_accounts enable row level security;
alter table charm.orders add column if not exists submitted_by bigint references charm.users(id);
alter table charm.visits add column if not exists unsuccessful_reason text;
alter table charm.payments add column if not exists follow_up_notes text;
alter table charm.reports add column if not exists follow_up_date date;
create table charm.request_receipts (
 submission_key uuid primary key, actor_id bigint not null references charm.users(id),
 operation text not null, payload jsonb not null, result_id bigint
);
alter table charm.request_receipts enable row level security;

create function charm.actor() returns bigint language sql stable security definer set search_path='' as $$
 select u.id from charm.auth_accounts a join charm.users u on u.id=a.salesperson_id
 where a.auth_user_id=auth.uid() and u.active
$$;
create function charm.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select role='admin' from charm.users where id=charm.actor()),false)
$$;
create function charm.can_access(owner_id bigint) returns boolean language sql stable security definer set search_path='' as $$
 select charm.actor() is not null and (owner_id=charm.actor() or charm.is_admin())
$$;
create function charm.require_actor() returns bigint language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.actor(); begin if a is null then raise exception 'unauthorized'; end if; return a; end $$;
create function charm.require_admin() returns bigint language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); begin if not charm.is_admin() then raise exception 'forbidden'; end if; return a; end $$;
create function charm.audit(action text,entity text,entity_id bigint,details jsonb default '{}') returns void language sql security definer set search_path='' as $$
 insert into charm.audit_logs(actor_id,action,entity,entity_id,details,created_at) values(charm.require_actor(),action,entity,entity_id,details,now())
$$;
create function charm.claim(key uuid,op text,body jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); r charm.request_receipts; begin
 if key is null then raise exception 'invalid'; end if;
 perform pg_advisory_xact_lock(hashtextextended(key::text,0));
 select * into r from charm.request_receipts where submission_key=key;
 if found then
  if r.actor_id<>a or r.operation<>op or r.payload<>body then raise exception 'duplicateConflict'; end if;
  return r.result_id;
 end if;
 insert into charm.request_receipts values(key,a,op,body,null);
 return null;
end $$;
create function charm.finish(key uuid,id bigint) returns bigint language sql security definer set search_path='' as $$
 update charm.request_receipts set result_id=id where submission_key=key returning result_id
$$;

-- Explicit grants: no direct browser inserts, edits, deletes or sequence access.
revoke all on all tables in schema charm from anon,authenticated;
revoke all on all sequences in schema charm from anon,authenticated;
grant usage on schema charm to authenticated;
grant select(id,name,email,role,active) on charm.users to authenticated;
grant select on charm.auth_accounts,charm.products,charm.clients,charm.orders,charm.order_items,charm.payments,charm.visits,charm.plans,charm.expenses,charm.reports,charm.workdays,charm.location_points,charm.audit_logs to authenticated;
create policy account_self on charm.auth_accounts for select to authenticated using(auth_user_id=auth.uid() and salesperson_id=charm.actor());
create policy user_scope on charm.users for select to authenticated using(charm.can_access(id));
create policy catalogue on charm.products for select to authenticated using(charm.actor() is not null);
create policy client_scope on charm.clients for select to authenticated using(charm.can_access(salesperson_id));
create policy order_scope on charm.orders for select to authenticated using(charm.can_access(salesperson_id));
create policy item_scope on charm.order_items for select to authenticated using(exists(select 1 from charm.orders o where o.id=order_id and charm.can_access(o.salesperson_id)));
create policy payment_scope on charm.payments for select to authenticated using(exists(select 1 from charm.orders o where o.id=order_id and charm.can_access(o.salesperson_id)));
create policy visit_scope on charm.visits for select to authenticated using(charm.can_access(salesperson_id));
create policy plan_scope on charm.plans for select to authenticated using(charm.can_access(salesperson_id));
create policy expense_scope on charm.expenses for select to authenticated using(charm.can_access(salesperson_id));
create policy report_scope on charm.reports for select to authenticated using(charm.can_access(salesperson_id));
create policy workday_scope on charm.workdays for select to authenticated using(charm.can_access(salesperson_id));
create policy point_scope on charm.location_points for select to authenticated using(exists(select 1 from charm.workdays w where w.id=workday_id and charm.can_access(w.salesperson_id)));
create policy audit_admin on charm.audit_logs for select to authenticated using(charm.is_admin());

create index if not exists react_clients_owner on charm.clients(salesperson_id,id desc);
create index if not exists react_orders_owner_confirmed on charm.orders(salesperson_id,status,confirmed_at);
create index if not exists react_orders_client on charm.orders(client_id,status);
create index if not exists react_payments_balance on charm.payments(order_id,status);
create index if not exists react_items_order on charm.order_items(order_id);
create index if not exists react_points_route on charm.location_points(workday_id,recorded_at,id);
create index if not exists react_workdays_owner on charm.workdays(salesperson_id,date desc);
create index if not exists react_visits_owner on charm.visits(salesperson_id,id desc);
create index if not exists react_plans_owner on charm.plans(salesperson_id,id desc);
create index if not exists react_expenses_owner on charm.expenses(salesperson_id,id desc);
create index if not exists react_reports_owner on charm.reports(salesperson_id,id desc);
-- New functions are private unless explicitly granted in the API migration.
revoke execute on all functions in schema charm from public,anon,authenticated;
grant execute on function charm.actor(),charm.is_admin(),charm.can_access(bigint) to authenticated;
commit;

-- FILE: 202610120004_sales_api.sql
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

-- FILE: 202610120005_field_api.sql
begin;
create function charm.submit_record(p_key uuid,p_kind text,p_date date,p_client bigint,p_budget text,p_notes text,p_follow_up date default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); old bigint; id bigint; budget numeric;
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
create function charm.review_record(p_kind text,p_id bigint,p_approve boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); r record;
begin
 if p_approve is null then raise exception 'invalid'; end if;
 if p_kind not in ('plans','expenses','reports') or p_kind is null then raise exception 'invalid'; end if;
 execute format('select * from charm.%I where id=$1 for update',p_kind) into r using p_id;
 if r.id is null then raise exception 'notFound'; end if;
 if r.salesperson_id=a then raise exception 'selfApproval'; end if;
 if r.status<>'pending' then raise exception 'alreadyReviewed'; end if;
 execute format('update charm.%I set status=$1,reviewed_by=$2,reviewed_at=now(),updated_at=now() where id=$3',p_kind) using case when p_approve then 'approved' else 'rejected' end,a,p_id;
 perform charm.audit(case when p_approve then 'approved' else 'rejected' end,p_kind,p_id);
end $$;

create function charm.submit_visit(p_key uuid,p_client bigint,p_lat numeric,p_lng numeric,p_accuracy numeric,p_outcome text,p_notes text,p_reason text,p_next text,p_follow_up date) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); id bigint; old bigint;
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
create function charm.checkout_visit(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); v charm.visits;
begin
 select * into v from charm.visits where id=p_id for update;
 if not found or v.salesperson_id<>a then raise exception 'forbidden'; end if;
 if v.check_out_at is null then update charm.visits set check_out_at=now(),updated_at=now() where id=p_id; perform charm.audit('checkedOut','visits',p_id); end if;
end $$;
create function charm.start_workday() returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); id bigint; w charm.workdays;
begin
 perform 1 from charm.users where users.id=a for update;
 select * into w from charm.workdays where salesperson_id=a and (ended_at is null or date=(now() at time zone 'Africa/Nairobi')::date) order by id desc limit 1;
 if found then if w.ended_at is not null then raise exception 'alreadyReviewed'; end if; return w.id; end if;
 insert into charm.workdays(salesperson_id,date,started_at) values(a,(now() at time zone 'Africa/Nairobi')::date,now()) returning workdays.id into id;
 return id;
end $$;
create function charm.end_workday(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 update charm.workdays set ended_at=coalesce(ended_at,now()) where id=p_id and salesperson_id=charm.require_actor();
 if not found then raise exception 'forbidden'; end if;
end $$;
create function charm.location_batch(p_workday bigint,p_points jsonb) returns integer language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); w charm.workdays; point jsonb; at timestamptz; key uuid; old bigint; id bigint; lat numeric; lng numeric; accuracy numeric;
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
revoke execute on function charm.submit_record(uuid,text,date,bigint,text,text,date),charm.review_record(text,bigint,boolean),charm.submit_visit(uuid,bigint,numeric,numeric,numeric,text,text,text,text,date),charm.checkout_visit(bigint),charm.start_workday(),charm.end_workday(bigint),charm.location_batch(bigint,jsonb) from public,anon;
grant execute on function charm.submit_record(uuid,text,date,bigint,text,text,date),charm.review_record(text,bigint,boolean),charm.submit_visit(uuid,bigint,numeric,numeric,numeric,text,text,text,text,date),charm.checkout_visit(bigint),charm.start_workday(),charm.end_workday(bigint),charm.location_batch(bigint,jsonb) to authenticated;
commit;

-- FILE: 202610120006_private_storage.sql
begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('charm-private','charm-private',false,5242880,array['image/jpeg','image/png','image/webp'])
 on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
-- Preserve legacy paths: visits/{record_id}/{uuid}.png or payments/{record_id}/{uuid}.png.
create function charm.file_access(path text,writing boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare kind text:=split_part(path,'/',1); record_id bigint; owner bigint; status text;
begin
 if charm.actor() is null or split_part(path,'/',2) !~ '^\d+$' then return false; end if;
 record_id:=split_part(path,'/',2)::bigint;
 if kind='visits' then select salesperson_id into owner from charm.visits where visits.id=record_id;
 elsif kind='payments' then select o.salesperson_id,p.status into owner,status from charm.payments p join charm.orders o on o.id=p.order_id where p.id=record_id;
 else return false; end if;
 if writing and kind='payments' and status<>'pending' then return false; end if;
 return owner is not null and coalesce(charm.can_access(owner),false);
end $$;
create policy charm_files_read on storage.objects for select to authenticated using(bucket_id='charm-private' and charm.file_access(name));
create policy charm_files_insert on storage.objects for insert to authenticated with check(bucket_id='charm-private' and charm.file_access(name,true));
-- No overwrite or delete policy. Attachments become immutable evidence after verification.
create function charm.attach_file(p_kind text,p_id bigint,p_path text) returns void language plpgsql security definer set search_path='' as $$
declare p charm.payments;
begin
 perform charm.require_actor();
 if p_kind='payments' then
  select * into p from charm.payments where id=p_id for update;
  if p.status<>'pending' then raise exception 'alreadyReviewed'; end if;
 end if;
 if p_kind not in ('visits','payments') or p_kind is null or p_path not like p_kind||'/'||p_id||'/%' or not charm.file_access(p_path,true) or not exists(select 1 from storage.objects where bucket_id='charm-private' and name=p_path) then raise exception 'forbidden'; end if;
 if p_kind='visits' then update charm.visits set photo_path=p_path where id=p_id;
 else update charm.payments set proof_path=p_path where id=p_id; end if;
 perform charm.audit('attached',p_kind,p_id,jsonb_build_object('path',p_path));
end $$;
revoke execute on function charm.file_access(text,boolean),charm.attach_file(text,bigint,text) from public,anon;
grant execute on function charm.file_access(text,boolean),charm.attach_file(text,bigint,text) to authenticated;
commit;

-- FILE: 202610120007_staff_api.sql
begin;
-- This function is callable only by the Edge Function's service role.
-- It rechecks the requesting admin against trusted database identity.
create function charm.link_staff(p_actor uuid,p_auth uuid,p_email text,p_name text,p_role text) returns bigint language plpgsql security definer set search_path='' as $$
declare admin_id bigint; staff_id bigint; existing_auth uuid; canonical_email text;
begin
 select u.id into admin_id from charm.auth_accounts a join charm.users u on u.id=a.salesperson_id where a.auth_user_id=p_actor and u.active and u.role='admin';
 if admin_id is null or p_actor=p_auth then raise exception 'forbidden'; end if;
 select email into canonical_email from auth.users where id=p_auth;
 if canonical_email is null or lower(canonical_email)<>lower(trim(p_email)) or p_role not in ('admin','salesperson') or coalesce(length(trim(p_name)),0) not between 1 and 200 then raise exception 'invalid'; end if;
 perform pg_advisory_xact_lock(hashtextextended(lower(trim(p_email)),1));
 if (select count(*) from charm.users where lower(email)=lower(trim(p_email)))>1 then raise exception 'duplicateConflict'; end if;
 select id into staff_id from charm.users where lower(email)=lower(trim(p_email)) for update;
 if staff_id=admin_id then raise exception 'forbidden'; end if;
 if staff_id is null then
  -- Unusable legacy password; Supabase reset/invite establishes the real credential.
  insert into charm.users(name,email,password,role,active,created_at,updated_at) values(p_name,lower(trim(p_email)),'!supabase-auth-only!',p_role,true,now(),now()) returning id into staff_id;
 end if;
 select auth_user_id into existing_auth from charm.auth_accounts where salesperson_id=staff_id;
 if existing_auth is not null and existing_auth<>p_auth then raise exception 'duplicateConflict'; end if;
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values(p_auth,staff_id) on conflict(auth_user_id) do nothing;
 if not exists(select 1 from charm.auth_accounts where auth_user_id=p_auth and salesperson_id=staff_id) then raise exception 'duplicateConflict'; end if;
 insert into charm.audit_logs(actor_id,action,entity,entity_id,details,created_at) values(admin_id,'invited','users',staff_id,jsonb_build_object('auth_user_id',p_auth),now());
 return staff_id;
end $$;
revoke execute on function charm.link_staff(uuid,uuid,text,text,text) from public,anon,authenticated;
grant usage on schema charm to service_role;
grant execute on function charm.link_staff(uuid,uuid,text,text,text) to service_role;
commit;

-- Refresh the Data API after all functions and policies are installed.
NOTIFY pgrst, 'reload schema';

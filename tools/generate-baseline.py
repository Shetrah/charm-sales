"""Generate reviewable SQL from the inspected Laravel schema and supplied catalogue."""
import json
from pathlib import Path

tables = {
 'users': "id bigserial primary key,name varchar(255) not null,email varchar(255) unique not null,password varchar(255) not null,role varchar(255) not null default 'salesperson' check(role in ('admin','salesperson')),active boolean not null default true,remember_token varchar(100),created_at timestamp,updated_at timestamp",
 'products': "id bigserial primary key,category varchar(255) not null,capacity varchar(255) not null,fragrance varchar(255) not null,barcode varchar(255) not null,carton integer not null,unit_price numeric(14,2),active boolean not null default true,needs_review boolean not null default false,created_at timestamp,updated_at timestamp",
 'clients': "id bigserial primary key,salesperson_id bigint not null references charm.users(id),name varchar(255) not null,contact varchar(255) not null,phone varchar(255),location varchar(255) not null,latitude numeric(10,7),longitude numeric(10,7),created_at timestamp,updated_at timestamp",
 'orders': "id bigserial primary key,submission_key uuid not null unique,client_id bigint not null references charm.clients(id),salesperson_id bigint not null references charm.users(id),status varchar(255) not null default 'pending' check(status in ('pending','confirmed','rejected','cancelled')),total numeric(14,2) not null,confirmed_at timestamptz,due_date date,confirmed_by bigint references charm.users(id),reason text,created_at timestamptz,updated_at timestamptz",
 'order_items': "id bigserial primary key,order_id bigint not null references charm.orders(id),product_id bigint not null references charm.products(id),product_description varchar(255) not null,unit varchar(255) not null check(unit in ('bottle','carton')),quantity integer not null,unit_price numeric(14,2) not null,line_total numeric(14,2) not null",
 'payments': "id bigserial primary key,submission_key uuid not null unique,order_id bigint not null references charm.orders(id),submitted_by bigint not null references charm.users(id),amount numeric(14,2) not null,reference varchar(255) not null,proof_path varchar(255),status varchar(255) not null default 'pending' check(status in ('pending','verified','rejected')),received_at timestamptz not null,verified_at timestamptz,verified_by bigint references charm.users(id),created_at timestamptz,updated_at timestamptz",
 'workdays': "id bigserial primary key,salesperson_id bigint not null references charm.users(id),date date not null,started_at timestamptz not null,ended_at timestamptz,unique(salesperson_id,date)",
 'location_points': "id bigserial primary key,submission_key uuid not null unique,workday_id bigint not null references charm.workdays(id),latitude numeric(10,7) not null,longitude numeric(10,7) not null,accuracy_m numeric(10,2) not null,recorded_at timestamptz not null,received_at timestamptz not null",
 'visits': "id bigserial primary key,submission_key uuid not null unique,salesperson_id bigint not null references charm.users(id),client_id bigint not null references charm.clients(id),check_in_at timestamptz not null,check_out_at timestamptz,latitude numeric(10,7) not null,longitude numeric(10,7) not null,accuracy_m numeric(10,2) not null,photo_path varchar(255),outcome varchar(255) not null,notes text not null,next_action text,follow_up_date date,created_at timestamptz,updated_at timestamptz",
 'audit_logs': "id bigserial primary key,actor_id bigint not null references charm.users(id),action varchar(255) not null,entity varchar(255) not null,entity_id bigint not null,details jsonb not null,created_at timestamptz not null",
}
for name in ['plans','expenses','reports']:
 tables[name] = "id bigserial primary key,submission_key uuid not null unique,salesperson_id bigint not null references charm.users(id),date date not null,client_id bigint references charm.clients(id),budget numeric(14,2),notes text not null,status varchar(255) not null default 'pending' check(status in ('pending','approved','rejected')),reviewed_by bigint references charm.users(id),reviewed_at timestamptz,created_at timestamptz,updated_at timestamptz" + (",follow_up_date date" if name=='reports' else '')
sql = ['-- Additive baseline. Existing charm tables and records are never replaced.', 'begin;', 'create schema if not exists charm;']
for name, columns in tables.items():
 sql += [f'create table if not exists charm.{name} ({columns});',f'alter table charm.{name} enable row level security;']
sql += ['commit;']
Path('supabase/migrations/202610120001_baseline.sql').write_text('\n'.join(sql)+'\n')
sql=['-- No quotation prices. Existing product rows and approved prices stay untouched.', 'begin;']
for p in json.loads(Path('products.json').read_text()):
 vals=[str(p['id'])]+["'"+p[k].replace("'","''")+"'" for k in ['category','capacity','fragrance','barcode']]+[str(p['carton']),str(p['id'] in [18,20,24]).lower()]
 sql += [f"insert into charm.products(id,category,capacity,fragrance,barcode,carton,needs_review) values ({','.join(vals)}) on conflict(id) do nothing;"]
sql += ["select setval(pg_get_serial_sequence('charm.products','id'),greatest((select coalesce(max(id),1) from charm.products),1));",'commit;']
Path('supabase/migrations/202610120002_catalogue.sql').write_text('\n'.join(sql)+'\n')

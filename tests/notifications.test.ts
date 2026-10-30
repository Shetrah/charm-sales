import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';

const db = new PGlite();
const admin = '00000000-0000-4000-8000-000000000001';
const a = '00000000-0000-4000-8000-000000000002';
const b = '00000000-0000-4000-8000-000000000003';
const financeUser = '00000000-0000-4000-8000-000000000004';
let keyCount = 900;
const key = () => `90000000-0000-4000-8000-${String(keyCount++).padStart(12, '0')}`;

async function scalar(sql: string, params: unknown[] = []): Promise<any> {
 const result = await db.query(sql, params);
 return Object.values(result.rows[0] ?? {})[0];
}
async function asSystem(actor: string = admin) {
 await db.exec('reset role');
 await db.query("select set_config('request.jwt.claim.sub',$1,false)", [actor]);
}
async function notifyCount() {
 return Number(await scalar('select count(*)::int from charm.finance_notifications'));
}
async function recipients(entity: string, event: string) {
 const rows = await db.query('select distinct recipient_id from charm.finance_notifications where entity=$1 and event=$2', [entity, event]);
 return rows.rows.map((row: any) => Number(row.recipient_id)).sort((left, right) => left - right);
}

beforeAll(async () => {
 await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
 create schema auth; create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth to authenticated,anon; grant execute on function auth.uid() to authenticated,anon;
 create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text,unique(bucket_id,name));alter table storage.objects enable row level security;
 grant usage on schema storage to authenticated,anon;grant select,insert,update,delete on storage.objects to authenticated,anon;`);
 await db.exec("insert into storage.buckets(id,name,public) values('charm-private','charm-private',false)");
 for (const file of readdirSync('supabase/migrations').sort()) await db.exec(readFileSync(`supabase/migrations/${file}`, 'utf8'));
 await db.exec(`insert into auth.users values('${admin}','admin@test.invalid'),('${a}','a@test.invalid'),('${b}','b@test.invalid'),('${financeUser}','finance@test.invalid');
 insert into charm.users(id,name,email,password,role) values
  (1,'Admin','admin@test.invalid','legacy','admin'),
  (2,'Sales A','a@test.invalid','legacy','salesperson'),
  (3,'Sales B','b@test.invalid','legacy','salesperson'),
  (4,'Finance Officer','finance@test.invalid','legacy','finance_officer');
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values('${admin}',1),('${a}',2),('${b}',3),('${financeUser}',4);
 insert into charm.clients(id,salesperson_id,name,contact,phone,location,customer_segment,credit_limit) values
  (1,2,'Nairobi client','Jane Supplier','0711000111','Thika Road, Nairobi','distributor',500000),
  (2,3,'Mombasa client','Ali Retail','0722000222','Nyali, Mombasa','retail',100000);
 insert into charm.products(id,sku,category,capacity,fragrance,barcode,carton,unit_price,active) values
  (9301,'NTF-LIQ-5L','Liquid Soap','5L','Lemon','NTF-111',12,100,true);
 select setval(pg_get_serial_sequence('charm.products','id'),9301);
 select setval(pg_get_serial_sequence('charm.clients','id'),2);
 select setval(pg_get_serial_sequence('charm.users','id'),4);`);
 await asSystem(a);
}, 120000);

afterAll(() => db.close());

describe.sequential('Notification routing', () => {
 it('sends a new order only to the approver', async () => {
  const before = await notifyCount();
  await asSystem(a);
  await db.exec(`insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at)
   values('90000000-0000-4000-8000-000000000101',1,2,2,300,current_date+7,'pending',now(),now())`);
  await db.exec(`insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total)
   values(1,9301,'Liquid Soap 5L','bottle',3,100,300)`);
  expect(await notifyCount()).toBe(before + 1);
  expect(await recipients('orders', 'orders_submitted')).toEqual([1]);
 });

 it('informs the owner and finance when an order is confirmed, without copying other salespeople', async () => {
  await asSystem(admin);
  await db.exec("update charm.orders set status='confirmed',confirmed_at=now(),confirmed_by=1 where id=1");
  expect(await recipients('orders', 'confirmed')).toEqual([2, 4]);
  await db.exec("update charm.finance_sales_invoices set batch_lot='LOT-READY' where order_id=1");
 });

 it('routes a pending payment to admin and finance only', async () => {
  const before = await notifyCount();
  await asSystem(a);
  await db.exec(`insert into charm.payments(submission_key,order_id,submitted_by,amount,reference,received_at,follow_up_notes,status,created_at,updated_at)
   values('90000000-0000-4000-8000-000000000102',1,2,100,'M-PESA-NTF-1',now(),'Cash on delivery','pending',now(),now())`);
  expect(await notifyCount()).toBe(before + 2);
  expect(await recipients('payments', 'payments_submitted')).toEqual([1, 4]);
 });

 it('keeps field visits and daily reports with the person who logged them', async () => {
  const before = await notifyCount();
  await asSystem(a);
  await db.exec(`insert into charm.visits(submission_key,salesperson_id,client_id,check_in_at,latitude,longitude,accuracy_m,outcome,notes,created_at,updated_at)
   values('90000000-0000-4000-8000-000000000103',2,1,now(),-1.286389,36.817223,12,'follow-up','Discussed the next replenishment',now(),now())`);
  await db.exec(`insert into charm.reports(submission_key,salesperson_id,date,client_id,notes,status,created_at,updated_at)
   values('90000000-0000-4000-8000-000000000104',2,current_date,1,'Two stops completed','pending',now(),now())`);
  expect(await notifyCount()).toBe(before);
  expect(await recipients('visits', 'visits_submitted')).toEqual([]);
  expect(await recipients('reports', 'reports_submitted')).toEqual([]);
 });

 it('tells only the salespeople still waiting for a production lot when a batch is released', async () => {
  await asSystem(b);
  await db.exec(`insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at)
   values('90000000-0000-4000-8000-000000000105',2,3,3,400,current_date+7,'pending',now(),now())`);
  await db.exec(`insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total)
   values(2,9301,'Liquid Soap 5L','carton',2,200,400)`);
  await asSystem(admin);
  await db.exec("update charm.orders set status='confirmed',confirmed_at=now(),confirmed_by=1 where id=2");
  await db.exec("update charm.finance_sales_invoices set batch_lot='LOT-HELD' where order_id=2");
  await db.exec(`insert into charm.production_formulas(id,product_name,version,yield_liters,status,created_by,created_at)
   values(7001,'Liquid Soap','v1.0',1000,'approved',1,now())`);
  await db.exec(`insert into charm.production_batches(id,formula_id,target_liters,status,started_by,started_at)
   values(8001,7001,1000,'mixing',4,now())`);
  await db.exec("select setval(pg_get_serial_sequence('charm.production_formulas','id'),7001)");
  await db.exec("select setval(pg_get_serial_sequence('charm.production_batches','id'),8001)");
  await asSystem(a);
  await db.exec(`insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at)
   values('90000000-0000-4000-8000-000000000106',1,2,2,200,current_date+7,'pending',now(),now())`);
  await db.exec(`insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total)
   values(3,9301,'Liquid Soap 5L','bottle',2,100,200)`);
  await asSystem(admin);
  await db.exec("update charm.orders set status='confirmed',confirmed_at=now(),confirmed_by=1 where id=3");
  expect(await recipients('production_batches', 'production_batches_submitted')).toEqual([4]);
  await db.exec("update charm.production_batches set status='qc_hold',actual_liters=980,completed_at=now() where id=8001");
  await db.exec(`insert into charm.production_quality_checks(batch_id,result,tested_by,tested_at) values(8001,'passed',4,now())`);
  await db.exec("update charm.production_batches set status='released' where id=8001");
  expect(await recipients('production_batches', 'released')).toEqual([2, 4]);
 });
});

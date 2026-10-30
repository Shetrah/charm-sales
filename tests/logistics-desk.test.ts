import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';

const db = new PGlite();
const admin = '00000000-0000-4000-8000-000000000001';
const a = '00000000-0000-4000-8000-000000000002';
const b = '00000000-0000-4000-8000-000000000003';
const desk = '00000000-0000-4000-8000-000000000005';
let keyCount = 700;
const key = () => `70000000-0000-4000-8000-${String(keyCount++).padStart(12, '0')}`;

async function scalar(sql: string, params: unknown[] = []): Promise<any> {
 const result = await db.query(sql, params);
 return Object.values(result.rows[0] ?? {})[0];
}
async function rows(sql: string, params: unknown[] = []): Promise<any[]> {
 return (await db.query(sql, params)).rows;
}
async function asUser(id: string) {
 await db.exec('reset role');
 await db.query("select set_config('request.jwt.claim.sub',$1,false)", [id]);
 await db.exec('set role authenticated');
}
async function asSystem(actor: string = admin) {
 await db.exec('reset role');
 await db.query("select set_config('request.jwt.claim.sub',$1,false)", [actor]);
}
async function today(offset = 0) {
 return String(await scalar("select to_char((now() at time zone 'Africa/Nairobi')::date+$1::int,'YYYY-MM-DD')", [offset]));
}
async function auditCount(action: string, entity: string, entityId: number, restore: string = desk) {
 await asSystem(admin);
 const count = Number(await scalar('select count(*)::int from charm.audit_logs where action=$1 and entity=$2 and entity_id=$3', [action, entity, entityId]));
 await asUser(restore);
 return count;
}
async function intake() {
 return rows('select * from charm.logistics_order_intake()');
}
async function recipients(event: string, entity: string, entityId?: number, restore: string = desk) {
 await asSystem(admin);
 const found = entityId === undefined
  ? await rows('select distinct recipient_id from charm.finance_notifications where entity=$1 and event=$2', [entity, event])
  : await rows('select distinct recipient_id from charm.finance_notifications where entity=$1 and event=$2 and entity_id=$3', [entity, event, entityId]);
 await asUser(restore);
 return found.map((row: any) => Number(row.recipient_id)).sort((left, right) => left - right);
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
 await db.exec(`insert into auth.users values('${admin}','admin@test.invalid'),('${a}','a@test.invalid'),('${b}','b@test.invalid'),('${desk}','desk@test.invalid');
 insert into charm.users(id,name,email,password,role) values
  (1,'Admin','admin@test.invalid','legacy','admin'),
  (2,'Sales A','a@test.invalid','legacy','salesperson'),
  (3,'Sales B','b@test.invalid','legacy','salesperson'),
  (4,'Finance Officer','finance@test.invalid','legacy','finance_officer'),
  (5,'Logistics Desk','desk@test.invalid','legacy','logistics_manager'),
  (6,'Storekeeper','store@test.invalid','legacy','salesperson');
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values('${admin}',1),('${a}',2),('${b}',3),('${desk}',5);
 insert into charm.clients(id,salesperson_id,name,contact,location) values(1,2,'Nairobi client','Contact','Nairobi'),(2,3,'Mombasa client','Contact','Mombasa');
 insert into charm.products(id,sku,category,capacity,fragrance,barcode,carton,unit_price,active) values
  (9101,'DSK-SOAP-5L','Liquid Soap','5L','Lemon','DSK-111',12,100,true),
  (9102,'DSK-BLEACH-1L','Bleach','1L','Plain','DSK-222',6,50,true);
 select setval(pg_get_serial_sequence('charm.products','id'),9102);
 select setval(pg_get_serial_sequence('charm.clients','id'),2);
 select setval(pg_get_serial_sequence('charm.users','id'),6);`);
 await asSystem(a);
 await db.exec(`insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at) values
   ('70000000-0000-4000-8000-000000000001',1,2,2,1100,current_date+7,'pending',now(),now()),
   ('70000000-0000-4000-8000-000000000002',2,3,3,300,current_date+9,'pending',now(),now()),
   ('70000000-0000-4000-8000-000000000003',1,2,2,10000,current_date+14,'pending',now(),now());
 insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total) values
  (1,9101,'Liquid Soap 5L','bottle',2,100,200),
  (1,9101,'Liquid Soap 5L','carton',1,900,900),
  (2,9102,'Bleach 1L','carton',1,300,300),
  (3,9101,'Liquid Soap 5L','bottle',100,100,10000);
 insert into charm.sales_finished_stock(product_id,lot_number,quantity,reference,created_by) values(9101,'LOT-DESK',20,'opening stock',2);
 update charm.orders set status='confirmed',confirmed_at=now(),confirmed_by=1 where id in (1,2,3);`);
 await asUser(desk);
}, 90000);

afterAll(() => db.close());

describe.sequential('Logistics fulfilment desk', () => {
 it('assigns the fulfilment role through the staff editor and rejects unknown roles', async () => {
  await asSystem(admin);
  await db.query('select charm.update_staff(6,$1,$2,$3,$4,$5)', ['Storekeeper', '0700123456', 'Athi River', 'logistics_manager', true]);
  expect(await scalar('select role from charm.users where id=6')).toBe('logistics_manager');
  await expect(db.query("select charm.update_staff(6,'Storekeeper','','','courier',true)")).rejects.toThrow('invalid');
  await asUser(desk);
  await expect(db.query("select charm.update_staff(6,'Storekeeper','','','logistics_manager',true)")).rejects.toThrow('forbidden');
  await asSystem(admin);
  await db.exec("update charm.users set role='salesperson' where id=6");
  await asUser(desk);
 });

 it('opens the order book, clients, colleagues and deliveries to the desk only', async () => {
  expect(await scalar('select count(*)::int from charm.orders')).toBe(3);
  expect(await scalar('select count(*)::int from charm.order_items')).toBe(4);
  expect(await scalar('select count(*)::int from charm.clients')).toBe(2);
  expect(await scalar('select count(*)::int from charm.users')).toBeGreaterThanOrEqual(6);
  await asUser(b);
  expect(await scalar('select count(*)::int from charm.orders')).toBe(1);
  expect(await scalar('select count(*)::int from charm.clients')).toBe(1);
  expect(await scalar('select count(*)::int from charm.users')).toBe(1);
  await asUser(desk);
 });

 it('checks stock per order line and never lets two orders spend the same bottles', async () => {
  const queue = await intake();
  expect(queue.map((row: any) => Number(row.order_id))).toEqual([1, 2, 3]);
  expect(queue[0].covered).toBe(true);
  expect(queue[0].short_items).toEqual([]);
  expect(queue[1].covered).toBe(false);
  expect(queue[1].short_items).toEqual([{ product_id: 9102, product: 'Bleach · 1L', needed: 6, short: 6 }]);
  expect(queue[2].covered).toBe(false);
  expect(queue[2].short_items).toEqual([{ product_id: 9101, product: 'Liquid Soap · 5L', needed: 100, short: 94 }]);
  expect(queue[2].client_name).toBe('Nairobi client');
  expect(queue[2].salesperson_name).toBe('Sales A');
  await asUser(b);
  expect(await scalar('select count(*)::int from charm.logistics_order_intake()')).toBe(0);
  await asUser(desk);
 });

 it('refuses production work that the store already covers or that the desk does not own', async () => {
  await expect(db.query('select charm.logistics_arrange_production($1,$2,$3)', [key(), 1, await today(7)])).rejects.toThrow('stockAvailable');
  await expect(db.query('select charm.logistics_arrange_production($1,$2,$3)', [key(), 3, await today(-1)])).rejects.toThrow('invalid');
  await expect(db.query('select charm.logistics_arrange_production($1,$2,$3)', [key(), 3, await today(400)])).rejects.toThrow('invalid');
  await asUser(b);
  await expect(db.query('select charm.logistics_arrange_production($1,$2,$3)', [key(), 2, await today(7)])).rejects.toThrow('forbidden');
  await asUser(desk);
 });

 it('schedules exactly the shortfall, flags the order as under production and tells only the owner and admins', async () => {
  const submission = key();
  const ready = await today(7);
  expect(await scalar('select charm.logistics_arrange_production($1,$2,$3)', [submission, 3, ready])).toBe(1);
  const batch = await rows('select product_id,scheduled_quantity,to_char(ready_on,$2) as ready_on,status from charm.sales_batch_schedule where ready_on=$1::date', [ready, 'YYYY-MM-DD']);
  expect(batch).toEqual([{ product_id: 9101, scheduled_quantity: 94, ready_on: ready, status: 'scheduled' }]);
  expect(await scalar('select production_required from charm.orders where id=3')).toBe(true);
  expect(String(await scalar("select to_char(production_ready_on,'YYYY-MM-DD') from charm.orders where id=3"))).toBe(ready);
  expect(await recipients('productionArranged', 'orders')).toEqual([1, 2]);
  expect(await scalar('select charm.logistics_arrange_production($1,$2,$3)', [submission, 3, ready])).toBe(1);
  await expect(db.query('select charm.logistics_arrange_production($1,$2,$3)', [submission, 2, ready])).rejects.toThrow('duplicateConflict');
  const queue = await intake();
  expect(queue.find((row: any) => Number(row.order_id) === 3)?.covered).toBe(true);
  expect(await auditCount('productionArranged', 'orders', 3)).toBe(1);
 });

 it('plans a delivery for another salesperson’s order and clears the production flag', async () => {
  const forBleach = Number(await scalar('select charm.sales_create_delivery($1,$2,$3,$4,$5,$6,$7)', [key(), 2, await today(), 'Driver Desk', '0700000000', 'KDG 100A', 'Mombasa run']));
  expect(forBleach).toBeGreaterThan(0);
  expect(await scalar('select salesperson_id from charm.sales_deliveries where id=$1', [forBleach])).toBe(3);
  expect(await scalar('select count(*)::int from charm.sales_delivery_items where delivery_id=$1', [forBleach])).toBe(1);
  const forBulk = Number(await scalar('select charm.sales_create_delivery($1,$2,$3,$4,$5,$6,$7)', [key(), 3, await today(), 'Driver Bulk', '', '', '']));
  expect(await scalar('select production_required from charm.orders where id=3')).toBe(false);
  expect(await scalar('select status from charm.sales_deliveries where id=$1', [forBulk])).toBe('planned');
  expect(await recipients('deliveryPlanned', 'sales_deliveries')).toEqual([1, 2, 3]);
  await expect(db.query('select charm.logistics_arrange_production($1,$2,$3)', [key(), 3, await today(7)])).rejects.toThrow('deliveryInProgress');
  expect((await intake()).map((row: any) => Number(row.order_id))).toEqual([1]);
 });

 it('will not queue production while a delivery is already on the road', async () => {
  await asSystem(admin);
  await db.exec('update charm.clients set credit_limit=1000000 where id=1');
  const resupplied = Number(await scalar("insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at) values('70000000-0000-4000-8000-000000000004',1,2,2,6000,current_date+21,'pending',now(),now()) returning id"));
  await db.exec(`insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total) values(${resupplied},9101,'Liquid Soap 5L','bottle',60,100,6000)`);
  await db.exec(`update charm.orders set status='confirmed',confirmed_at=now(),confirmed_by=1,production_required=true,production_ready_on=current_date+7 where id=${resupplied}`);
  await asUser(desk);
  expect((await intake()).find((row: any) => Number(row.order_id) === resupplied)?.short_items)
   .toEqual([{ product_id: 9101, product: 'Liquid Soap · 5L', needed: 60, short: 60 }]);
  const planned = Number(await scalar('select charm.sales_create_delivery($1,$2,$3,$4,$5,$6,$7)', [key(), resupplied, await today(), 'Blocked Driver', '', '', '']));
  await expect(db.query('select charm.logistics_arrange_production($1,$2,$3)', [key(), resupplied, await today(7)])).rejects.toThrow('deliveryInProgress');
  expect(await scalar('select production_required from charm.orders where id=$1', [resupplied])).toBe(false);
  expect(planned).toBeGreaterThan(0);
 });

 it('serves documents and the ledger to the desk across the whole order book', async () => {
  const document = await scalar('select charm.sales_order_documents(2)');
  expect(document.client.name).toBe('Mombasa client');
  expect(document.delivery.status).toBe('planned');
  expect(((await scalar('select charm.sales_inventory_ledger(60)')).rows as unknown[]).length).toBeGreaterThan(0);
  await asUser(b);
  await expect(db.query('select charm.sales_order_documents(1)')).rejects.toThrow('notFound');
  await asUser(desk);
 });

 it('stores identity photos only for the person or an administrator and demands a real upload', async () => {
  await asSystem(a);
  await db.exec("insert into storage.objects(bucket_id,name) values('charm-private','staff/2/face.jpg')");
  await asUser(a);
  await db.exec("select charm.save_staff_photo(2,'staff/2/face.jpg')");
  expect(await scalar('select photo_path from charm.users where id=2')).toBe('staff/2/face.jpg');
  await expect(db.query("select charm.save_staff_photo(5,'staff/5/someone-else.jpg')")).rejects.toThrow('forbidden');
  await expect(db.query("select charm.save_staff_photo(2,'staff/2/notes.pdf')")).rejects.toThrow('mediaUploadRequired');
  await expect(db.query("select charm.save_staff_photo(2,'staff/2/ghost.jpg')")).rejects.toThrow('mediaUploadRequired');
  await asSystem(admin);
  await db.exec("insert into storage.objects(bucket_id,name) values('charm-private','staff/3/portrait.png')");
  await asUser(admin);
  await db.exec("select charm.save_staff_photo(3,'staff/3/portrait.png')");
  expect(await rows('select id,photo_path from charm.team_directory where id in (2,3) order by id'))
   .toEqual([{ id: 2, photo_path: 'staff/2/face.jpg' }, { id: 3, photo_path: 'staff/3/portrait.png' }]);
  expect(String(await scalar("select charm.staff_profile(2,current_date)->'person'->>'photo_path'"))).toBe('staff/2/face.jpg');
  await expect(db.query("select charm.save_staff_photo(2,'staff/3/portrait.png')")).rejects.toThrow('mediaUploadRequired');
  await asUser(a);
  await db.exec("select charm.save_staff_photo(2,'')");
  expect(await scalar('select photo_path from charm.users where id=2')).toBeNull();
  expect(await auditCount('photoRemoved', 'users', 2, a)).toBe(1);
  await asUser(desk);
 });

 it('keeps product imagery writable by the desk and readable in the catalogue', async () => {
  await asUser(a);
  await expect(db.query("select charm.save_product_image(9101,'products/9101/any.jpg')")).rejects.toThrow('forbidden');
  await asUser(desk);
  await expect(db.query("select charm.save_product_image(9101,'products/9101/hero.jpg')")).rejects.toThrow('mediaUploadRequired');
  await asSystem(desk);
  await db.exec("insert into storage.objects(bucket_id,name) values('charm-private','products/9101/hero.jpg'),('charm-private','products/9102/bleach.png')");
  await asUser(desk);
  await db.exec("select charm.save_product_image(9101,'products/9101/hero.jpg')");
  expect(await scalar('select image_path from charm.products where id=9101')).toBe('products/9101/hero.jpg');
  await expect(db.query("select charm.save_product_image(9102,'products/9101/hero.jpg')")).rejects.toThrow('mediaUploadRequired');
  await asUser(admin);
  await db.exec("select charm.save_product_image(9102,'products/9102/bleach.png')");
  await asUser(a);
  expect(await scalar('select image_path from charm.products where id=9102')).toBe('products/9102/bleach.png');
  await asUser(desk);
  await db.exec("select charm.save_product_image(9101,'')");
  expect(await scalar('select image_path from charm.products where id=9101')).toBeNull();
  expect(await auditCount('imageAttached', 'products', 9102)).toBe(1);
 });

 it('routes a newly confirmed order to the desk, its owner and finance but not to other salespeople', async () => {
  await asSystem(b);
  await db.exec(`insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at)
   values('70000000-0000-4000-8000-000000000005',2,3,3,100,current_date+7,'pending',now(),now())`);
  await db.exec(`insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total)
   values(5,9102,'Bleach 1L','bottle',2,50,100)`);
  await asSystem(admin);
  await db.exec("update charm.orders set status='confirmed',confirmed_at=now(),confirmed_by=1 where id=5");
  expect(await recipients('confirmed', 'orders', 5)).toEqual([3, 4, 5]);
  await asUser(desk);
 });
});

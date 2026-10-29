import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';

const db = new PGlite();
const admin = '00000000-0000-4000-8000-000000000001';
const a = '00000000-0000-4000-8000-000000000002';
const b = '00000000-0000-4000-8000-000000000003';
let keyCount = 500;
const key = () => `50000000-0000-4000-8000-${String(keyCount++).padStart(12, '0')}`;

async function scalar(sql: string, params: unknown[] = []): Promise<any> {
 const result = await db.query(sql, params);
 return Object.values(result.rows[0] ?? {})[0];
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
async function asStranger() {
 await db.exec('reset role');
 await db.query("select set_config('request.jwt.claim.sub','',false)");
 await db.exec('set role authenticated');
}
async function today() {
 return String(await scalar("select to_char(now() at time zone 'Africa/Nairobi','YYYY-MM-DD')"));
}
async function createDelivery(order: number, scheduled: string, actor = a, driver = 'Driver One') {
 return scalar('select charm.sales_create_delivery($1,$2,$3,$4,$5,$6,$7)', [key(), order, scheduled, driver, '0700000000', 'KDA 001A', 'Deliver before noon']);
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
 await db.exec(`insert into auth.users values('${admin}','admin@test.invalid'),('${a}','a@test.invalid'),('${b}','b@test.invalid');
 insert into charm.users(id,name,email,password,role) values
  (1,'Admin','admin@test.invalid','legacy','admin'),
  (2,'Sales A','a@test.invalid','legacy','salesperson'),
  (3,'Sales B','b@test.invalid','legacy','salesperson'),
  (4,'Finance Officer','finance@test.invalid','legacy','finance_officer');
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values('${admin}',1),('${a}',2),('${b}',3);
 insert into charm.clients(id,salesperson_id,name,contact,location) values(1,2,'Nairobi client','Contact','Nairobi'),(2,3,'Mombasa client','Contact','Mombasa');
 insert into charm.products(id,category,capacity,fragrance,barcode,carton,unit_price,active) values
  (9001,'Liquid Soap','5L','Lavender','LOG-111',12,100,true),(9002,'Bleach','1L','Plain','LOG-222',6,50,true);
 select setval(pg_get_serial_sequence('charm.products','id'),9002);
 select setval(pg_get_serial_sequence('charm.clients','id'),2);
 select setval(pg_get_serial_sequence('charm.users','id'),4);`);
 await asSystem(a);
 await db.exec(`insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at)
  values('60000000-0000-4000-8000-000000000001',1,2,2,1100,current_date+7,'pending',now(),now()),
        ('60000000-0000-4000-8000-000000000002',2,3,3,500,current_date+7,'pending',now(),now());
 insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total) values
  (1,9001,'Liquid Soap 5L','bottle',2,100,200),
  (1,9001,'Liquid Soap 5L','carton',1,900,900),
  (2,9002,'Bleach 1L','bottle',2,50,100);
 insert into charm.sales_finished_stock(product_id,lot_number,quantity,reference,created_by) values(9001,'LOT-1',100,'opening stock',2);
 update charm.orders set status='confirmed',confirmed_at=now(),confirmed_by=1 where id=1;`);
 await asUser(a);
}, 60000);

afterAll(() => db.close());

describe.sequential('Order logistics and delivery notes', () => {
 it('plans a delivery for a confirmed order with a Kenyan delivery number and item snapshot', async () => {
  const id = Number(await createDelivery(1, await today()));
  expect(id).toBeGreaterThan(0);
  const row = await scalar('select delivery_number from charm.sales_deliveries where id=$1', [id]);
  expect(row).toMatch(/^DN-\d{8}-\d{5}$/);
  expect(await scalar('select status from charm.sales_deliveries where id=$1', [id])).toBe('planned');
  expect(await scalar('select count(*)::int from charm.sales_delivery_items where delivery_id=$1', [id])).toBe(2);
  expect(await scalar('select sum(quantity)::int from charm.sales_delivery_items where delivery_id=$1 and unit=\'bottle\'', [id])).toBe(2);
 });

 it('rejects pending orders, foreign clients and duplicate deliveries', async () => {
  await expect(createDelivery(2, await today())).rejects.toThrow('confirmedOrderRequired');
  await asUser(b);
  await expect(createDelivery(1, await today())).rejects.toThrow('forbidden');
  await asUser(a);
  await expect(createDelivery(1, await today())).rejects.toThrow('deliveryExists');
 });

 it('is idempotent for the same submission key and rejects a changed payload', async () => {
  await asSystem(a);
  const order = Number(await scalar("insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at) values('60000000-0000-4000-8000-000000000003',1,2,2,300,current_date+7,'pending',now(),now()) returning id"));
  await db.exec(`insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total) values(${order},9002,'Bleach 1L','bottle',3,100,300)`);
  await db.exec(`update charm.orders set status='confirmed',confirmed_at=now(),confirmed_by=1 where id=${order}`);
  await asUser(a);
  const submission = key();
  const first = await scalar('select charm.sales_create_delivery($1,$2,$3,$4,$5,$6,$7)', [submission, order, await today(), 'Driver Two', '', '', '']);
  const second = await scalar('select charm.sales_create_delivery($1,$2,$3,$4,$5,$6,$7)', [submission, order, await today(), 'Driver Two', '', '', '']);
  expect(second).toBe(first);
  await expect(scalar('select charm.sales_create_delivery($1,$2,$3,$4,$5,$6,$7)', [submission, order, await today(), 'Someone Else', '', '', ''])).rejects.toThrow('duplicateConflict');
  await scalar('select charm.sales_update_delivery($1,$2,$3)', [first, 'failed', 'Vehicle breakdown']);
 });

 it('enforces status transitions and a failure reason, then reschedules failed deliveries', async () => {
  const id = Number(await scalar('select id from charm.sales_deliveries where order_id=1'));
  await expect(scalar('select charm.sales_update_delivery($1,$2,$3)', [id, 'delivered', ''])).rejects.toThrow('invalidTransition');
  await expect(scalar('select charm.sales_update_delivery($1,$2,$3)', [id, 'failed', 'no'])).rejects.toThrow('reasonRequired');
  await scalar('select charm.sales_update_delivery($1,$2,$3)', [id, 'dispatched', '']);
  expect(await scalar('select dispatched_at is not null from charm.sales_deliveries where id=$1', [id])).toBe(true);
  await expect(scalar('select charm.sales_update_delivery($1,$2,$3)', [id, 'dispatched', ''])).rejects.toThrow('invalidTransition');

  const failed = Number(await scalar("select id from charm.sales_deliveries where status='failed'"));
  expect(failed).toBeGreaterThan(0);
  expect(await scalar('select failure_reason from charm.sales_deliveries where id=$1', [failed])).toBe('Vehicle breakdown');
  const rescheduled = Number(await scalar('select charm.sales_create_delivery($1,$2,$3,$4,$5,$6,$7)', [key(), await scalar('select order_id from charm.sales_deliveries where id=$1', [failed]), await today(), 'Driver Three', '0711111111', 'KDB 222B', 'Second attempt']));
  expect(rescheduled).toBe(failed);
  expect(await scalar('select status from charm.sales_deliveries where id=$1', [failed])).toBe('planned');
  expect(await scalar('select count(*)::int from charm.sales_deliveries where order_id=(select order_id from charm.sales_deliveries where id=$1)', [failed])).toBe(1);
 });

 it('moves finished goods out of available-to-promise only when delivered', async () => {
  const before = await db.query("select finished_stock::int,available_quantity::int from charm.sales_atp() where product_id=9001");
  expect(Number(before.rows[0].finished_stock)).toBe(100);
  expect(Number(before.rows[0].available_quantity)).toBe(86);
  const id = Number(await scalar('select id from charm.sales_deliveries where order_id=1'));
  await asUser(a);
  await scalar('select charm.sales_update_delivery($1,$2,$3)', [id, 'delivered', '']);
  expect(await scalar('select delivered_at is not null from charm.sales_deliveries where id=$1', [id])).toBe(true);
  await expect(scalar('select charm.sales_update_delivery($1,$2,$3)', [id, 'failed', 'late'])).rejects.toThrow('alreadyClosed');
  const after = await db.query("select finished_stock::int,available_quantity::int from charm.sales_atp() where product_id=9001");
  expect(Number(after.rows[0].finished_stock)).toBe(86);
  expect(Number(after.rows[0].available_quantity)).toBe(86);
 });

 it('serves the delivery note, invoice and credit notes to the owning salesperson only', async () => {
  const document = await scalar("select charm.sales_order_documents(1)");
  expect(document.client.name).toBe('Nairobi client');
  expect(document.items).toHaveLength(2);
  expect(document.invoice.invoice_number).toMatch(/^CHM-INV-/);
  expect(Number(document.invoice.total)).toBe(1100);
  expect(document.delivery.delivery_number).toMatch(/^DN-/);
  expect(document.delivery.status).toBe('delivered');
  expect(document.delivery.items).toHaveLength(2);
  expect(document.credit_notes).toEqual([]);
  await asUser(b);
  await expect(scalar('select charm.sales_order_documents(1)')).rejects.toThrow('notFound');
 });

 it('lists receipts and delivered dispatches in the inventory ledger with owner scoping', async () => {
  await asUser(a);
  const own = await scalar('select charm.sales_inventory_ledger(60)');
  const kinds = own.rows.map((row: any) => row.kind);
  expect(kinds).toContain('receipt');
  expect(kinds).toContain('dispatch');
  const dispatch = own.rows.find((row: any) => row.kind === 'dispatch');
  expect(dispatch.quantity).toBe(-14);
  expect(dispatch.detail).toBe('Nairobi client');
  await asUser(b);
  const foreign = await scalar('select charm.sales_inventory_ledger(60)');
  expect(foreign.rows.some((row: any) => row.kind === 'dispatch')).toBe(false);
 });

 it('hides delivery records from unrelated salespeople and keeps them visible to admins', async () => {
  await asUser(b);
  expect(await scalar('select count(*)::int from charm.sales_deliveries')).toBe(0);
  expect(await scalar('select count(*)::int from charm.sales_delivery_items')).toBe(0);
  await asUser(admin);
  expect(await scalar('select count(*)::int from charm.sales_deliveries')).toBeGreaterThan(0);
 });

 it('records delivery notifications and audit entries for each transition', async () => {
  await asUser(admin);
  expect(await scalar("select count(*)::int from charm.finance_notifications where entity='sales_deliveries' and recipient_id=1 and event='deliveryPlanned'")).toBeGreaterThan(0);
  expect(await scalar("select count(*)::int from charm.finance_notifications where entity='sales_deliveries' and recipient_id=1 and event='deliveryDelivered'")).toBeGreaterThan(0);
  expect(await scalar("select count(*)::int from charm.audit_logs where entity='sales_deliveries' and action='deliveryDelivered'")).toBeGreaterThan(0);
  await asStranger();
  expect(await scalar('select count(*)::int from charm.sales_deliveries')).toBe(0);
 });
});

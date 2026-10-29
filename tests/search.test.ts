import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';

const db = new PGlite();
const admin = '00000000-0000-4000-8000-000000000001';
const a = '00000000-0000-4000-8000-000000000002';
const b = '00000000-0000-4000-8000-000000000003';

async function scalar(sql: string, params: unknown[] = []): Promise<any> {
 const result = await db.query(sql, params);
 return Object.values(result.rows[0] ?? {})[0];
}
async function asUser(id: string) {
 await db.exec('reset role');
 await db.query("select set_config('request.jwt.claim.sub',$1,false)", [id]);
 await db.exec('set role authenticated');
}
async function asStranger() {
 await db.exec('reset role');
 await db.query("select set_config('request.jwt.claim.sub','',false)");
 await db.exec('set role authenticated');
}
const search = (query: string) => scalar('select charm.search_centre($1)', [query]);

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
  (3,'Sales B','b@test.invalid','legacy','salesperson');
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values('${admin}',1),('${a}',2),('${b}',3);
 insert into charm.clients(id,salesperson_id,name,contact,location) values(1,2,'Nairobi client','Amina','Nairobi'),(2,3,'Mombasa client','Bilal','Mombasa');
 insert into charm.clients(id,salesperson_id,name,contact,location) values(3,2,'Naivasha depot','Cathy','Naivasha');
 insert into charm.products(id,category,capacity,fragrance,barcode,carton,unit_price,active) values
  (9101,'Liquid Soap','5L','Lavender','BAR-999',12,100,true),(9102,'Bleach','1L','Plain','BAR-000',6,50,false);
 select setval(pg_get_serial_sequence('charm.products','id'),9102);
 select setval(pg_get_serial_sequence('charm.clients','id'),3);
 select setval(pg_get_serial_sequence('charm.users','id'),3);`);
 await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)", [a]);
 await db.exec(`insert into charm.orders(id,submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,contract_reference,created_at,updated_at)
  values(1,'70000000-0000-4000-8000-000000000001',1,2,2,1100,current_date+7,'pending','CT-SEARCH-1',now(),now()),
        (2,'70000000-0000-4000-8000-000000000002',2,3,3,500,current_date+7,'pending','CT-SEARCH-2',now(),now());
 insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total) values(1,9101,'Liquid Soap 5L','bottle',2,100,200);
 update charm.orders set status='confirmed',confirmed_at=now(),confirmed_by=1 where id=1;
 select setval(pg_get_serial_sequence('charm.orders','id'),2);`);
 await asUser(a);
 await scalar('select charm.sales_create_delivery($1,$2,$3,$4,$5,$6,$7)', ['70000000-0000-4000-8000-000000000010', 1, String(await scalar("select to_char(now() at time zone 'Africa/Nairobi','YYYY-MM-DD')")), 'Amina Driver', '0700000000', 'KDA 9', '']);
}, 60000);

afterAll(() => db.close());

describe.sequential('Role-scoped search centre', () => {
 it('requires a signed-in actor and at least two characters', async () => {
  await asStranger();
  await expect(search('nairobi')).rejects.toThrow('unauthorized');
  await asUser(a);
  await expect(search('n')).rejects.toThrow('invalid');
 });
 it('returns grouped clients, orders and deliveries for an administrator', async () => {
  await asUser(admin);
  const result = await search('nairobi');
  expect(result.clients.map((row: any) => row.name)).toContain('Nairobi client');
  expect(result.orders.map((row: any) => row.id)).toContain(1);
  expect(result.deliveries.map((row: any) => row.id)).toHaveLength(1);
  expect(result.deliveries[0].client).toBe('Nairobi client');
 });
 it('finds a delivery by its generated number', async () => {
  await asUser(a);
  const prefix = await scalar('select left(delivery_number,8) from charm.sales_deliveries limit 1');
  const result = await search(prefix);
  expect(result.deliveries).toHaveLength(1);
  expect(result.deliveries[0].delivery_number).toMatch(/^DN-\d{8}-\d{5}$/);
 });
 it('finds an order by contract reference within the owner scope', async () => {
  await asUser(b);
  expect((await search('ct-search-2')).orders.map((row: any) => row.id)).toEqual([2]);
  await asUser(a);
  expect((await search('ct-search-2')).orders).toHaveLength(0);
 });
 it('does not expose another salesperson client or order', async () => {
  await asUser(a);
  const result = await search('mombasa');
  expect(result.clients).toHaveLength(0);
  expect(result.orders).toHaveLength(0);
  expect(result.deliveries).toHaveLength(0);
 });
 it('searches active products by barcode and hides inactive catalogue lines', async () => {
  await asUser(a);
  const active = await search('bar-999');
  expect(active.products.map((row: any) => row.id)).toEqual([9101]);
  expect((await search('bar-000')).products).toHaveLength(0);
  expect((await search('bleach')).products).toHaveLength(0);
 });
 it('matches client details by contact and location', async () => {
  await asUser(a);
  const result = await search('cathy');
  expect(result.clients.map((row: any) => row.name)).toEqual(['Naivasha depot']);
  expect((await search('naivasha')).clients.map((row: any) => row.id)).toEqual([3]);
 });
});

import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';

const db = new PGlite();
const admin = '00000000-0000-4000-8000-000000000001';
const a = '00000000-0000-4000-8000-000000000002';
const b = '00000000-0000-4000-8000-000000000003';
const financeUser = '00000000-0000-4000-8000-000000000004';
let keyCount = 700;
const key = () => `70000000-0000-4000-8000-${String(keyCount++).padStart(12, '0')}`;

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
async function saveProfile(actor: string, values: Record<string, string>) {
 await asUser(actor);
 const order = ['legal_name','trading_name','address_line1','address_line2','city','country','phone','email','website','tax_id','bank_name','bank_account_name','bank_account_number','bank_branch','mobile_money_name','mobile_paybill','mobile_account','delivery_terms','invoice_terms','footer_note'];
 const params = order.map(name => values[name] ?? '');
 return scalar(`select charm.company_profile_save(${order.map((_, index) => `$${index + 1}`).join(',')})`, params);
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
 update charm.users set phone='+254700111222',staff_code='CHM-SP-001' where id=2;
 insert into charm.clients(id,salesperson_id,name,contact,phone,location,customer_segment,credit_limit) values
  (1,2,'Nairobi client','Jane Supplier','0711000111','Thika Road, Nairobi','distributor',500000),
  (2,3,'Mombasa client','Ali Retail','0722000222','Nyali, Mombasa','retail',100000);
 insert into charm.products(id,sku,category,capacity,fragrance,barcode,carton,unit_price,active) values
  (9101,'CHQ-LIQ-5L','Liquid Soap','5L','Lavender','DOC-111',12,100,true),
  (9102,'CHQ-BLE-1L','Bleach','1L','Plain','DOC-222',6,50,true);
 select setval(pg_get_serial_sequence('charm.products','id'),9102);
 select setval(pg_get_serial_sequence('charm.clients','id'),2);
 select setval(pg_get_serial_sequence('charm.users','id'),4);
 update charm.finance_invoice_settings set tax_rate=0.16,credit_terms_days=30 where id=true;
 insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,created_at,updated_at)
  values('80000000-0000-4000-8000-000000000001',1,2,2,1100,current_date+7,'pending',now(),now()),
        ('80000000-0000-4000-8000-000000000002',2,3,3,100,current_date+7,'pending',now(),now());
 insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total) values
  (1,9101,'Liquid Soap 5L','bottle',2,100,200),
  (1,9101,'Liquid Soap 5L','carton',1,900,900),
  (2,9102,'Bleach 1L','bottle',2,50,100);
 insert into charm.sales_finished_stock(product_id,lot_number,quantity,reference,created_by) values(9101,'LOT-DOC-1',200,'opening stock',2);`);
 await asSystem(admin);
 await db.exec(`update charm.orders set contract_reference='CHM/CT/2026/014',contract_signed_by='Jane Supplier',status='confirmed',confirmed_at=now(),confirmed_by=1 where id=1;
 insert into charm.payments(submission_key,order_id,submitted_by,amount,reference,received_at,follow_up_notes,status,verified_at,verified_by,created_at,updated_at)
  values('80000000-0000-4000-8000-000000000011',1,2,500,'M-PESA-DOC-1',now()-interval '1 day','Bank transfer received','verified',now(),1,now(),now()),
        ('80000000-0000-4000-8000-000000000012',1,2,200,'M-PESA-DOC-2',now(),'Awaiting verification','pending',null,null,now(),now());`);
 await asUser(a);
 await scalar('select charm.sales_create_delivery($1,$2,$3,$4,$5,$6,$7)', [key(), 1, await today(), 'Driver One', '0700000000', 'KDA 001A', 'Deliver before noon']);
}, 120000);

afterAll(() => db.close());

describe.sequential('Company letterhead and commercial documents', () => {
 it('seeds a single letterhead row that every signed-in staff member can read', async () => {
  expect(await scalar('select count(*)::int from charm.company_profile')).toBe(1);
  await asUser(a);
  const profile = await db.query('select legal_name,city,country,footer_note from charm.company_profile where id=true');
  expect(profile.rows[0].legal_name).toBe('CHARM KENYA');
  expect(profile.rows[0].city).toBe('Nairobi');
  expect(profile.rows[0].country).toBe('Kenya');
  expect(String(profile.rows[0].footer_note)).toContain('Thank you');
  await expect(db.query('update charm.company_profile set legal_name=$1 where id=true', ['Hacked'])).rejects.toThrow();
 });

 it('saves the letterhead only for administrators and normalises the values', async () => {
  await expect(saveProfile(a, { legal_name: 'Nope' })).rejects.toThrow('forbidden');
  await expect(saveProfile(financeUser, { legal_name: 'Nope' })).rejects.toThrow('forbidden');
  await saveProfile(admin, {
   legal_name: '  Charm Kenya Detergents Ltd  ', trading_name: ' Charm Kenya ',
   address_line1: ' Enterprise Road ', address_line2: '', city: ' Nairobi ', country: ' Kenya ',
   phone: ' +254 20 111 222 ', email: ' Billing@CharmKenya.Co.Ke ', website: ' www.charmkenya.co.ke ',
   tax_id: ' kra-p0512345678x ', bank_name: ' KCB ', bank_account_name: ' Charm Kenya Detergents Ltd ',
   bank_account_number: ' 1234567890 ', bank_branch: ' Westlands ', mobile_money_name: ' M-PESA ',
   mobile_paybill: ' 400200 ', mobile_account: ' CHARMKEN ', delivery_terms: ' Check goods at delivery. ',
   invoice_terms: ' Payment due within 30 days. ', footer_note: ' Thank you for your business. ',
  });
  const saved = (await db.query('select * from charm.company_profile where id=true')).rows[0];
  expect(saved.legal_name).toBe('Charm Kenya Detergents Ltd');
  expect(saved.city).toBe('Nairobi');
  expect(saved.email).toBe('billing@charmkenya.co.ke');
  expect(saved.tax_id).toBe('KRA-P0512345678X');
  expect(saved.bank_branch).toBe('Westlands');
  expect(Number(saved.updated_by)).toBe(1);
  expect(await scalar('select count(*)::int from charm.audit_logs where action=$1', ['companyProfileUpdated'])).toBeGreaterThan(0);
 });

 it('rejects a blank trading name, a malformed email and oversized letterhead text', async () => {
  await expect(saveProfile(admin, { legal_name: '   ' })).rejects.toThrow('invalid');
  await expect(saveProfile(admin, { legal_name: 'Charm Kenya', email: 'not-an-email' })).rejects.toThrow('invalid');
  await expect(saveProfile(admin, { legal_name: 'Charm Kenya', footer_note: 'x'.repeat(301) })).rejects.toThrow('invalid');
  expect(await scalar('select legal_name from charm.company_profile')).toBe('Charm Kenya Detergents Ltd');
 });

 it('builds the invoice payload with company identity, VAT and the running balance', async () => {
  await asUser(a);
  const doc = await scalar('select charm.sales_document_payload(1)');
  expect(doc.company.legal_name).toBe('Charm Kenya Detergents Ltd');
  expect(doc.company.tax_id).toBe('KRA-P0512345678X');
  expect(doc.company.mobile_paybill).toBe('400200');
  expect(doc.client.name).toBe('Nairobi client');
  expect(doc.client.phone).toBe('0711000111');
  expect(doc.salesperson.staff_code).toBe('CHM-SP-001');
  expect(doc.order.contract_reference).toBe('CHM/CT/2026/014');
  expect(doc.items).toHaveLength(2);
  expect(doc.items[0].sku).toBe('CHQ-LIQ-5L');
  expect(doc.items[0].barcode).toBe('DOC-111');
  expect(Number(doc.items[0].quantity)).toBe(2);
  expect(doc.items[0].unit).toBe('bottle');
  expect(Number(doc.items[0].unit_price)).toBe(100);
  expect(Number(doc.items[0].line_total)).toBe(200);
  expect(Number(doc.invoice.subtotal)).toBe(1100);
  expect(Number(doc.invoice.tax_rate)).toBe(0.16);
  expect(Number(doc.invoice.tax_amount)).toBe(176);
  expect(Number(doc.invoice.total)).toBe(1276);
  expect(doc.invoice.invoice_number).toMatch(/^CHM-INV-/);
  expect(Number(doc.invoice.credit_terms_days)).toBe(30);
  expect(Number(doc.payments.verified)).toBe(500);
  expect(Number(doc.payments.pending)).toBe(200);
  expect(doc.payments.lines).toHaveLength(1);
  expect(doc.payments.lines[0].reference).toBe('M-PESA-DOC-1');
  expect(doc.credit_notes).toEqual([]);
 });

 it('builds the delivery note payload with bottle conversions and driver details', async () => {
  await asUser(a);
  const doc = await scalar('select charm.sales_document_payload(1)');
  expect(doc.delivery.delivery_number).toMatch(/^DN-\d{8}-\d{5}$/);
  expect(doc.delivery.status).toBe('planned');
  expect(doc.delivery.driver_name).toBe('Driver One');
  expect(doc.delivery.vehicle).toBe('KDA 001A');
  expect(doc.delivery.notes).toBe('Deliver before noon');
  expect(doc.delivery.items).toHaveLength(2);
  const carton = doc.delivery.items.find((line: any) => line.unit === 'carton');
  expect(Number(carton.bottles)).toBe(12);
  expect(carton.sku).toBe('CHQ-LIQ-5L');
  const bottle = doc.delivery.items.find((line: any) => line.unit === 'bottle');
  expect(Number(bottle.bottles)).toBe(2);
 });

 it('serves documents to the owning salesperson and finance, and nobody else', async () => {
  await asUser(b);
  await expect(scalar('select charm.sales_document_payload(1)')).rejects.toThrow('notFound');
  await asUser(financeUser);
  const officer = await scalar('select charm.sales_document_payload(1)');
  expect(officer.invoice.invoice_number).toMatch(/^CHM-INV-/);
  expect(officer.client.name).toBe('Nairobi client');
  await asStranger();
  await expect(scalar('select charm.sales_document_payload(1)')).rejects.toThrow('unauthorized');
  await asUser(a);
  await expect(scalar('select charm.sales_document_payload(999999)')).rejects.toThrow('notFound');
 });

 it('shows a pending order without an invoice or delivery as a document without those sections', async () => {
  await asUser(b);
  const doc = await scalar('select charm.sales_document_payload(2)');
  expect(doc.order.status).toBe('pending');
  expect(doc.invoice).toBeNull();
  expect(doc.delivery).toBeNull();
  expect(Number(doc.items[0].line_total)).toBe(100);
  expect(Number(doc.payments.verified)).toBe(0);
  expect(doc.payments.lines).toEqual([]);
 });
});

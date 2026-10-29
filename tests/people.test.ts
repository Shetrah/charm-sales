import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';

const db = new PGlite();
const admin = '00000000-0000-4000-8000-000000000001';
const a = '00000000-0000-4000-8000-000000000002';
const b = '00000000-0000-4000-8000-000000000003';
let keyCount = 300;
const key = () => `30000000-0000-4000-8000-${String(keyCount++).padStart(12, '0')}`;

async function scalar(sql: string, params: unknown[] = []): Promise<any> {
 const result = await db.query(sql, params);
 return Object.values(result.rows[0] ?? {})[0];
}
async function asUser(id: string) {
 await db.exec('reset role');
 await db.query("select set_config('request.jwt.claim.sub',$1,false)", [id]);
 await db.exec('set role authenticated');
}
async function asSystem() {
 await db.exec('reset role');
}
async function today() {
 return String(await scalar("select to_char(now() at time zone 'Africa/Nairobi','YYYY-MM-DD')"));
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
 select setval(pg_get_serial_sequence('charm.users','id'),4);
 select setval(pg_get_serial_sequence('charm.clients','id'),2);`);
}, 60000);

afterAll(() => db.close());

describe.sequential('People, attendance, leave and commissions', () => {
 it('assigns stable staff codes and keeps them on new staff', async () => {
  expect(await scalar("select staff_code from charm.users where id=1")).toBe('CK-0001');
  expect(await scalar("select staff_code from charm.users where id=2")).toBe('CK-0002');
  await asSystem();
  const code = await scalar("insert into charm.users(name,email,password,role) values('New Person','new@test.invalid','legacy','salesperson') returning staff_code");
  expect(code).toBe('CK-0005');
  await db.exec("delete from charm.users where email='new@test.invalid'");
 });

 it('records dated client ownership changes and lifecycle decisions', async () => {
  await asUser(admin);
  expect(await scalar('select charm.assign_client($1,1,3,$2)', [key(), 'Territory handover'])).toBe(1);
  expect(await scalar('select salesperson_id from charm.clients where id=1')).toBe(3);
  expect(await scalar('select count(*)::int from charm.client_assignments where client_id=1')).toBe(2);
  expect(await scalar('select count(*)::int from charm.client_assignments where client_id=1 and active')).toBe(1);
  expect(await scalar('select charm.assign_client($1,1,3,$2)', [key(), 'Territory handover'])).toBe(1);
  expect(await scalar('select count(*)::int from charm.client_assignments where client_id=1')).toBe(2);
  await asUser(a);
  expect(await scalar('select count(*)::int from charm.clients where id=1')).toBe(0);
  await asUser(b);
  expect(await scalar('select count(*)::int from charm.clients where id=1')).toBe(1);
  await db.query('select charm.set_client_lifecycle(1,$1,$2)', ['declined', 'Closed after review']);
  expect(await scalar('select lifecycle_status from charm.clients where id=1')).toBe('declined');
  await asUser(admin);
  expect(await scalar("select count(*)::int from charm.audit_logs where action='clientAssigned' and entity='clients' and entity_id=1")).toBe(1);
 });

 it('derives attendance from verified visits and supports audited corrections', async () => {
  const day = await today();
  await asSystem();
  await db.query(`insert into charm.visits(submission_key,salesperson_id,client_id,check_in_at,check_out_at,latitude,longitude,accuracy_m,outcome,notes)
   values($1,2,1,charm.business_day_start($2::date)+interval '9 hours',charm.business_day_start($2::date)+interval '17 hours',-1.28,36.82,10,'order','Full day')`, [key(), day]);
  expect(await scalar('select status from charm.attendance_days where salesperson_id=2 and day=$1', [day])).toBe('full');
  expect(Number(await scalar('select hours from charm.attendance_days where salesperson_id=2 and day=$1', [day]))).toBe(8);

  const prior = String(await scalar("select to_char(d,'YYYY-MM-DD') from generate_series($1::date - 7,$1::date - 1,'1 day') d where extract(isodow from d) between 1 and 5 order by d desc limit 1", [day]));
  await db.query(`insert into charm.visits(submission_key,salesperson_id,client_id,check_in_at,check_out_at,latitude,longitude,accuracy_m,outcome,notes)
   values($1,2,1,charm.business_day_start($2::date)+interval '9 hours',charm.business_day_start($2::date)+interval '11 hours',-1.28,36.82,10,'follow-up','Morning visit')`, [key(), prior]);
  expect(await scalar('select status from charm.attendance_days where salesperson_id=2 and day=$1', [prior])).toBe('incomplete');
  await db.query(`insert into charm.visits(submission_key,salesperson_id,client_id,check_in_at,check_out_at,latitude,longitude,accuracy_m,outcome,notes)
   values($1,2,1,charm.business_day_start($2::date)+interval '11 hours 30 minutes',charm.business_day_start($2::date)+interval '13 hours 30 minutes',-1.28,36.82,10,'order','Second visit')`, [key(), prior]);
  expect(await scalar('select status from charm.attendance_days where salesperson_id=2 and day=$1', [prior])).toBe('partial');
  expect(Number(await scalar('select hours from charm.attendance_days where salesperson_id=2 and day=$1', [prior]))).toBe(4.5);

  await asUser(admin);
  const report = await scalar('select charm.attendance_report($1::date,$1::date,null)', [prior]);
  const saleRow = report.rows.find((row: any) => row.salesperson_id === 2);
  expect(saleRow.status).toBe('partial');
  await db.query('select charm.correct_attendance(2,$1,$2,$3,$4)', [prior, 'full', 'Late approval evidence', 'Manager verified']);
  expect(await scalar('select status from charm.attendance_days where salesperson_id=2 and day=$1', [prior])).toBe('full');
  expect(await scalar('select corrected_by from charm.attendance_days where salesperson_id=2 and day=$1', [prior])).toBe(1);
  await db.query('select charm.correct_attendance(2,$1,$2,$3,$4)', [prior, 'auto', 'Correction restored', '']);
  expect(await scalar('select status from charm.attendance_days where salesperson_id=2 and day=$1', [prior])).toBe('partial');
 });

 it('routes leave through submission, balance checks, approval and attendance', async () => {
  const start = String(await scalar("select to_char((date_trunc('week',now() at time zone 'Africa/Nairobi')::date + 7),'YYYY-MM-DD')"));
  const end = String(await scalar("select to_char((date_trunc('week',now() at time zone 'Africa/Nairobi')::date + 8),'YYYY-MM-DD')"));
  await asUser(a);
  const id = await scalar('select charm.save_leave_request($1,null,1,$2::date,$3::date,$4,null,null)', [key(), start, end, 'Family commitment']);
  expect(await scalar('select status from charm.leave_requests where id=$1', [id])).toBe('draft');
  expect(Number(await scalar('select days from charm.leave_requests where id=$1', [id]))).toBe(2);
  await db.query('select charm.submit_leave_request($1)', [id]);
  expect(await scalar('select status from charm.leave_requests where id=$1', [id])).toBe('pending');
  await expect(db.query('select charm.submit_leave_request($1)', [id])).rejects.toThrow();
  await asUser(b);
  await expect(db.query("select charm.decide_leave_request($1,'approve','ok')", [id])).rejects.toThrow();
  await asUser(admin);
  await db.query("select charm.decide_leave_request($1,'approve','Approved')", [id]);
  expect(await scalar('select status from charm.leave_requests where id=$1', [id])).toBe('approved');
  expect(await scalar('select status from charm.attendance_days where salesperson_id=2 and day=$1::date', [start])).toBe('leave');
  const balance = await scalar('select charm.leave_balances(2026,2)');
  expect(Number(balance.find((row: any) => row.leave_type_id === 1).remaining)).toBe(19);
 });

 it('snapshots commission rates per order and preserves history when rules change', async () => {
  const day = await today();
  await asUser(admin);
  const rule = await scalar("select charm.save_commission_rule($1,null,'Standard commission','gross','percentage',10::numeric,null::numeric,'2026-01-01'::date,null,true,'[]'::jsonb,'')", [key()]);
  await asSystem();
  const product = await scalar("insert into charm.products(category,capacity,fragrance,barcode,carton,unit_price) values('Perfume','100ml','Amber','TEST-BARCODE-1',12,100) returning id");
  const makeOrder = async () => {
   const order = await scalar(`insert into charm.orders(submission_key,client_id,salesperson_id,total,status,created_at,updated_at)
    values($1,1,2,1000,'pending',now(),now()) returning id`, [key()]);
   await db.query("insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total) values($1,$2,'Perfume 100ml Amber','bottle',10,100,1000)", [order, product]);
   await db.query("update charm.orders set status='confirmed',confirmed_at=now(),confirmed_by=1 where id=$1", [order]);
   return order;
  };
  const firstOrder = await makeOrder();
  const first = await scalar('select commission_amount from charm.commission_entries where order_id=$1', [firstOrder]);
  expect(Number(first)).toBe(100);

  await asUser(admin);
  await db.query("select charm.save_commission_rule($1,$2,'Standard commission','gross','percentage',20::numeric,null::numeric,'2026-01-01'::date,null,true,'[]'::jsonb,'')", [key(), rule]);
  expect(Number(await scalar('select commission_amount from charm.commission_entries where order_id=$1', [firstOrder]))).toBe(100);
  await asSystem();
  const secondOrder = await makeOrder();
  expect(Number(await scalar('select commission_amount from charm.commission_entries where order_id=$1', [secondOrder]))).toBe(200);

  await asUser(admin);
  const summary = await scalar('select charm.commission_summary($1::date,$1::date,null)', [day]);
  expect(Number(summary.totals.earned)).toBe(300);
  const entry = await scalar('select id from charm.commission_entries where order_id=$1', [secondOrder]);
  await db.query("select charm.commission_decide($1,'approved',null,'Reviewed')", [entry]);
  await db.query("select charm.commission_decide($1,'paid',null,'Settled')", [entry]);
  const after = await scalar('select charm.commission_summary($1::date,$1::date,null)', [day]);
  expect(Number(after.totals.paid)).toBe(200);
 });
});

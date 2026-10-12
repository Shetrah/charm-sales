import { beforeAll, afterAll, describe, it, expect } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { cents, lineTotal } from '../src/lib/money';
import { translations } from '../src/i18n';
const db=new PGlite();
const admin='00000000-0000-4000-8000-000000000001', a='00000000-0000-4000-8000-000000000002', b='00000000-0000-4000-8000-000000000003';
let keyCount=10;const key=()=>`10000000-0000-4000-8000-${String(keyCount++).padStart(12,'0')}`;
async function scalar(sql:string,params:unknown[]=[]):Promise<any>{const r=await db.query(sql,params);return Object.values(r.rows[0]??{})[0];}
async function asUser(id:string){await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');}
beforeAll(async()=>{
 await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
 create schema auth; create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth to authenticated,anon; grant execute on function auth.uid() to authenticated,anon;
 create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text,unique(bucket_id,name));alter table storage.objects enable row level security;
 grant usage on schema storage to authenticated,anon;grant select,insert,update,delete on storage.objects to authenticated,anon;`);
 for(const file of readdirSync('supabase/migrations').sort())await db.exec(readFileSync(`supabase/migrations/${file}`,'utf8'));
 await db.exec(`insert into auth.users values('${admin}','admin@test.invalid'),('${a}','a@test.invalid'),('${b}','b@test.invalid');
 insert into charm.users(id,name,email,password,role) values(1,'Admin','admin@test.invalid','legacy','admin'),(2,'A','a@test.invalid','legacy','salesperson'),(3,'B','b@test.invalid','legacy','salesperson');
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values('${admin}',1),('${a}',2),('${b}',3);
 insert into charm.clients(id,salesperson_id,name,contact,location) values(1,2,'A client','A contact','Nairobi'),(2,3,'B client','B contact','Mombasa');`);
},60000);
afterAll(()=>db.close());
describe.sequential('Supabase PostgreSQL migration and permissions',()=>{
 let order:number,payment:number;
 it('preserves 48 variants, null quotation prices and source discrepancies',async()=>{
  expect(await scalar('select count(*)::int from charm.products')).toBe(48);
  expect(await scalar('select count(*)::int from charm.products where unit_price is not null')).toBe(0);
  expect(await scalar('select count(*)::int from charm.products where needs_review')).toBe(3);
  expect(await scalar('select capacity from charm.products where id=24')).toBe('751ml');
  expect(await scalar('select barcode from charm.products where id=18')).toBe(await scalar('select barcode from charm.products where id=20'));
  await db.exec("update charm.products set unit_price=15.50 where id=1");
  await db.exec(readFileSync('supabase/migrations/202610120002_catalogue.sql','utf8'));
  expect(await scalar('select unit_price from charm.products where id=1')).toBe('15.50');
 });
 it('enforces row ownership, hides passwords and forbids direct writes',async()=>{
  await asUser(a);expect(await scalar('select count(*)::int from charm.clients')).toBe(1);
  expect(await scalar('select name from charm.clients')).toBe('A client');
  await expect(db.query('select password from charm.users')).rejects.toThrow();
  await expect(db.query("update charm.users set role='admin' where id=2")).rejects.toThrow();
  await expect(db.query("insert into charm.orders(submission_key,client_id,salesperson_id,total,status) values($1,1,2,100,'confirmed')",[key()])).rejects.toThrow();
  await expect(db.query('select charm.set_price(1,\'12.00\')')).rejects.toThrow('forbidden');
  await expect(db.query("select charm.save_client($1,'Intrusion','X',null,'Nairobi',3)",[key()])).rejects.toThrow('forbidden');
 });
 it('creates exact multi-line orders and protects concurrent retry payload identity',async()=>{
  const k=key(),items=JSON.stringify([{product_id:1,quantity:2,unit:'bottle',unit_price:'12.35'},{product_id:2,quantity:3,unit:'carton',unit_price:'8.20'}]);
  order=await scalar('select charm.submit_order($1,1,null,$2)',[k,items]);
  expect(await scalar('select total from charm.orders where id=$1',[order])).toBe('49.30');
  expect(await scalar('select charm.submit_order($1,1,null,$2)',[k,items])).toBe(order);
  await expect(db.query('select charm.submit_order($1,2,null,$2)',[key(),items])).rejects.toThrow('forbidden');
  await expect(db.query('select charm.submit_order($1,1,null,null)',[key()])).rejects.toThrow('invalid');
  await expect(db.query('select charm.submit_order($1,1,null,$2)',[key(),'{}'])).rejects.toThrow('invalid');
  await expect(db.query('select charm.submit_order($1,1,null,$2)',[k,'[]'])).rejects.toThrow('duplicateConflict');
  await asUser(b);await expect(db.query('select charm.submit_order($1,1,null,$2)',[k,items])).rejects.toThrow('duplicateConflict');
 });
 it('requires admin approval, counts pending as zero and records approvals atomically',async()=>{
  await asUser(a);const month=new Date().toISOString().slice(0,7)+'-01';
  expect((await scalar('select charm.monthly_summary($1)',[month])).monthly_sales).toBe('0.00');
  await expect(db.query('select charm.approve_order($1,true)',[order])).rejects.toThrow('forbidden');
  await asUser(admin);await db.query('select charm.approve_order($1,true)',[order]);
  await expect(db.query('select charm.approve_order($1,true)',[order])).rejects.toThrow('alreadyReviewed');
  expect(await scalar("select count(*)::int from charm.audit_logs where entity='orders' and action='confirmed'")).toBe(1);
 });
 it('pending payments leave balances unchanged and verified partial payments never increase sales',async()=>{
  await asUser(a);const k=key();const received=new Date().toISOString();
  payment=await scalar('select charm.submit_payment($1,$2,\'10.00\',\'REF-1\',$3,null)',[k,order,received]);
  expect(await scalar('select charm.submit_payment($1,$2,\'10.00\',\'REF-1\',$3,null)',[k,order,received])).toBe(payment);
  expect(await scalar('select balance from charm.order_balances where id=$1',[order])).toBe('49.30');
  await asUser(admin);await db.query('select charm.review_payment($1,true)',[payment]);
  expect(await scalar('select balance from charm.order_balances where id=$1',[order])).toBe('39.30');
  expect(await scalar('select total from charm.orders where id=$1',[order])).toBe('49.30');
  await expect(db.query('select charm.review_payment($1,true)',[payment])).rejects.toThrow('alreadyReviewed');
  await asUser(a);const p2=await scalar('select charm.submit_payment($1,$2,\'40.00\',\'REF-2\',now(),null)',[key(),order]);
  await asUser(admin);await expect(db.query('select charm.review_payment($1,true)',[p2])).rejects.toThrow('overpayment');
  expect(await scalar('select balance from charm.order_balances where id=$1',[order])).toBe('39.30');
 });
 it('blocks approval of own orders, payments and expense requests',async()=>{
  await asUser(admin);const own=await scalar('select charm.submit_order($1,1,null,$2)',[key(),JSON.stringify([{product_id:1,quantity:1,unit:'bottle',unit_price:'5.00'}])]);
  await expect(db.query('select charm.approve_order($1,true)',[own])).rejects.toThrow('selfApproval');
  const p=await scalar('select charm.submit_payment($1,$2,\'1.00\',\'own\',now(),null)',[key(),order]);
  await expect(db.query('select charm.review_payment($1,true)',[p])).rejects.toThrow('selfApproval');
  const expense=await scalar("select charm.submit_record($1,'expenses',(now() at time zone 'Africa/Nairobi')::date+1,1,'10.00','Client visit',null)",[key()]);
  await expect(db.query("select charm.review_record('expenses',$1,true)",[expense])).rejects.toThrow('selfApproval');
 });
 it('uses Nairobi confirmation boundaries and retains sales history after client assignment',async()=>{
  await db.exec('reset role');await db.query("update charm.orders set confirmed_at='2026-10-31 20:59:59+00' where id=$1",[order]);
  await asUser(admin);expect((await scalar("select charm.monthly_summary('2026-10-01')")).monthly_sales).toBe('49.30');
  expect((await scalar("select charm.monthly_summary('2026-11-01')")).monthly_sales).toBe('0.00');
  await db.exec('reset role');await db.query("update charm.orders set confirmed_at='2026-10-31 21:00:00+00' where id=$1",[order]);
  await asUser(admin);expect((await scalar("select charm.monthly_summary('2026-11-01')")).monthly_sales).toBe('49.30');
  await db.query('select charm.assign_client(1,3)');expect(await scalar('select salesperson_id from charm.orders where id=$1',[order])).toBe(2);
  await db.query('select charm.assign_client(1,2)');
 });
 it('enforces private uploads and immutable verified payment evidence',async()=>{
  await asUser(a);const path=`payments/${payment}/${key()}.png`;
  await expect(db.query("insert into storage.objects(bucket_id,name) values('charm-private',$1)",[path])).rejects.toThrow();
  const visit=await scalar("select charm.submit_visit($1,1,-1.2,36.8,10,'no-sale','Store closed','Closed',null,null)",[key()]);
  const photo=`visits/${visit}/${key()}.png`;
  await db.query("insert into storage.objects(bucket_id,name) values('charm-private',$1)",[photo]);
  await db.query("select charm.attach_file('visits',$1,$2)",[visit,photo]);
  expect(await scalar("select count(*)::int from storage.objects where name=$1",[photo])).toBe(1);
  await asUser(b);expect(await scalar('select count(*)::int from storage.objects')).toBe(0);
  await expect(db.query("insert into storage.objects(bucket_id,name) values('charm-private',$1)",[photo+'x'])).rejects.toThrow();
  await db.exec('reset role;set role anon');expect(await scalar('select count(*)::int from storage.objects')).toBe(0);
 });
 it('rejects invalid GPS, supports delayed idempotent batches and blocks other routes',async()=>{
  await asUser(a);const w=await scalar('select charm.start_workday()');
  await expect(db.query('select charm.location_batch($1,null)',[w])).rejects.toThrow('invalid');
  expect(await scalar('select charm.start_workday()')).toBe(w);
  const points=JSON.stringify([{submission_key:key(),latitude:-1.2,longitude:36.8,accuracy_m:8,recorded_at:new Date().toISOString()}]);
  await db.query('select charm.end_workday($1)',[w]);
  expect(await scalar('select charm.location_batch($1,$2)',[w,points])).toBe(1);
  expect(await scalar('select charm.location_batch($1,$2)',[w,points])).toBe(1);
  expect(await scalar('select count(*)::int from charm.location_points')).toBe(1);
  await expect(db.query('select charm.location_batch($1,$2)',[w,JSON.stringify([{submission_key:key(),latitude:999,longitude:1,accuracy_m:8,recorded_at:new Date().toISOString()}])])).rejects.toThrow('invalidLocation');
  await asUser(b);expect(await scalar('select count(*)::int from charm.workdays')).toBe(0);await expect(db.query('select charm.location_batch($1,$2)',[w,points])).rejects.toThrow('forbidden');
 });
 it('blocks inactive accounts and unmapped authenticated users',async()=>{
  await db.exec('reset role;update charm.users set active=false where id=2');await asUser(a);
  expect(await scalar('select count(*)::int from charm.clients')).toBe(0);await expect(db.query('select charm.start_workday()')).rejects.toThrow('unauthorized');
  await asUser('00000000-0000-4000-8000-000000000099');expect(await scalar('select charm.actor()')).toBe(null);
  await expect(db.query("select charm.link_staff($1,$2,'a@test.invalid','A','admin')",[admin,a])).rejects.toThrow();
 });
 it('links legacy accounts only through the service role and preserves their ID and role',async()=>{
  await db.exec('reset role;update charm.users set active=true where id=2');
  await db.exec('set role service_role');
  expect(await scalar("select charm.link_staff($1,$2,'a@test.invalid','Renamed','admin')",[admin,a])).toBe(2);
  await asUser(a);expect(await scalar('select role from charm.users')).toBe('salesperson');
  expect(await scalar('select name from charm.users')).toBe('A');
  await db.exec('reset role;set role service_role');
  await expect(db.query("select charm.link_staff($1,$2,'admin@test.invalid','Admin','salesperson')",[admin,admin])).rejects.toThrow('forbidden');
 });
 it('edits staff securely without changing historical attribution and exposes exact admin profile metrics',async()=>{
  await asUser(a);await expect(db.query("select charm.update_staff(2,'Changed','0712345678','Nairobi','admin',true)")).rejects.toThrow('forbidden');
  await expect(db.query("select charm.staff_profile(2,'2026-11-01')")).rejects.toThrow('forbidden');
  await asUser(admin);
  await expect(db.query("select charm.update_staff(1,'Admin',null,null,'salesperson',true)")).rejects.toThrow('selfRoleChange');
  await expect(db.query("select charm.update_staff(1,'Admin',null,null,'admin',false)")).rejects.toThrow('selfRoleChange');
  await db.query("select charm.update_staff(2,'Updated salesperson','0712345678','Nairobi','salesperson',true)");
  const profile=await scalar("select charm.staff_profile(2,'2026-11-01')");
  expect(profile.person.id).toBe(2);expect(profile.person.name).toBe('Updated salesperson');expect(profile.person.phone).toBe('0712345678');
  expect(profile.person).not.toHaveProperty('password');expect(profile.person).not.toHaveProperty('remember_token');
  expect(profile.monthly_sales).toBe('49.30');expect(profile.lifetime_sales).toBe('49.30');expect(profile.outstanding).toBe('39.30');
  expect(profile.trend).toHaveLength(6);expect(profile.trend[5].sales).toBe('49.30');
  expect(await scalar('select salesperson_id from charm.orders where id=$1',[order])).toBe(2);
 });
 it('captures client coordinates only for the owner or administrator',async()=>{
  await asUser(b);await expect(db.query('select charm.set_client_location(1,-1.2,36.8,12)')).rejects.toThrow('forbidden');
  await asUser(a);await db.query('select charm.set_client_location(1,-1.2,36.8,12)');
  expect(await scalar('select latitude from charm.clients where id=1')).toBe('-1.2000000');
  await expect(db.query('select charm.set_client_location(1,999,36.8,12)')).rejects.toThrow('invalidLocation');
 });
});
describe('frontend financial and localization contracts',()=>{
 it('uses exact cents without multiplying carton size',()=>{expect(cents('12.35')).toBe(1235n);expect(lineTotal('12.35',2)).toBe('24.70');expect(lineTotal('8.20',3)).toBe('24.60');expect(()=>cents('1.001')).toThrow();});
 it('provides English and Simplified Chinese for every defined interface key',()=>{for(const [key,value] of Object.entries(translations)){expect(value[0],key).toBeTruthy();expect(value[1],key).toBeTruthy();}});
});

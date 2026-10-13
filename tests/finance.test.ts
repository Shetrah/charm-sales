import { beforeAll, afterAll, describe, it, expect } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { csvCell } from '../src/lib/exportCells';
const db=new PGlite();const auth=(id:number)=>`00000000-0000-4000-8000-${String(id).padStart(12,'0')}`;let keyIndex=1;const key=()=>`f0000000-0000-4000-8000-${String(keyIndex++).padStart(12,'0')}`;
async function scalar(sql:string,args:unknown[]=[]):Promise<any>{const result=await db.query(sql,args);return Object.values(result.rows[0]??{})[0];}
async function user(id:number){await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[auth(id)]);await db.exec('set role authenticated');}
let date:string,due:string,month:string,request:number,account:number,second:number,firstProof:number,paidAt:string,disbursementKey:string,refund:number;
async function createRequest(amount='100.35',payee:number|null=null){return scalar('select charm.finance_save_request($1,null,1,$2,\'Client delivery\',$3,$4,$5)',[key(),amount,date,due,payee]);}
async function proof(id:number,kind:string,actor:number){const path=`requests/${id}/${kind}/${actor}/${key()}.pdf`;await db.query("insert into storage.objects(bucket_id,name) values('charm-finance',$1)",[path]);return scalar('select charm.finance_attach_document($1,$2,$3)',[id,kind,path]);}
beforeAll(async()=>{
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema auth;create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth to authenticated,anon;grant execute on function auth.uid() to authenticated,anon;
 create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text,unique(bucket_id,name));alter table storage.objects enable row level security;
 grant usage on schema storage to authenticated;grant select,insert,update,delete on storage.objects to authenticated;`);
 for(const file of readdirSync('supabase/migrations').sort())await db.exec(readFileSync(`supabase/migrations/${file}`,'utf8'));
 const roles=['admin','salesperson','salesperson','finance_officer','finance_officer','salesperson','salesperson','admin'];
 for(let i=1;i<=roles.length;i++){await db.query('insert into auth.users values($1,$2)',[auth(i),`test${i}@invalid.test`]);await db.query("insert into charm.users(id,name,email,password,role) values($1,$2,$3,'test-only',$4)",[i,`Person ${i}`,`test${i}@invalid.test`,roles[i-1]]);await db.query('insert into charm.auth_accounts(auth_user_id,salesperson_id) values($1,$2)',[auth(i),i]);}
 date=await scalar("select ((now() at time zone 'Africa/Nairobi')::date+1)::text");due=await scalar("select ($1::date+7)::text",[date]);month=date.slice(0,7)+'-01';
},60000);
afterAll(()=>db.close());
describe.sequential('Integrated finance controls in PostgreSQL',()=>{
 it('creates one request, keeps exact money and prevents unauthorized admin/finance actions',async()=>{
  await user(2);request=await createRequest();await db.query('select charm.finance_submit_request($1)',[request]);expect(await scalar('select amount from charm.finance_requests where id=$1',[request])).toBe('100.35');
  await expect(db.query("select charm.finance_review_request($1,'approved',null,'90.20')",[request])).rejects.toThrow('forbidden');
  await user(4);await expect(db.query("select charm.finance_review_request($1,'approved',null,'90.20')",[request])).rejects.toThrow('forbidden');
  expect(await scalar('select count(*)::int from charm.finance_requests')).toBe(0);await expect(db.query('select charm.finance_detail($1)',[request])).rejects.toThrow('forbidden');
  await user(1);await expect(db.query("select charm.finance_review_request($1,'approved',null,'90.20')",[request])).rejects.toThrow('budgetMissing');
  await expect(db.query("select charm.finance_disburse($1,$2,1,'1.00','X',now(),1,true)",[key(),request])).rejects.toThrow('financeLocked');
  await expect(db.query("update charm.finance_requests set status='approved' where id=$1",[request])).rejects.toThrow();
 });
 it('finance officers configure budgets, verified recipients and confirmed opening funds',async()=>{
  await user(2);await expect(db.query("select charm.finance_configure($1,'account',$2)",[key(),JSON.stringify({name:'M-Pesa operations',method:'M-Pesa'})])).rejects.toThrow('forbidden');
  await user(5);account=await scalar("select charm.finance_configure($1,'account',$2)",[key(),JSON.stringify({name:'M-Pesa operations',method:'M-Pesa'})]);
  await expect(db.query("select charm.finance_configure($1,'opening',$2)",[key(),JSON.stringify({account_id:account,amount:'10000.00',reference:'OPEN',confirmed:false})])).rejects.toThrow('paymentConfirmationRequired');
  await db.query("select charm.finance_configure($1,'opening',$2)",[key(),JSON.stringify({account_id:account,amount:'10000.00',reference:'OPEN',confirmed:true})]);
  await db.query("select charm.finance_configure($1,'budget',$2)",[key(),JSON.stringify({category_id:1,month,amount:'1000.00'})]);
  await db.query("select charm.finance_configure($1,'payee',$2)",[key(),JSON.stringify({staff_id:2,name:'Person 2',details:'Verified test destination'})]);
  await user(1);await db.query("select charm.finance_review_request($1,'approved',null,'90.20')",[request]);
 });
 it('enforces self-approval, monthly commitments and returned requests with reasons',async()=>{
  await user(1);const own=await createRequest();await db.query('select charm.finance_submit_request($1)',[own]);await expect(db.query("select charm.finance_review_request($1,'approved',null,'100.35')",[own])).rejects.toThrow('selfApproval');
  await user(2);second=await createRequest('5.00');await db.query('select charm.finance_submit_request($1)',[second]);const big=await createRequest('999.99');await db.query('select charm.finance_submit_request($1)',[big]);
  await user(1);await expect(db.query("select charm.finance_review_request($1,'approved',null,'999.99')",[big])).rejects.toThrow('budgetExceeded');
  await expect(db.query("select charm.finance_review_request($1,'returned','',null)",[big])).rejects.toThrow('reasonRequired');await db.query("select charm.finance_review_request($1,'returned','Attach delivery plan',null)",[big]);
  await db.query("select charm.finance_review_request($1,'approved',null,'5.00')",[second]);
  await user(5);await expect(db.query("select charm.finance_configure($1,'budget',$2)",[key(),JSON.stringify({category_id:1,month,amount:'10.00'})])).rejects.toThrow('budgetExceeded');
 });
 it('requires evidence and confirmation, supports partial payments and rejects conflicting retries',async()=>{
  await user(4);paidAt=await scalar('select now()::text');firstProof=await proof(request,'payment',4);disbursementKey=key();
  await expect(db.query("select charm.finance_disburse($1,$2,$3,'30.10','PART-1',$4,$5,false)",[key(),request,account,paidAt,firstProof])).rejects.toThrow('paymentConfirmationRequired');
  await expect(db.query("select charm.finance_disburse($1,$2,$3,'30.10','PART-1',$4,999,true)",[key(),request,account,paidAt])).rejects.toThrow('proofRequired');
  const id=await scalar("select charm.finance_disburse($1,$2,$3,'30.10','PART-1',$4,$5,true)",[disbursementKey,request,account,paidAt,firstProof]);
  expect(await scalar("select charm.finance_disburse($1,$2,$3,'30.10','PART-1',$4,$5,true)",[disbursementKey,request,account,paidAt,firstProof])).toBe(id);
  await expect(db.query("select charm.finance_disburse($1,$2,$3,'30.11','PART-1',$4,$5,true)",[disbursementKey,request,account,paidAt,firstProof])).rejects.toThrow('duplicateConflict');
  const p2=await proof(request,'payment',4);await expect(db.query("select charm.finance_disburse($1,$2,$3,'61.00','OVER',now(),$4,true)",[key(),request,account,p2])).rejects.toThrow('overpayment');
  await db.query("select charm.finance_disburse($1,$2,$3,'60.10','PART-2',now(),$4,true)",[key(),request,account,p2]);
  expect((await scalar('select charm.finance_detail($1)',[request])).request.paid).toBe('90.20');expect((await scalar('select charm.finance_detail($1)',[request])).request.status).toBe('paid');
 });
 it('blocks another outstanding advance and records durable, recipient-scoped notifications',async()=>{
  await user(4);const doc=await proof(second,'payment',4);await expect(db.query("select charm.finance_disburse($1,$2,$3,'5.00','NEXT',now(),$4,true)",[key(),second,account,doc])).rejects.toThrow('advanceOutstanding');
  await user(2);expect(await scalar("select count(*)::int from charm.finance_notifications where event='financeDisbursed'")).toBe(2);expect(await scalar('select count(*)::int from charm.finance_notifications where recipient_id<>2')).toBe(0);
  await db.query('select charm.finance_mark_read(null)');expect(await scalar('select count(*)::int from charm.finance_notifications where read_at is null')).toBe(0);
  await user(3);expect(await scalar('select count(*)::int from charm.finance_requests')).toBe(0);await expect(db.query('select charm.finance_detail($1)',[request])).rejects.toThrow('forbidden');
 });
 it('checks receipt totals and refund confirmation before closing a fully settled advance',async()=>{
  await user(2);const expenseProof=await proof(request,'receipt',2);const expense=await scalar("select charm.finance_submit_accountability($1,$2,'expense','80.00','Delivery expenses',$3,null,null)",[key(),request,expenseProof]);
  const refundProof=await proof(request,'refund',2);await expect(db.query("select charm.finance_submit_accountability($1,$2,'refund','11.00','Unused money',$3,'REFUND-1',$4)",[key(),request,refundProof,account])).rejects.toThrow('overpayment');
  refund=await scalar("select charm.finance_submit_accountability($1,$2,'refund','10.20','Unused money',$3,'REFUND-1',$4)",[key(),request,refundProof,account]);
  await user(4);await expect(db.query("select charm.finance_close_request($1,'Settled')",[request])).rejects.toThrow('advanceOutstanding');await db.query("select charm.finance_review_accountability($1,true,null,false)",[expense]);
  await expect(db.query('select charm.finance_review_accountability($1,true,null,false)',[refund])).rejects.toThrow('paymentConfirmationRequired');await db.query('select charm.finance_review_accountability($1,true,null,true)',[refund]);await db.query("select charm.finance_close_request($1,'Settled')",[request]);
  expect((await scalar('select charm.finance_detail($1)',[request])).request.outstanding).toBe('0.00');await expect(db.query("select charm.finance_disburse($1,$2,$3,'1.00','CLOSED',now(),$4,true)",[key(),request,account,firstProof])).rejects.toThrow('financeLocked');
  expect((await scalar("select charm.finance_register('budgets',$1,$2,'',null,1)",[month,due])).rows[0].committed).toBe('85.00');
  await db.exec('reset role');await expect(db.query("delete from charm.finance_ledger where request_id=$1",[request])).rejects.toThrow('financeImmutable');await expect(db.query('update charm.finance_disbursements set amount=1 where request_id=$1',[request])).rejects.toThrow('financeImmutable');
 });
 it('enforces exact statement matching, duplicate references and insufficient funds',async()=>{
  await user(4);const proofId=await proof(second,'payment',4);await expect(db.query("select charm.finance_disburse($1,$2,$3,'5.00','PART-1',now(),$4,true)",[key(),second,account,proofId])).rejects.toThrow();
  await expect(db.query("select charm.finance_disburse($1,$2,$3,'5.00','part-1',now(),$4,true)",[key(),second,account,proofId])).rejects.toThrow();
  await user(5);const empty=await scalar("select charm.finance_configure($1,'account',$2)",[key(),JSON.stringify({name:'Empty cash',method:'Cash'})]);await user(4);await expect(db.query("select charm.finance_disburse($1,$2,$3,'5.00','NO-FUNDS',now(),$4,true)",[key(),second,empty,proofId])).rejects.toThrow('insufficientFunds');
  const day=await scalar("select (($1::timestamptz at time zone 'Africa/Nairobi')::date)::text",[paidAt]);const line=await scalar("select charm.finance_statement($1,$2,'part-1','out','30.10',$3)",[key(),account,day]);const ledger=await scalar("select id from charm.finance_ledger where reference='PART-1'");
  await db.query('select charm.finance_match_statement($1,$2)',[line,ledger]);await expect(db.query('select charm.finance_match_statement($1,$2)',[line,ledger])).rejects.toThrow('financeLocked');
  const mismatch=await scalar("select charm.finance_statement($1,$2,'DIFFERENT','out','30.10',$3)",[key(),account,day]);await expect(db.query('select charm.finance_match_statement($1,$2)',[mismatch,ledger])).rejects.toThrow('reconciliationMismatch');
 });
 it('salespeople cannot access other requests or configure finances',async()=>{
  for(const id of [6,7]){await user(id);expect(await scalar('select count(*)::int from charm.finance_requests')).toBe(0);await expect(db.query('select charm.finance_detail($1)',[request])).rejects.toThrow('forbidden');await expect(db.query("select charm.finance_configure($1,'category','{\"name\":\"X\"}')",[key()])).rejects.toThrow('forbidden');await expect(db.query('delete from charm.finance_requests')).rejects.toThrow();}
 });
 it('supplier payouts require Admin approval and the same officer can complete payment and preserve payee snapshots',async()=>{
  await user(5);const supplier=await scalar("select charm.finance_configure($1,'payee',$2)",[key(),JSON.stringify({name:'Verified Supplier',details:'Verified supplier bank account'})]);await user(4);const id=await createRequest('40.00',supplier);await db.query('select charm.finance_submit_request($1)',[id]);await expect(db.query("select charm.finance_review_request($1,'approved',null,'40.00')",[id])).rejects.toThrow('forbidden');await user(1);await db.query("select charm.finance_review_request($1,'approved',null,'40.00')",[id]);await user(4);const doc=await proof(id,'payment',4);await db.query("select charm.finance_disburse($1,$2,$3,'40.00','SUPPLIER-1',now(),$4,true)",[key(),id,account,doc]);await db.query("select charm.finance_close_request($1,'Supplier paid in full')",[id]);expect((await scalar('select charm.finance_detail($1)',[id])).payments[0].payee_snapshot.name).toBe('Verified Supplier');
 });
 it('integrates customer receipts once, assigns confirmed funds and waits for a real statement to reconcile',async()=>{
  await user(2);const client=await scalar("select charm.save_client($1,'Finance client','Contact',null,'Nairobi',2)",[key()]);const order=await scalar("select charm.submit_order($1,$2,null,$3)",[key(),client,JSON.stringify([{product_id:1,quantity:1,unit:'bottle',unit_price:'100.00'}])]);await user(1);await db.query('select charm.approve_order($1,true)',[order]);await user(2);const payment=await scalar("select charm.submit_payment($1,$2,'45.75','CUSTOMER-1',now(),null)",[key(),order]);const path=`payments/${payment}/${key()}.png`;await db.query("insert into storage.objects(bucket_id,name) values('charm-private',$1)",[path]);await db.query("select charm.attach_file('payments',$1,$2)",[payment,path]);
  await user(4);await db.query('select charm.finance_verify_customer_receipt($1,true,$2)',[payment,account]);await expect(db.query('select charm.finance_verify_customer_receipt($1,true,$2)',[payment,account])).rejects.toThrow('financeLocked');expect(await scalar('select count(*)::int from charm.finance_ledger where customer_payment_id=$1',[payment])).toBe(1);expect(await scalar('select account_id from charm.finance_cashbook where customer_payment_id=$1',[payment])).toBe(account);expect(await scalar('select statement_id from charm.finance_cashbook where customer_payment_id=$1',[payment])).toBeNull();expect(await scalar('select balance from charm.order_balances where id=$1',[order])).toBe('54.25');
  const exported=await scalar("select charm.finance_export('cashbook',$1,$2,'',null)",[paidAt.slice(0,10),due]);expect(exported.some((x:any)=>x.reference==='CUSTOMER-1'&&x.amount==='45.75')).toBe(true);
 });
 it('links legacy travel requests once and synchronizes financial decisions with their original IDs',async()=>{
  await user(2);const client=await scalar('select id from charm.clients order by id limit 1');const expense=await scalar("select charm.submit_record($1,'expenses',$2,$3,'25.00','Legacy delivery',null)",[key(),date,client]);const linked=await scalar('select id from charm.finance_requests where source_expense_id=$1',[expense]);expect(linked).toBeTruthy();expect(await scalar('select count(*)::int from charm.finance_requests where source_expense_id=$1',[expense])).toBe(1);
  await user(5);await db.query("select charm.finance_configure($1,'budget',$2)",[key(),JSON.stringify({category_id:7,month,amount:'100.00'})]);await user(1);await db.query("select charm.finance_review_request($1,'approved',null,'25.00')",[linked]);expect(await scalar('select status from charm.expenses where id=$1',[expense])).toBe('approved');expect((await scalar('select charm.finance_detail($1)',[linked])).request.paid).toBe('0.00');
  await user(2);const rejected=await scalar("select charm.submit_record($1,'expenses',$2,$3,'10.00','Legacy rejected',null)",[key(),date,client]);await user(1);await db.query("select charm.review_record('expenses',$1,false)",[rejected]);expect(await scalar('select status from charm.finance_requests where source_expense_id=$1',[rejected])).toBe('rejected');
 });
 it('reconciles a refund against its actual bank date when Finance reviews it later',async()=>{
  await db.exec('reset role');const dates=await scalar("select jsonb_build_object('fund',now()-interval '2 days','approval',now()-interval '3 days','refund',((now() at time zone 'Africa/Nairobi')::date-1)::text,'month',date_trunc('month',(now()-interval '2 days') at time zone 'Africa/Nairobi')::date::text)");
  await user(5);const budget=await scalar("select charm.finance_configure($1,'budget',$2)",[key(),JSON.stringify({category_id:1,month:dates.month,amount:'1000.00'})]);await db.query("select charm.finance_configure($1,'payee',$2)",[key(),JSON.stringify({staff_id:3,name:'Person 3',details:'Verified historical recipient'})]);
  // Existing approved historical request fixture; the following financial actions use real APIs.
  await db.exec('reset role');const old=await scalar("insert into charm.finance_requests(owner_id,kind,category_id,amount,approved_amount,purpose,required_date,accountability_due,status,approved_by,approved_at,budget_id) values(3,'staff',1,15,15,'Earlier advance',($1::timestamptz at time zone 'Africa/Nairobi')::date,$2,'approved',1,$3,$4) returning id",[dates.fund,due,dates.approval,budget]);
  await user(4);const paidProof=await proof(old,'payment',4);await db.query("select charm.finance_disburse($1,$2,$3,'15.00','OLDER-ADVANCE',$4,$5,true)",[key(),old,account,dates.fund,paidProof]);await user(3);const returnedProof=await proof(old,'refund',3);const returned=await scalar("select charm.finance_submit_accountability($1,$2,'refund','15.00','Unused funds',$3,'OLDER-REFUND',$4,$5)",[key(),old,returnedProof,account,dates.refund]);await user(4);await db.query('select charm.finance_review_accountability($1,true,null,true)',[returned]);
  const line=await scalar("select charm.finance_statement($1,$2,'OLDER-REFUND','in','15.00',$3)",[key(),account,dates.refund]);const ledger=await scalar('select id from charm.finance_ledger where accountability_id=$1',[returned]);await db.query('select charm.finance_match_statement($1,$2)',[line,ledger]);expect(await scalar("select (occurred_at at time zone 'Africa/Nairobi')::date::text from charm.finance_cashbook where id=$1",[ledger])).toBe(dates.refund);
 });
 it('reapplies the reviewed compatibility bundle without changing completed records or exact balances',async()=>{
  await db.exec('reset role');const before=await scalar("select jsonb_agg(to_jsonb(l) order by id) from charm.finance_ledger l");
  await db.exec(readFileSync('supabase/finance-upgrade-reviewed.sql','utf8'));await db.exec(readFileSync('supabase/finance-upgrade-reviewed.sql','utf8'));
  expect(await scalar("select jsonb_agg(to_jsonb(l) order by id) from charm.finance_ledger l")).toEqual(before);expect(await scalar('select count(*)::int from charm.finance_categories')).toBe(7);expect(await scalar("select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='charm' and p.proname='finance_submit_accountability'")).toBe(1);
 });
 it('private evidence is owner-scoped, cannot be overwritten, and CSV cells cannot execute formulas',async()=>{
  await user(3);await expect(proof(request,'receipt',3)).rejects.toThrow();await user(2);await expect(proof(request,'support',2)).rejects.toThrow();expect((await db.query("update storage.objects set name='changed'")).affectedRows).toBe(0);
  expect(csvCell('=HYPERLINK("evil")')).toBe('"\'=HYPERLINK(""evil"")"');expect(csvCell('  +CMD')).toBe('"\'  +CMD"');expect(csvCell('KES 1.00')).toBe('"KES 1.00"');
 });
});

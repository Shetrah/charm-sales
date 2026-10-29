// Local-only integration bridge. Executes real migrations/RLS in PGlite; not a production Auth/PostgREST implementation.
import {createServer} from 'node:http';
import {readFileSync,readdirSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
create schema auth;create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth to authenticated;grant execute on function auth.uid() to authenticated;
create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text,unique(bucket_id,name));alter table storage.objects enable row level security;grant usage on schema storage to authenticated;grant select,insert,update,delete on storage.objects to authenticated;`);
for(const file of readdirSync('supabase/migrations').sort())await db.exec(readFileSync(`supabase/migrations/${file}`,'utf8'));
const accounts=[{id:'00000000-0000-4000-8000-000000000001',email:'admin@test.invalid',name:'Test Admin',role:'admin'},{id:'00000000-0000-4000-8000-000000000002',email:'sales@test.invalid',name:'Test Salesperson',role:'salesperson'},{id:'00000000-0000-4000-8000-000000000003',email:'removable@test.invalid',name:'Test Removable',role:'salesperson'},{id:'00000000-0000-4000-8000-000000000004',email:'manager@test.invalid',name:'Test Finance Manager',role:'finance_officer'},{id:'00000000-0000-4000-8000-000000000005',email:'officer@test.invalid',name:'Test Finance Officer',role:'finance_officer'},{id:'00000000-0000-4000-8000-000000000006',email:'auditor@test.invalid',name:'Test Auditor',role:'salesperson'}];
for(const [i,u] of accounts.entries()){
 await db.query('insert into auth.users values($1,$2)',[u.id,u.email]);
 await db.query('insert into charm.users(id,name,email,password,role) values($1,$2,$3,\'test-only\',$4)',[i+1,u.name,u.email,u.role]);
 await db.query('insert into charm.auth_accounts(auth_user_id,salesperson_id) values($1,$2)',[u.id,i+1]);
}
await db.exec("insert into charm.clients(salesperson_id,name,contact,location) values(2,'Integration Client','Test contact','Nairobi')");
await db.exec("select setval(pg_get_serial_sequence('charm.users','id'),(select max(id) from charm.users))");
const passwords=new Map(accounts.map(account=>[account.id,'test-password-123']));
let queue=Promise.resolve();
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'*','Access-Control-Allow-Methods':'GET,POST,PUT,OPTIONS','Access-Control-Expose-Headers':'Content-Range','Content-Type':'application/json'};
createServer((req,res)=>{queue=queue.then(async()=>{
 const send=(status,body,headers={})=>{res.writeHead(status,{...cors,...headers});res.end(JSON.stringify(body));};
 if(req.method==='OPTIONS'){send(200,{});return;}
 const url=new URL(req.url,'http://127.0.0.1:54329');let raw='';for await(const chunk of req)raw+=chunk;const body=raw&&req.headers['content-type']?.includes('application/json')?JSON.parse(raw):{};
 const bearer=req.headers.authorization?.replace(/^Bearer /,'');let user=accounts.find(u=>u.id===bearer);
 if(url.pathname==='/health'){send(200,{ready:true});return;}
 if(url.pathname==='/auth/v1/token'){
  user=accounts.find(u=>u.email===body.email);if(!user||body.password!==passwords.get(user.id)){send(400,{msg:'Invalid login credentials'});return;}
  send(200,{access_token:user.id,refresh_token:'test-refresh',expires_in:3600,token_type:'bearer',user:{...user,aud:'authenticated',created_at:new Date().toISOString()}});return;
 }
 if(url.pathname==='/auth/v1/logout'){send(200,{});return;}
 if(url.pathname==='/auth/v1/user'){if(user&&req.method==='PUT'&&typeof body.password==='string')passwords.set(user.id,body.password);send(user?200:401,user??{msg:'Unauthorized'});return;}
 if(!user){send(401,{message:'unauthorized'});return;}
 try{
  await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user.id]);await db.exec('set role authenticated');
  if(url.pathname==='/functions/v1/add-staff'){
   const check=await db.query('select charm.is_admin() as allowed');if(!check.rows[0].allowed){send(403,{error:'forbidden'});return;}
   if(!['admin','salesperson','finance_officer'].includes(body.role)||typeof body.password!=='string'||body.password.length<12){send(422,{error:'invalid'});return;}
   if(accounts.some(account=>account.email===body.email)){send(409,{error:'staffExists'});return;}
   const account={id:crypto.randomUUID(),email:body.email,name:body.name,role:body.role};
   await db.exec('reset role');await db.query('insert into auth.users values($1,$2)',[account.id,account.email]);await db.exec('set role service_role');
   const linked=await db.query('select charm.link_staff($1,$2,$3,$4,$5) as id',[user.id,account.id,account.email,account.name,account.role]);
   accounts.push(account);passwords.set(account.id,body.password);send(200,{id:linked.rows[0].id});return;
  }
  if(url.pathname.startsWith('/storage/v1/object/')){
   const parts=url.pathname.split('/').slice(4);const signed=parts[0]==='sign';if(signed)parts.shift();const bucket=parts.shift();const name=decodeURIComponent(parts.join('/'));
   if(signed){const result=await db.query('select name from storage.objects where bucket_id=$1 and name=$2',[bucket,name]);if(!result.rows.length)throw Error('forbidden');send(200,{signedURL:'/object/sign/'+bucket+'/'+name+'?token=test-only'});return;}
   await db.query('insert into storage.objects(bucket_id,name) values($1,$2)',[bucket,name]);send(200,{Id:'test-storage-id',Key:bucket+'/'+name});return;
  }
  if(url.pathname.startsWith('/rest/v1/rpc/')){
   const fn=url.pathname.split('/').pop();if(!/^[a-z_]+$/.test(fn))throw Error('invalid');
   const keys=Object.keys(body);if(keys.some(k=>!/^p_[a-z_]+$/.test(k)))throw Error('invalid');
   const params=keys.map(k=>typeof body[k]==='object'&&body[k]!==null?JSON.stringify(body[k]):body[k]);
   const args=keys.map((k,i)=>`${k} => $${i+1}`).join(',');
   const listed=['product_price_book','product_price_history','sales_atp','sales_credit_status'].includes(fn);
   if(listed){const rows=await db.query(`select * from charm.${fn}(${args})`,params);send(200,rows.rows);return;}
   const data=await db.query(`select charm.${fn}(${args}) as result`,params);
   send(200,data.rows[0].result);return;
  }
  const table=url.pathname.split('/').pop();if(!['users','team_directory','clients','products','product_prices','quotation_batches','quotation_rows','orders','order_items','order_documents','order_contract_versions','payments','order_balances','visits','visit_exceptions','plans','plan_stops','expenses','travel_request_items','travel_request_documents','travel_policy','reports','workdays','location_points','audit_logs','finance_notifications','finance_requests','finance_disbursements','management_reports','management_report_versions','attendance_policy','attendance_days','leave_types','leave_requests','client_assignments','commission_rules','commission_tiers','commission_entries','sales_deliveries','sales_delivery_items'].includes(table))throw Error('invalid');
  const columns=url.searchParams.get('select')??'*';if(!/^[a-z_,*]+$/.test(columns))throw Error('invalid');
  const params=[],conditions=[];
  for(const [k,v] of url.searchParams.entries())if(!['select','order','offset','limit','or'].includes(k)){
   if(!/^[a-z_]+$/.test(k))throw Error('invalid');
   if(v==='is.null'){conditions.push(`${k} is null`);continue;}
   if(v.startsWith('in.(')&&v.endsWith(')')){const entries=v.slice(4,-1).split(',');const refs=entries.map(entry=>{params.push(entry);return '$'+params.length;});conditions.push(`${k} in (${refs.join(',')})`);continue;}
   const match=/^(eq|lt|lte|gt|gte)\.(.*)$/.exec(v);if(!match)throw Error('invalid');
   const operators={eq:'=',lt:'<',lte:'<=',gt:'>',gte:'>='};params.push(['active','needs_review'].includes(k)?match[2]==='true':match[2]);conditions.push(`${k}${operators[match[1]]}$${params.length}`);
  }
  const where=conditions.length?' where '+conditions.join(' and '):'';
  const orders=(url.searchParams.get('order')??'id.asc').split(',').map(s=>{const [col,direction]=s.split('.');if(!/^[a-z_]+$/.test(col)||!['asc','desc'].includes(direction))throw Error('invalid');return `${col} ${direction}`;}).join(',');
  const count=await db.query(`select count(*)::int as n from charm.${table}${where}`,params);
  if(req.method==='HEAD'){res.writeHead(200,{...cors,'Content-Range':`*/${count.rows[0].n}`});res.end();return;}
  const offset=Math.max(0,Number(url.searchParams.get('offset')??0)),limit=Math.min(200,Math.max(1,Number(url.searchParams.get('limit')??20)));
  const result=await db.query(`select ${columns} from charm.${table}${where} order by ${orders} limit ${limit} offset ${offset}`,params);
  const single=req.headers.accept?.includes('vnd.pgrst.object');
  send(200,single?result.rows[0]:result.rows,{'Content-Range':`${offset}-${offset+result.rows.length-1}/${count.rows[0].n}`});
 }catch(e){console.error('Test bridge:',url.pathname,e.message);send(400,{message:e.message,code:'test_error'});}
}).catch(e=>{res.writeHead(500,cors);res.end(JSON.stringify({message:e.message}));});}).listen(54329,'127.0.0.1');

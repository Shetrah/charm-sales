import { createClient } from 'npm:@supabase/supabase-js@2';
const allowed=(Deno.env.get('ALLOWED_ORIGINS')??'http://localhost:5173,http://127.0.0.1:5173,https://charm-sales.vercel.app,https://sales.charmkenya.com').split(',').map(s=>s.trim());
Deno.serve(async req=>{
 const origin=req.headers.get('origin')??'';
 const headers={'Access-Control-Allow-Origin':allowed.includes(origin)?origin:allowed[0],'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin','Content-Type':'application/json'};
 const reply=(status:number,error:unknown)=>new Response(JSON.stringify(error),{status,headers});
 if(origin&&!allowed.includes(origin))return reply(403,{error:'forbidden'});
 if(req.method==='OPTIONS')return new Response(null,{headers});
 if(req.method!=='POST')return reply(405,{error:'invalid'});
 const url=Deno.env.get('SUPABASE_URL')!;
 const token=req.headers.get('authorization')?.replace(/^Bearer\s+/i,'');
 if(!token)return reply(401,{error:'unauthorized'});
 const caller=createClient(url,Deno.env.get('SUPABASE_ANON_KEY')!,{db:{schema:'charm'},global:{headers:{Authorization:`Bearer ${token}`}},auth:{persistSession:false}});
 const {data:{user},error}=await caller.auth.getUser(token);
 if(error||!user)return reply(401,{error:'unauthorized'});
 const {data:admin,error:roleError}=await caller.rpc('is_admin');
 if(roleError||!admin)return reply(403,{error:'forbidden'});
 try{
  const {name,email,role,password}=await req.json();
  if(typeof name!=='string'||!name.trim()||name.length>200||typeof email!=='string'||email.length>254||!/^\S+@\S+\.\S+$/.test(email)||!['admin','salesperson','finance_officer'].includes(role)||typeof password!=='string'||password.length<12||password.length>128)return reply(422,{error:'invalid'});
  const service=createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{db:{schema:'charm'},auth:{persistSession:false}});
  // Credentials go directly to Supabase Auth. Never log or store the password in business tables.
  const created=await service.auth.admin.createUser({email:email.trim().toLowerCase(),password,email_confirm:true});
  if(created.error||!created.data.user)return reply(409,{error:['email_exists','user_already_exists'].includes(created.error?.code??'')?'staffExists':'linkFailed'});
  const linked=await service.rpc('link_staff',{p_actor:user.id,p_auth:created.data.user.id,p_name:name,p_email:email,p_role:role});
  if(linked.error){
   // Preserve Auth on an uncertain RPC response. Deletion could race a committed staff link.
   // An unmapped account cannot access company data; Admin can reconcile the verified email.
   return reply(409,{error:'linkFailed'});
  }
  return reply(200,{id:linked.data});
 }catch{return reply(400,{error:'invalid'});}
});

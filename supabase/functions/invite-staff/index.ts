import { createClient } from 'npm:@supabase/supabase-js@2';
const allowed = (Deno.env.get('ALLOWED_ORIGINS') ?? 'http://localhost:5173,http://127.0.0.1:5173,https://sales.charmkenya.com').split(',');
Deno.serve(async req => {
 const origin=req.headers.get('origin')??'';
 const headers={'Access-Control-Allow-Origin':allowed.includes(origin)?origin:'https://sales.charmkenya.com','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin','Content-Type':'application/json'};
 const response=(status:number,body:unknown)=>new Response(JSON.stringify(body),{status,headers});
 if(origin&&!allowed.includes(origin))return response(403,{error:'forbidden'});
 if(req.method==='OPTIONS')return new Response(null,{headers});
 if(req.method!=='POST')return response(405,{error:'invalid'});
 const url=Deno.env.get('SUPABASE_URL')!;
 const key=Deno.env.get('SUPABASE_ANON_KEY')!;
 const token=req.headers.get('authorization')?.replace(/^Bearer\s+/i,'');
 if(!token)return response(401,{error:'unauthorized'});
 const caller=createClient(url,key,{db:{schema:'charm'},global:{headers:{Authorization:`Bearer ${token}`}},auth:{persistSession:false}});
 const {data:{user},error:authError}=await caller.auth.getUser(token);
 if(authError||!user)return response(401,{error:'unauthorized'});
 const {data:admin,error:roleError}=await caller.rpc('is_admin');
 if(roleError||!admin)return response(403,{error:'forbidden'});
 try {
  const body=await req.json();const {name,email,role}=body;
  if(typeof name!=='string'||!name.trim()||name.length>200||typeof email!=='string'||email.length>254||!/^\S+@\S+\.\S+$/.test(email)||!['salesperson','admin'].includes(role))return response(422,{error:'invalid'});
  const service=createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{db:{schema:'charm'},auth:{persistSession:false}});
  const redirectTo=Deno.env.get('AUTH_REDIRECT_URL')??'https://sales.charmkenya.com/auth/callback';
  const {data,error}=await service.auth.admin.inviteUserByEmail(email.trim().toLowerCase(),{redirectTo});
  if(error||!data.user)return response(409,{error:'linkFailed'});
  const {data:id,error:linkError}=await service.rpc('link_staff',{p_actor:user.id,p_auth:data.user.id,p_email:email,p_name:name,p_role:role});
  // Keep the Auth account on failure; administrator can reconcile it without losing legacy records.
  if(linkError)return response(409,{error:'linkFailed'});
  return response(200,{id});
 }catch{return response(400,{error:'invalid'});}
});

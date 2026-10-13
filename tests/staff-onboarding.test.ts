import { describe, it, expect, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import ts from 'typescript';

function setup({admin=true,existing=false,linkError=false,alreadyLinked=false}={}){
 let handler!:(req:Request)=>Promise<Response>;
 const createUser=vi.fn(async()=>existing?{error:{code:'email_exists'},data:{user:null}}:{error:null,data:{user:{id:'new-auth-id'}}});
 const deleteUser=vi.fn(async()=>({error:null}));
 const caller={auth:{getUser:async()=>({data:{user:{id:'admin-auth-id'}},error:null})},rpc:async()=>({data:admin,error:null})};
 const rpc=vi.fn(async(name:string)=>name==='staff_auth_linked'?{data:alreadyLinked,error:null}:{data:linkError?null:42,error:linkError?{message:'link failure'}:null});
 const service={auth:{admin:{createUser,deleteUser}},rpc};
 const createClient=(_url:string,key:string)=>key==='service'?service:caller;
 const env={SUPABASE_URL:'https://test.invalid',SUPABASE_ANON_KEY:'public',SUPABASE_SERVICE_ROLE_KEY:'service'};
 const Deno={env:{get:(name:string)=>env[name as keyof typeof env]},serve:(fn:typeof handler)=>{handler=fn;}};
 const source=ts.transpileModule(readFileSync('supabase/functions/add-staff/index.ts','utf8').replace(/^import.*\n/,''),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
 new Function('createClient','Deno',source)(createClient,Deno);
 const send=(body:unknown,origin='https://charm-sales.vercel.app',token='test-token')=>handler(new Request('https://test.invalid/functions/v1/add-staff',{method:'POST',headers:{origin,authorization:token?`Bearer ${token}`:'','content-type':'application/json'},body:JSON.stringify(body)}));
 return {send,createUser,deleteUser,rpc};
}
const staff={name:'New employee',email:'new@test.invalid',role:'finance_officer',password:'temporary-test-password'};
describe('Admin temporary-password onboarding Edge handler',()=>{
 it('creates an immediately usable Auth account and links it without sending invitations',async()=>{
  const s=setup();const response=await s.send(staff);expect(response.status).toBe(200);expect(await response.json()).toEqual({id:42});
  expect(s.createUser).toHaveBeenCalledWith({email:staff.email,password:staff.password,email_confirm:true});
  expect(s.rpc).toHaveBeenCalledWith('link_staff',{p_actor:'admin-auth-id',p_auth:'new-auth-id',p_name:staff.name,p_email:staff.email,p_role:staff.role});
  expect(s.rpc.mock.calls.some(call=>JSON.stringify(call).includes(staff.password))).toBe(false);
 });
 it('rejects non-admins, foreign origins, missing tokens and invalid roles/passwords before creation',async()=>{
  const nonAdmin=setup({admin:false});expect((await nonAdmin.send(staff)).status).toBe(403);expect(nonAdmin.createUser).not.toHaveBeenCalled();
  const s=setup();expect((await s.send(staff,'https://foreign.invalid')).status).toBe(403);expect((await s.send(staff,undefined,'')).status).toBe(401);
  for(const body of [{...staff,password:'short'},{...staff,role:'finance_manager'}])expect((await s.send(body)).status).toBe(422);
  expect(s.createUser).not.toHaveBeenCalled();
 });
 it('preserves existing accounts and never deletes an account after an uncertain linking response',async()=>{
  const existing=setup({existing:true});expect(await (await existing.send(staff)).json()).toEqual({error:'staffExists'});expect(existing.deleteUser).not.toHaveBeenCalled();
  const failed=setup({linkError:true});expect((await failed.send(staff)).status).toBe(409);expect(failed.deleteUser).not.toHaveBeenCalled();
  const linked=setup({linkError:true,alreadyLinked:true});expect((await linked.send(staff)).status).toBe(409);expect(linked.deleteUser).not.toHaveBeenCalled();
 });
});

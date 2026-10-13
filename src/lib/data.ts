import { nairobiDate } from './dates';
export { nairobiDate } from './dates';
import { supabase } from './supabase';
export type Row=Record<string,any>;
export type Profile={id:number;name:string;role:'admin'|'salesperson';email:string;active:boolean};
export const tables:Record<string,string>={clients:'clients',products:'products',orders:'orders',payments:'payments',balances:'order_balances',visits:'visits',plans:'plans',expenses:'expenses',reports:'reports',routes:'workdays',staff:'team_directory',audit:'audit_logs'};
export const columns:Record<string,string[]>={
 clients:['id','name','contact','phone','location','salesperson_id'],products:['id','category','capacity','fragrance','barcode','carton','unit_price','needs_review'],orders:['id','client_id','salesperson_id','status','total','due_date','confirmed_at'],payments:['id','order_id','amount','reference','status','received_at'],balances:['id','client_id','salesperson_id','total','paid','balance','financial_status','due_date'],visits:['id','client_id','outcome','check_in_at','check_out_at','follow_up_date'],plans:['id','date','client_id','budget','notes','status'],expenses:['id','date','client_id','budget','notes','status'],reports:['id','date','notes','follow_up_date','status'],routes:['id','salesperson_id','date','started_at','ended_at'],staff:['id','name','email','role','active'],audit:['id','actor_id','action','entity','entity_id','created_at']};
const searchColumns:Record<string,string[]>={clients:['name','contact','phone','location'],products:['category','capacity','fragrance','barcode'],payments:['reference'],visits:['notes'],plans:['notes'],expenses:['notes'],reports:['notes'],staff:['name','email'],audit:['action','entity']};
export async function list(section:string,page:number,search:string,status:string,date:string,owner='',attention='') {
 if(!supabase) throw new Error('configuration');
 let query=supabase.from(tables[section]).select(section==='staff'?'id,name,email,role,active':'*',{count:'exact'}).order('id',{ascending:false}).range((page-1)*20,page*20-1);
 const clean=search.replace(/[,%().\\]/g,' ').trim().slice(0,100);
 if(clean && searchColumns[section]) query=query.or(searchColumns[section].map(c=>`${c}.ilike.%${clean}%`).join(','));
 else if(clean && /^\d+$/.test(clean)) query=query.eq('id',clean);
 if(status && ['orders','payments','plans','expenses','reports'].includes(section)) query=query.eq('status',status);
 if(date && ['routes','plans','expenses','reports'].includes(section)) query=query.eq('date',date);
 if(owner&&/^\d+$/.test(owner)&&!['staff','audit','products'].includes(section))query=query.eq(section==='payments'?'submitted_by':'salesperson_id',owner);
 if(attention==='overdue'&&section==='balances')query=query.gt('balance',0).lt('due_date',nairobiDate());
 if(attention==='followup'&&section==='visits')query=query.lte('follow_up_date',nairobiDate());
 const {data,error,count}=await query;if(error) throw new Error(section==='staff'&&error.code==='PGRST205'?'staffLifecycleSetup':error.message);return {rows:data as Row[],count:count??0};
}
export async function listRecord(section:string,id:string):Promise<Row>{
 if(!supabase)throw new Error('configuration');
 const {data,error}=await supabase.from(tables[section]).select(section==='staff'?'id,name,email,role,active':'*').eq('id',id).limit(1);
 if(error)throw new Error(error.message);if(!data?.[0])throw new Error('notFound');return data[0];
}
export async function lookup(kind:string,search:string):Promise<Row[]> {
 if(!supabase) return [];
 let q=supabase.from(kind==='users'?'team_directory':kind).select(kind==='users'?'id,name,role':kind==='products'?'id,category,capacity,fragrance,barcode,carton,unit_price':'*').order('id',{ascending:false}).limit(20);
 const clean=search.replace(/[,%().\\]/g,' ').trim().slice(0,100);
 if(kind==='orders') {q=q.eq('status','confirmed');if(/^\d+$/.test(clean)) q=q.eq('id',clean);}
 else if(clean) q=kind==='products'?q.or(['category','capacity','fragrance','barcode'].map(c=>`${c}.ilike.%${clean}%`).join(',')):q.ilike('name',`%${clean}%`);
 if(kind==='products'||kind==='users') q=q.eq('active',true);
 const {data,error}=await q;if(error) throw new Error(error.message);return data as Row[];
}

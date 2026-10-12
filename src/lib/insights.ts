import { supabase, rpc } from './supabase';
import { databaseError } from './errors';
import { nairobiDate, type Row } from './data';

import { reportingMonths } from './presentation';
export { reportingMonths } from './presentation';
export async function salesTrend(month:string) {
 return Promise.all(reportingMonths(month).map(async value=>({month:value,...await rpc<Row>('monthly_summary',{p_month:`${value}-01`})})));
}
export async function enrich(rows:Row[]):Promise<Row[]> {
 if(!rows.length||!supabase)return rows;
 const people=[...new Set(rows.flatMap(r=>[r.salesperson_id,r.submitted_by,r.actor_id,r.reviewed_by,r.confirmed_by,r.verified_by]).filter(Boolean))];
 const clients=[...new Set(rows.map(r=>r.client_id).filter(Boolean))];
 const [users,stores]=await Promise.all([
  people.length?supabase.from('users').select('id,name').in('id',people):Promise.resolve({data:[],error:null}),
  clients.length?supabase.from('clients').select('id,name').in('id',clients):Promise.resolve({data:[],error:null}),
 ]);
 if(users.error)throw databaseError(users.error);if(stores.error)throw databaseError(stores.error);
 const peopleMap=new Map(users.data?.map(r=>[String(r.id),r.name]));const clientMap=new Map(stores.data?.map(r=>[String(r.id),r.name]));
 return rows.map(r=>({...r,_people:Object.fromEntries(peopleMap),_client:clientMap.get(String(r.client_id))}));
}
export async function workload() {
 if(!supabase)throw new Error('configuration');
 const today=nairobiDate();
 const pending=['orders','payments','plans','expenses','reports'];
 const counts=await Promise.all(pending.map(async table=>{
  const {count,error}=await supabase!.from(table).select('id',{count:'exact',head:true}).eq('status','pending');
  if(error)throw databaseError(error);return [table,count??0] as const;
 }));
 const [overdue,followups,workdays,...feeds]=await Promise.all([
  supabase.from('order_balances').select('id',{count:'exact',head:true}).gt('balance',0).lt('due_date',today),
  supabase.from('visits').select('id',{count:'exact',head:true}).lte('follow_up_date',today),
  supabase.from('workdays').select('*').is('ended_at',null).order('id',{ascending:false}).limit(8),
  ...['orders','payments','visits','plans','expenses','reports'].map(table=>supabase!.from(table).select('*').order('updated_at',{ascending:false}).order('id',{ascending:false}).limit(5).then(result=>({...result,table}))),
 ]);
 for(const result of [overdue,followups,workdays,...feeds])if(result.error)throw databaseError(result.error);
 const activity=feeds.flatMap(r=>(r.data??[]).map(item=>({...item,_section:r.table}))).sort((a:Row,b:Row)=>new Date(b.updated_at??b.created_at).getTime()-new Date(a.updated_at??a.created_at).getTime()).slice(0,12);
 const active=workdays.data??[];
 const points=await Promise.all(active.map(async day=>{
  const {data,error}=await supabase!.from('location_points').select('latitude,longitude,accuracy_m,recorded_at').eq('workday_id',day.id).order('recorded_at',{ascending:false}).order('id',{ascending:false}).limit(1);
  if(error)throw databaseError(error);return {...day,_point:data?.[0]??null};
 }));
 const named=await enrich([...activity,...points]);
 return {counts:Object.fromEntries(counts),overdue:overdue.count??0,followups:followups.count??0,activity:named.slice(0,activity.length),workdays:named.slice(activity.length)};
}

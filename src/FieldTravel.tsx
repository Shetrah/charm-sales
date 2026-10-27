import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useSearchParams } from 'react-router-dom';
import { CheckCircle2, ChevronDown, ChevronUp, Clock3, FileText, MapPin, Plane, Plus, Receipt, Route, ShieldCheck, Trash2, X } from 'lucide-react';
import { Dialog, ErrorNotice, Field, Loading, Status } from './components';
import { usePreferences } from './i18n';
import { rpc, supabase } from './lib/supabase';
import { databaseError } from './lib/errors';
import { nairobiDate, type Profile, type Row } from './lib/data';
import { businessDateInput, businessDateTimeInput, businessInputToInstant, formatBusinessDate, formatBusinessDateTime } from './lib/dates';
import { formatMoney } from './finance';
import { documentExtension, openPrivateFile, prepareDocument, uploadPrivate } from './lib/documents';

const ALL_TABS = ['overview','itineraries','requests','approvals','history'] as const;
type Tab = typeof ALL_TABS[number];
const TRANSPORT = ['walk','public','boda','car','company_vehicle','air','other'];
const ITEM_KINDS = ['transport','accommodation','other'];
const OPEN_PLAN = ['draft','planned','in_progress','partially_completed'];
const CLOSED_PLAN = ['completed','partially_completed','cancelled'];
const PENDING_REQUEST = ['pending','pending_approval'];
const APPROVED_REQUEST = ['approved','in_progress','completed'];
const WAITING = ['pending','pending_approval','finance_review'];
const amount = (value: unknown) => Number(value ?? 0) || 0;
const dateOnly = (value: string | null | undefined, language: 'en' | 'zh') => value ? formatBusinessDate(value, language) : '—';
const dateTime = (value: string | null | undefined, language: 'en' | 'zh') => value ? formatBusinessDateTime(value, language) : '—';

type FieldData = {
 scope: string;
 profile: Profile;
 admin: boolean;
 plans: Row[];
 stops: Row[];
 requests: Row[];
 items: Row[];
 documents: Row[];
 clients: Row[];
 users: Row[];
 policy: Row | null;
 actual: Map<string, number>;
};

export default function FieldTravel({scope,profile,initial='overview'}:{scope:string;profile:Profile;initial?:Tab}) {
 const {t,language}=usePreferences();const qc=useQueryClient();const admin=profile.role==='admin';
 const [params,setParams]=useSearchParams();
 const requested=params.get('tab') as Tab|null;
 const available:Tab[]=admin?[...ALL_TABS]:ALL_TABS.filter(value=>value!=='approvals');
 const tab:Tab=requested&&available.includes(requested)?requested:available.includes(initial)?initial:'overview';
 const setTab=(next:Tab)=>setParams(next==='overview'?{}:{tab:next},{replace:true});
 const [selectedPlan,setSelectedPlan]=useState<number|null>(null);const [selectedRequest,setSelectedRequest]=useState<number|null>(null);
 const [editor,setEditor]=useState<{kind:'itinerary';id:number|null}|{kind:'request';id:number|null}|null>(null);
 const [decision,setDecision]=useState<{id:number;action:string}|null>(null);
 const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();const [notice,setNotice]=useState('');

 const plans=useQuery({queryKey:[scope,'field','plans'],queryFn:async()=>{const {data,error}=await supabase!.from('plans').select('*').order('date',{ascending:false}).order('id',{ascending:false}).limit(400);if(error)throw databaseError(error);return data as Row[];}});
 const stops=useQuery({queryKey:[scope,'field','stops'],queryFn:async()=>{const {data,error}=await supabase!.from('plan_stops').select('*').order('plan_id').order('sequence').limit(1500);if(error)throw databaseError(error);return data as Row[];}});
 const requests=useQuery({queryKey:[scope,'field','requests'],queryFn:async()=>{const {data,error}=await supabase!.from('expenses').select('*').order('id',{ascending:false}).limit(400);if(error)throw databaseError(error);return data as Row[];}});
 const items=useQuery({queryKey:[scope,'field','items'],queryFn:async()=>{const {data,error}=await supabase!.from('travel_request_items').select('*').order('request_id').order('id').limit(1500);if(error)throw databaseError(error);return data as Row[];}});
 const documents=useQuery({queryKey:[scope,'field','documents'],queryFn:async()=>{const {data,error}=await supabase!.from('travel_request_documents').select('*').order('request_id').order('id').limit(800);if(error)throw databaseError(error);return data as Row[];}});
 const clients=useQuery({queryKey:[scope,'field','clients'],queryFn:async()=>{const {data,error}=await supabase!.from('clients').select('id,name,salesperson_id').order('name').limit(500);if(error)throw databaseError(error);return data as Row[];}});
 const users=useQuery({queryKey:[scope,'field','users'],queryFn:async()=>{const {data,error}=await supabase!.from('users').select('id,name,role').order('name').limit(200);if(error)throw databaseError(error);return data as Row[];}});
 const policy=useQuery({queryKey:[scope,'field','policy'],queryFn:async()=>{const {data,error}=await supabase!.from('travel_policy').select('*').limit(1);if(error)throw databaseError(error);return (data?.[0] as Row|undefined)??null;}});
 const finance=useQuery({queryKey:[scope,'field','finance'],enabled:admin,retry:false,queryFn:async()=>{
  const [funding,payments]=await Promise.all([supabase!.from('finance_requests').select('id,source_expense_id'),supabase!.from('finance_disbursements').select('request_id,amount')]);
  if(funding.error)throw databaseError(funding.error);if(payments.error)throw databaseError(payments.error);
  const source=new Map<string,string>((funding.data??[]).filter(row=>row.source_expense_id!=null).map(row=>[String(row.id),String(row.source_expense_id)]));
  const totals=new Map<string,number>();
  for(const payment of payments.data??[]){const expense=source.get(String(payment.request_id));if(!expense)continue;totals.set(expense,(totals.get(expense)??0)+amount(payment.amount));}
  return totals;
 }});

 const loading=[plans,stops,requests,items,documents,clients,users,policy].find(query=>query.isPending);
 const failure=[plans,stops,requests,items,documents,clients,users,policy].find(query=>query.isError);
 const data:FieldData={scope,profile,admin,plans:plans.data??[],stops:stops.data??[],requests:requests.data??[],items:items.data??[],documents:documents.data??[],clients:clients.data??[],users:users.data??[],policy:policy.data??null,actual:finance.data??new Map()};
 const {planById,requestById,clientById,userById,docsByRequest,itemsByRequest}=useMemo(()=>{
  const planById=new Map<string,Row>(data.plans.map(row=>[String(row.id),row]));
  const requestById=new Map<string,Row>(data.requests.map(row=>[String(row.id),row]));
  const clientById=new Map<string,Row>(data.clients.map(row=>[String(row.id),row]));
  const userById=new Map<string,Row>(data.users.map(row=>[String(row.id),row]));
  const docsByRequest=new Map<string,Row[]>();for(const doc of data.documents){const key=String(doc.request_id);docsByRequest.set(key,[...(docsByRequest.get(key)??[]),doc]);}
  const itemsByRequest=new Map<string,Row[]>();for(const item of data.items){const key=String(item.request_id);itemsByRequest.set(key,[...(itemsByRequest.get(key)??[]),item]);}
  return {planById,requestById,clientById,userById,docsByRequest,itemsByRequest};
 },[data.plans,data.requests,data.clients,data.users,data.documents,data.items]);

 const stopsByPlan=useMemo(()=>{const map=new Map<string,Row[]>();for(const stop of data.stops){const key=String(stop.plan_id);map.set(key,[...(map.get(key)??[]),stop]);}return map;},[data.stops]);
 const plansByRequest=useMemo(()=>{const map=new Map<string,Row[]>();for(const plan of data.plans){if(plan.travel_request_id==null)continue;const key=String(plan.travel_request_id);map.set(key,[...(map.get(key)??[]),plan]);}return map;},[data.plans]);

 const refresh=async(message:string)=>{setEditor(null);setDecision(null);await qc.invalidateQueries({queryKey:[scope,'field']});setNotice(t(message));setTimeout(()=>setNotice(''),4500);};
 async function run(action:()=>Promise<unknown>,message:string){setBusy(true);setError(undefined);try{await action();await refresh(message);}catch(next){setError(next);}finally{setBusy(false);}}

 const today=nairobiDate();
 const activeStops=data.stops.filter(stop=>stop.status!=='cancelled');
 const todayPlans=data.plans.filter(plan=>plan.date===today&&OPEN_PLAN.includes(plan.status));
 const todayStops=activeStops.filter(stop=>planById.get(String(stop.plan_id))?.date===today);
 const pending=data.requests.filter(request=>WAITING.includes(request.status));
 const returned=data.requests.filter(request=>['returned','rejected'].includes(request.status));
 const upcoming=data.plans.filter(plan=>plan.date>=today&&['planned','in_progress','partially_completed'].includes(plan.status));
 const approvedTrips=data.requests.filter(request=>['approved','in_progress'].includes(request.status)&&(!request.return_at||request.return_at>=new Date().toISOString()));
 const completedStops=activeStops.filter(stop=>stop.visit_id!=null).length;
 const plannedStops=activeStops.length;
 const estimatedTotal=data.requests.filter(request=>request.status!=='draft').reduce((sum,row)=>sum+amount(row.total_estimated),0);
 const approvedTotal=data.requests.filter(request=>APPROVED_REQUEST.includes(request.status)).reduce((sum,row)=>sum+amount(row.total_estimated),0);
 const actualTotal=[...data.actual.values()].reduce((sum,value)=>sum+value,0);
 const recent=[...data.plans.map(row=>({kind:'itinerary' as const,row})),...data.requests.map(row=>({kind:'request' as const,row}))].sort((a,b)=>new Date(b.row.updated_at??b.row.created_at).getTime()-new Date(a.row.updated_at??a.row.created_at).getTime()).slice(0,8);

 const heading:Record<Tab,string>={overview:'field',itineraries:'plans',requests:'expenses',approvals:'fieldApprovals',history:'fieldHistory'};
 const intro:Record<Tab,string>={overview:'overviewIntro',itineraries:'itinerariesIntro',requests:'requestsIntro',approvals:'approvalsIntro',history:'historyIntro'};
 return <main className="content field-travel">
  <div className="page-heading"><div><span className="eyebrow">CHARM KENYA · {t('businessTimeZone')}</span><h1>{t(heading[tab])}</h1><p>{t(intro[tab])}</p></div>{tab==='itineraries'&&<button className="primary" onClick={()=>setEditor({kind:'itinerary',id:null})}><Plus size={18}/>{t('newItinerary')}</button>}{tab==='requests'&&<button className="primary" onClick={()=>setEditor({kind:'request',id:null})}><Plus size={18}/>{t('newTravelRequest')}</button>}</div>
  <nav className="field-tabs" role="tablist" aria-label={t('field')}>
   {available.map(value=><button type="button" role="tab" aria-selected={tab===value} key={value} className={tab===value?'active':''} onClick={()=>setTab(value)}>{value==='overview'?<MapPin size={16}/>:value==='itineraries'?<Route size={16}/>:value==='requests'?<Receipt size={16}/>:value==='approvals'?<ShieldCheck size={16}/>:<Clock3 size={16}/>}<span>{t(value==='overview'?'fieldOverview':value==='itineraries'?'fieldItineraries':value==='requests'?'fieldRequests':value==='approvals'?'fieldApprovals':'fieldHistory')}</span>{value==='approvals'&&pending.length>0&&<em>{pending.length}</em>}</button>)}
  </nav>
  <p className="field-timezone"><Clock3 size={14}/>{t('timeZoneNote')}</p>
  {!!notice&&<div className="notice" role="status">{notice}</div>}{!!error&&<ErrorNotice error={error} retry={()=>setError(undefined)}/>}
  {loading?<Loading/>:failure?<ErrorNotice error={failure.error} retry={()=>{loadingQuery(failure);}}/>:<>
   {tab==='overview'&&<section className="field-overview">
    <div className="field-cards">
     <button type="button" className="card field-card" onClick={()=>setTab('itineraries')}><span className="eyebrow">{t('todayPlanned')}</span><strong>{todayStops.length}</strong><small>{todayPlans.length} {t('fieldItineraries').toLowerCase()} · {today}</small><MapPin size={19}/></button>
     <button type="button" className="card field-card" onClick={()=>setTab('history')}><span className="eyebrow">{t('completedVisits')}</span><strong>{completedStops}/{plannedStops}</strong><small>{t('completionRate')}: {plannedStops?Math.round(completedStops/plannedStops*100):0}%</small><CheckCircle2 size={19}/></button>
     <button type="button" className="card field-card" onClick={()=>setTab(admin?'approvals':'requests')}><span className="eyebrow">{t('pendingApprovals')}</span><strong>{pending.length}</strong><small>{data.requests.filter(row=>row.status==='finance_review').length} {t('awaitingFinance')}</small><ShieldCheck size={19}/></button>
     <button type="button" className="card field-card" onClick={()=>setTab('requests')}><span className="eyebrow">{t('approvedUpcoming')}</span><strong>{approvedTrips.length}</strong><small>{t('estimatedCost')}: {formatMoney(approvedTotal,language)}</small><Plane size={19}/></button>
    </div>
    {returned.length>0&&<div className="notice field-action-note"><strong>{t('returnedNeedingAction')}</strong><span>{returned.slice(0,3).map(row=>`#${row.id} ${row.destination??''}`).join(' · ')}</span><button type="button" className="text-button" onClick={()=>setTab('requests')}>{t('openRequest')}</button></div>}
    <div className="field-columns">
     <section className="card field-list-card"><header><h2>{t('upcomingItineraries')}</h2><button type="button" className="text-button" onClick={()=>setTab('itineraries')}>{t('fieldItineraries')}</button></header>{upcoming.length===0?<p className="field-empty">{t('noItineraries')}</p>:<div className="field-rows">{upcoming.slice(0,6).map(plan=>{const stopsFor=stopsByPlan.get(String(plan.id))??[];const active=stopsFor.filter(stop=>stop.status!=='cancelled');return <button type="button" className="field-row" key={plan.id} onClick={()=>setSelectedPlan(Number(plan.id))}><div><strong>{plan.title||`#${plan.id}`}</strong><span>{dateOnly(plan.date,language)} · {plan.start_location||t('notSpecified')} · {active.filter(stop=>stop.visit_id!=null).length}/{active.length} {t('completedVisits').toLowerCase()}</span></div><Status value={plan.status}/></button>;})}</div>}</section>
     <section className="card field-list-card"><header><h2>{t('recentActivity')}</h2><span className="small-label">{t('businessTimeZone')}</span></header>{recent.length===0?<p className="field-empty">{t('noActivity')}</p>:<div className="field-rows">{recent.map(entry=><button type="button" className="field-row" key={`${entry.kind}-${entry.row.id}`} onClick={()=>entry.kind==='itinerary'?setSelectedPlan(Number(entry.row.id)):setSelectedRequest(Number(entry.row.id))}><div><strong>{entry.kind==='itinerary'?entry.row.title||`#${entry.row.id}`:entry.row.purpose||`#${entry.row.id}`}</strong><span>{entry.kind==='itinerary'?`${t('fieldItineraries')} · ${dateOnly(entry.row.date,language)}`:`${t('travelRequest')} · ${entry.row.origin??''} → ${entry.row.destination??''}`} · {dateTime(entry.row.updated_at??entry.row.created_at,language)}</span></div><Status value={entry.row.status}/></button>)}</div>}</section>
    </div>
    <section className="card field-list-card"><header><h2>{t('estimatedVsActual')}</h2><span className="small-label">{t('businessTimeZone')}</span></header><div className="field-money"><div><span>{t('estimatedCost')}</span><strong>{formatMoney(estimatedTotal,language)}</strong></div><div><span>{t('approvedCost')}</span><strong>{formatMoney(approvedTotal,language)}</strong></div>{admin&&<div><span>{t('actualCost')}</span><strong>{formatMoney(actualTotal,language)}</strong></div>}</div><p className="field-note">{t('actualCostHint')}</p></section>
   </section>}

   {tab==='itineraries'&&<section className="card field-list-card">
    {data.plans.length===0?<div className="state"><Route size={34}/><h3>{t('noItineraries')}</h3><p>{t('itinerariesIntro')}</p><button className="primary" onClick={()=>setEditor({kind:'itinerary',id:null})}>{t('newItinerary')}</button></div>:<div className="field-records">{data.plans.map(plan=>{const stopsFor=(stopsByPlan.get(String(plan.id))??[]).filter(stop=>stop.status!=='cancelled');const done=stopsFor.filter(stop=>stop.visit_id!=null).length;const request=plan.travel_request_id?requestById.get(String(plan.travel_request_id)):undefined;const owner=userById.get(String(plan.salesperson_id))?.name??`#${plan.salesperson_id}`;return <article className="field-record" key={plan.id}>
     <header><div><span className="eyebrow">{dateOnly(plan.date,language)} · {owner}</span><h3>{plan.title||`${t('itineraryTitle')} #${plan.id}`}</h3></div><Status value={plan.status}/></header>
     <div className="field-meta"><span><MapPin size={14}/>{plan.start_location||t('notSpecified')}</span><span><Route size={14}/>{TRANSPORT.includes(plan.transport_mode)?t(plan.transport_mode):t('notSpecified')}</span><span><Clock3 size={14}/>{plan.expected_duration_minutes?`${plan.expected_duration_minutes} min`:t('notSpecified')}</span></div>
     <div className="field-progress"><span>{t('plannedVisits')} <strong>{stopsFor.length}</strong></span><span>{t('completedVisits')} <strong>{done}</strong></span><span>{t('outstandingVisits')} <strong>{stopsFor.length-done}</strong></span><span>{t('linkedTravelRequest')} <strong>{request?`#${request.id} · ${t(request.status)}`:'—'}</strong></span></div>
     <div className="field-record-actions"><button type="button" onClick={()=>setSelectedPlan(Number(plan.id))}>{t('openItinerary')}</button>{(OPEN_PLAN.includes(plan.status)&&(admin||plan.salesperson_id===profile.id))&&<button type="button" onClick={()=>setEditor({kind:'itinerary',id:Number(plan.id)})}>{t('editItinerary')}</button>}{request&&<button type="button" onClick={()=>setSelectedRequest(Number(request.id))}>{t('openRequest')}</button>}</div>
    </article>;})}</div>}
   </section>}

   {tab==='requests'&&<section className="card field-list-card">
    {data.requests.length===0?<div className="state"><Receipt size={34}/><h3>{t('noRequests')}</h3><p>{t('requestsIntro')}</p><button className="primary" onClick={()=>setEditor({kind:'request',id:null})}>{t('newTravelRequest')}</button></div>:<div className="field-records">{data.requests.map(request=>{const lines=itemsByRequest.get(String(request.id))??[];const linked=plansByRequest.get(String(request.id))??[];const owner=userById.get(String(request.salesperson_id))?.name??`#${request.salesperson_id}`;const editable=['draft','returned','pending'].includes(request.status)&&(admin||request.salesperson_id===profile.id);return <article className="field-record" key={request.id}>
     <header><div><span className="eyebrow">#{request.id} · {owner} · {dateOnly(request.date,language)}</span><h3>{request.purpose||t('travelRequest')}</h3></div><Status value={request.status}/></header>
     <div className="field-route"><strong>{request.origin||'—'}</strong><span>→</span><strong>{request.destination||'—'}</strong></div>
     <div className="field-meta"><span><Clock3 size={14}/>{dateTime(request.depart_at,language)}</span><span><Clock3 size={14}/>{dateTime(request.return_at,language)}</span>{request.advance_required&&<span><Receipt size={14}/>{t('advanceRequired')}</span>}</div>
     <div className="field-progress"><span>{t('totalEstimated')} <strong>{formatMoney(request.total_estimated,language)}</strong></span><span>{t('requestItems')} <strong>{lines.length}</strong></span><span>{t('linkedItineraries')} <strong>{linked.length}</strong></span></div>
     {request.decision_reason&&<p className="field-rejection">{t('decisionReason')}: {request.decision_reason}</p>}
     <div className="field-record-actions"><button type="button" onClick={()=>setSelectedRequest(Number(request.id))}>{t('openRequest')}</button>{editable&&<button type="button" onClick={()=>setEditor({kind:'request',id:Number(request.id)})}>{t('editTravelRequest')}</button>}{editable&&request.status!=='pending'&&<button type="button" disabled={busy} onClick={()=>run(()=>rpc('submit_travel_request',{p_id:request.id}),'requestSubmitted')}>{t('submitRequest')}</button>}{admin&&(PENDING_REQUEST.includes(request.status)||request.status==='finance_review')&&<button type="button" className="primary" onClick={()=>setDecision({id:Number(request.id),action:request.status==='finance_review'?'finance-approve':'approve'})}>{t('fieldApprovals')}</button>}</div>
    </article>;})}</div>}
   </section>}

   {tab==='approvals'&&admin&&<div className="field-columns">
    <section className="card field-list-card"><header><h2>{t('pendingApprovals')}</h2><span className="small-label">{t('businessTimeZone')}</span></header>{pending.length===0?<p className="field-empty">{t('noApprovals')}</p>:<div className="field-rows">{pending.map(request=>{const owner=userById.get(String(request.salesperson_id))?.name??`#${request.salesperson_id}`;return <div className="field-row static" key={request.id}><div><strong>{request.purpose||`#${request.id}`} · {formatMoney(request.total_estimated,language)}</strong><span>{owner} · {request.origin} → {request.destination} · {dateTime(request.depart_at,language)}</span></div><Status value={request.status}/><div className="field-decision-actions"><button type="button" onClick={()=>setSelectedRequest(Number(request.id))}>{t('details')}</button><button type="button" className="primary" onClick={()=>setDecision({id:Number(request.id),action:request.status==='finance_review'?'finance-approve':'approve'})}>{request.status==='finance_review'?t('financeApprove'):t('approve')}</button><button type="button" onClick={()=>setDecision({id:Number(request.id),action:request.status==='finance_review'?'finance-reject':'return'})}>{request.status==='finance_review'?t('financeReject'):t('returnRequest')}</button>{request.status!=='finance_review'&&<button type="button" onClick={()=>setDecision({id:Number(request.id),action:'reject'})}>{t('rejectRequest')}</button>}</div></div>;})}</div>}</section>
    <section className="card field-list-card"><header><h2>{t('travelPolicy')}</h2></header><PolicyEditor policy={data.policy} onSaved={()=>refresh('policySaved')}/><p className="field-note">{t('notificationScope')}</p></section>
   </div>}

   {tab==='history'&&<div className="field-columns">
    <section className="card field-list-card"><header><h2>{t('historyItineraries')}</h2></header>{data.plans.filter(plan=>CLOSED_PLAN.includes(plan.status)).length===0?<p className="field-empty">{t('noHistory')}</p>:<div className="field-rows">{data.plans.filter(plan=>CLOSED_PLAN.includes(plan.status)).map(plan=>{const stopsFor=(stopsByPlan.get(String(plan.id))??[]).filter(stop=>stop.status!=='cancelled');return <button type="button" className="field-row" key={plan.id} onClick={()=>setSelectedPlan(Number(plan.id))}><div><strong>{plan.title||`#${plan.id}`}</strong><span>{dateOnly(plan.date,language)} · {stopsFor.filter(stop=>stop.visit_id!=null).length}/{stopsFor.length} {t('completedVisits').toLowerCase()}</span></div><Status value={plan.status}/></button>;})}</div>}</section>
    <section className="card field-list-card"><header><h2>{t('historyRequests')}</h2></header>{data.requests.filter(request=>['completed','cancelled','rejected'].includes(request.status)).length===0?<p className="field-empty">{t('noHistory')}</p>:<div className="field-rows">{data.requests.filter(request=>['completed','cancelled','rejected'].includes(request.status)).map(request=><button type="button" className="field-row" key={request.id} onClick={()=>setSelectedRequest(Number(request.id))}><div><strong>{request.purpose||`#${request.id}`}</strong><span>{request.origin} → {request.destination} · {formatMoney(request.total_estimated,language)} · {dateTime(request.decided_at,language)}</span></div><Status value={request.status}/></button>)}</div>}</section>
   </div>}
  </>}
  {editor?.kind==='itinerary'&&<ItineraryEditor scope={scope} profile={profile} plan={editor.id?planById.get(String(editor.id))??null:null} planStops={editor.id?(stopsByPlan.get(String(editor.id))??[]).filter(stop=>stop.status!=='cancelled'):[]} clients={data.clients} requests={data.requests} onClose={()=>setEditor(null)} onSaved={refresh}/>}
  {editor?.kind==='request'&&<RequestEditor scope={scope} profile={profile} request={editor.id?requestById.get(String(editor.id))??null:null} items={editor.id?itemsByRequest.get(String(editor.id))??[]:[]} plans={data.plans} clients={data.clients} onClose={()=>setEditor(null)} onSaved={refresh}/>}
  {selectedPlan!=null&&planById.get(String(selectedPlan))&&<ItineraryDetail plan={planById.get(String(selectedPlan))!} stops={stopsByPlan.get(String(selectedPlan))??[]} request={planById.get(String(selectedPlan))!.travel_request_id?requestById.get(String(planById.get(String(selectedPlan))!.travel_request_id))??null:null} clientById={clientById} profile={profile} admin={admin} busy={busy} onClose={()=>setSelectedPlan(null)} onEdit={()=>{setEditor({kind:'itinerary',id:selectedPlan});setSelectedPlan(null);}} onOpenRequest={id=>{setSelectedPlan(null);setSelectedRequest(id);}} onRun={run}/>}
  {selectedRequest!=null&&requestById.get(String(selectedRequest))&&<RequestDetail scope={scope} request={requestById.get(String(selectedRequest))!} items={itemsByRequest.get(String(selectedRequest))??[]} documents={docsByRequest.get(String(selectedRequest))??[]} plans={plansByRequest.get(String(selectedRequest))??[]} client={clientById.get(String(requestById.get(String(selectedRequest))!.client_id))} profile={profile} admin={admin} busy={busy} onClose={()=>setSelectedRequest(null)} onEdit={()=>{setEditor({kind:'request',id:selectedRequest});setSelectedRequest(null);}} onDecide={action=>setDecision({id:selectedRequest!,action})} onRun={run} onRefresh={()=>qc.invalidateQueries({queryKey:[scope,'field']})}/>}
  {decision&&requestById.get(String(decision.id))&&<DecisionDialog request={requestById.get(String(decision.id))!} action={decision.action} onClose={()=>setDecision(null)} onSaved={refresh}/>}
 </main>;
}

function loadingQuery(query:{refetch:()=>unknown}){void query.refetch();}

function PolicyEditor({policy,onSaved}:{policy:Row|null;onSaved:()=>void}){
 const {t}=usePreferences();const [value,setValue]=useState(policy?.finance_review_threshold!=null?String(policy.finance_review_threshold):'');const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();
 return <form className="field-policy" noValidate onSubmit={async event=>{event.preventDefault();setBusy(true);setError(undefined);try{await rpc('save_travel_policy',{p_threshold:value.trim()===''?null:Number(value)});onSaved();}catch(next){setError(next);}finally{setBusy(false);}}}>
  <Field label="financeReviewThreshold"><input type="number" min="0" step="0.01" value={value} onChange={event=>setValue(event.target.value)} placeholder={t('notSpecified')}/></Field>
  <p className="field-note">{t('financeReviewThresholdHint')}</p>{!!error&&<ErrorNotice error={error}/>}<button className="primary" disabled={busy}>{t('savePolicy')}</button>
 </form>;
}

type StopDraft={id?:number;client_id:string;appointment_at:string;objective:string;expected_duration_minutes:string;notes:string};

function ItineraryEditor({scope,profile,plan,planStops,clients,requests,onClose,onSaved}:{scope:string;profile:Profile;plan:Row|null;planStops:Row[];clients:Row[];requests:Row[];onClose:()=>void;onSaved:(message:string)=>void}){
 const {t}=usePreferences();const [v,set]=useState({title:plan?.title??'',date:plan?.date??nairobiDate(),start_location:plan?.start_location??'',transport_mode:plan?.transport_mode??'',expected_duration_minutes:plan?.expected_duration_minutes?String(plan.expected_duration_minutes):'',notes:plan?.notes??'',travel_request_id:plan?.travel_request_id?String(plan.travel_request_id):''});
 const [stops,setStops]=useState<StopDraft[]>(()=>planStops.map(stop=>({id:Number(stop.id),client_id:String(stop.client_id),appointment_at:stop.appointment_at?businessDateTimeInput(stop.appointment_at):'',objective:stop.objective??'',expected_duration_minutes:stop.expected_duration_minutes?String(stop.expected_duration_minutes):'',notes:stop.notes??''})));
 const [key]=useState(()=>crypto.randomUUID());const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();
 const owner=plan?.salesperson_id??profile.id;
 const eligible=requests.filter(request=>request.id===plan?.travel_request_id||(!['rejected','cancelled','completed','returned'].includes(request.status)&&(request.salesperson_id===owner||profile.role==='admin')));
 const change=(name:string,value:string)=>set(previous=>({...previous,[name]:value}));
 const updateStop=(index:number,patch:Partial<StopDraft>)=>setStops(previous=>previous.map((stop,position)=>position===index?{...stop,...patch}:stop));
 const move=(index:number,direction:number)=>setStops(previous=>{const next=[...previous];const target=index+direction;if(target<0||target>=next.length)return previous;[next[index],next[target]]=[next[target],next[index]];return next;});
 function addStop(){setStops(previous=>[...previous,{client_id:'',appointment_at:v.date?`${v.date}T09:00`:'',objective:'',expected_duration_minutes:'',notes:''}]);}
 async function save(submit:boolean){setBusy(true);setError(undefined);try{
  if(submit&&!stops.length)throw new Error('destinationRequired');
  if(stops.some(stop=>!stop.client_id)&&(submit||stops.length))throw new Error('invalid');
  if(stops.some(stop=>stop.appointment_at&&businessDateInput(businessInputToInstant(stop.appointment_at))!==v.date))throw new Error('stopDateMismatch');
  const payload=stops.map((stop,index)=>({...(stop.id?{id:stop.id}:{}),client_id:stop.client_id,appointment_at:stop.appointment_at?businessInputToInstant(stop.appointment_at):null,objective:stop.objective,expected_duration_minutes:stop.expected_duration_minutes?Number(stop.expected_duration_minutes):null,notes:stop.notes,sequence:index+1}));
  await rpc('save_itinerary',{p_key:key,p_id:plan?.id??null,p_title:v.title,p_salesperson:Number(owner),p_date:v.date,p_start:v.start_location||null,p_transport:v.transport_mode||null,p_duration:v.expected_duration_minutes?Number(v.expected_duration_minutes):null,p_notes:v.notes||null,p_stops:payload,p_request:v.travel_request_id?Number(v.travel_request_id):null,p_submit:submit});
  onSaved(submit?'itinerarySubmitted':'itinerarySaved');
 }catch(next){setError(next);}finally{setBusy(false);}}
 return <Dialog title={plan?t('editItinerary'):t('newItinerary')} onClose={onClose}><form className="field-form" noValidate onSubmit={event=>{event.preventDefault();void save(false);}}>
  <p className="field-note">{t('itineraryRequestOptional')}</p>
  <div className="field-form-grid"><Field label="itineraryTitle"><input required minLength={3} maxLength={200} value={v.title} onChange={event=>change('title',event.target.value)}/></Field><Field label="itineraryDate"><input required type="date" value={v.date} onChange={event=>change('date',event.target.value)}/></Field><Field label="startLocation"><input maxLength={200} value={v.start_location} onChange={event=>change('start_location',event.target.value)}/></Field><Field label="transportMode"><select value={v.transport_mode} onChange={event=>change('transport_mode',event.target.value)}><option value="">{t('choose')}</option>{TRANSPORT.map(value=><option key={value} value={value}>{t(value)}</option>)}</select></Field><Field label="expectedDuration"><input type="number" min="1" max="1440" value={v.expected_duration_minutes} onChange={event=>change('expected_duration_minutes',event.target.value)}/></Field><Field label="linkedTravelRequest"><select value={v.travel_request_id} onChange={event=>change('travel_request_id',event.target.value)}><option value="">{t('noLinkedRequest')}</option>{eligible.map(request=><option key={request.id} value={request.id}>#{request.id} · {request.destination||request.purpose} · {t(request.status)}</option>)}</select></Field></div>
  <Field label="itineraryNotes"><textarea maxLength={10000} value={v.notes} onChange={event=>change('notes',event.target.value)}/></Field>
  <section className="field-stops"><header><h3>{t('itineraryStops')}</h3><button type="button" className="text-button" onClick={addStop}><Plus size={15}/>{t('addStop')}</button></header>{stops.length===0?<p className="field-empty">{t('noStops')}</p>:stops.map((stop,index)=><article className="field-stop-edit" key={stop.id??`new-${index}`}>
   <div className="field-stop-head"><strong>{index+1}. {t('sequence')}</strong><div><button type="button" disabled={index===0} aria-label={t('moveStopUp')} onClick={()=>move(index,-1)}><ChevronUp size={15}/></button><button type="button" disabled={index===stops.length-1} aria-label={t('moveStopDown')} onClick={()=>move(index,1)}><ChevronDown size={15}/></button><button type="button" aria-label={t('removeStop')} onClick={()=>setStops(previous=>previous.filter((_,position)=>position!==index))}><Trash2 size={15}/></button></div></div>
   <div className="field-form-grid"><Field label="stopClient"><select required value={stop.client_id} aria-label={`${t('stopClient')} ${index+1}`} onChange={event=>updateStop(index,{client_id:event.target.value})}><option value="">{t('choose')}</option>{clients.map(client=><option key={client.id} value={client.id}>{client.name}</option>)}</select></Field><Field label="appointmentAt"><input type="datetime-local" value={stop.appointment_at} onChange={event=>updateStop(index,{appointment_at:event.target.value})}/></Field><Field label="stopDuration"><input type="number" min="1" max="1440" value={stop.expected_duration_minutes} onChange={event=>updateStop(index,{expected_duration_minutes:event.target.value})}/></Field></div>
   <Field label="objective"><input maxLength={1000} value={stop.objective} onChange={event=>updateStop(index,{objective:event.target.value})}/></Field>
   <Field label="stopNotes"><textarea maxLength={2000} value={stop.notes} onChange={event=>updateStop(index,{notes:event.target.value})}/></Field>
  </article>)}</section>
  {!!error&&<ErrorNotice error={error}/>}<div className="dialog-actions"><button type="button" onClick={onClose}>{t('cancel')}</button><button type="button" disabled={busy} onClick={()=>void save(false)}>{t('saveDraft')}</button>{(!plan||plan.status==='draft')&&<button type="button" className="primary" disabled={busy} onClick={()=>void save(true)}>{t('submitItinerary')}</button>}{plan&&plan.status!=='draft'&&<button type="button" className="primary" disabled={busy} onClick={()=>void save(false)}>{t('saveChanges')}</button>}</div>
 </form></Dialog>;
}

function ItineraryDetail({plan,stops,request,clientById,profile,admin,busy,onClose,onEdit,onOpenRequest,onRun}:{plan:Row;stops:Row[];request:Row|null;clientById:Map<string,Row>;profile:Profile;admin:boolean;busy:boolean;onClose:()=>void;onEdit:()=>void;onOpenRequest:(id:number)=>void;onRun:(action:()=>Promise<unknown>,message:string)=>Promise<void>}){
 const {t,language}=usePreferences();const [confirmCancel,setConfirmCancel]=useState(false);const active=stops.filter(stop=>stop.status!=='cancelled');const completed=active.filter(stop=>stop.visit_id!=null).length;
 const editable=OPEN_PLAN.includes(plan.status)&&(admin||plan.salesperson_id===profile.id);
 return <Dialog title={`${t('itineraryMeta')} · #${plan.id}`} onClose={onClose}>
  <dl className="field-meta-list"><div><dt>{t('itineraryTitle')}</dt><dd>{plan.title||'—'}</dd></div><div><dt>{t('itineraryDate')}</dt><dd>{dateOnly(plan.date,language)}</dd></div><div><dt>{t('status')}</dt><dd><Status value={plan.status}/></dd></div><div><dt>{t('startLocation')}</dt><dd>{plan.start_location||t('notSpecified')}</dd></div><div><dt>{t('transportMode')}</dt><dd>{TRANSPORT.includes(plan.transport_mode)?t(plan.transport_mode):t('notSpecified')}</dd></div><div><dt>{t('expectedDuration')}</dt><dd>{plan.expected_duration_minutes??'—'}</dd></div><div><dt>{t('plannedVisits')}</dt><dd>{active.length}</dd></div><div><dt>{t('completedVisits')}</dt><dd>{completed}</dd></div><div><dt>{t('submittedAt')}</dt><dd>{dateTime(plan.submitted_at,language)}</dd></div><div><dt>{t('linkedTravelRequest')}</dt><dd>{request?<button type="button" className="text-button" onClick={()=>onOpenRequest(Number(request.id))}>#{request.id} · {t(request.status)}</button>:'—'}</dd></div></dl>
  {plan.notes&&<p className="field-note">{plan.notes}</p>}
  <section className="field-stops"><header><h3>{t('itineraryStops')}</h3><span className="small-label">{t('plannedVisits')} ≠ {t('completedVisits').toLowerCase()}</span></header>{active.length===0?<p className="field-empty">{t('noStops')}</p>:<ol className="field-stop-list">{active.map(stop=><li key={stop.id}><div><strong>{stop.sequence}. {clientById.get(String(stop.client_id))?.name??`#${stop.client_id}`}</strong><span>{stop.appointment_at?dateTime(stop.appointment_at,language):t('notSpecified')}{stop.objective?` · ${stop.objective}`:''}</span>{stop.notes&&<small>{stop.notes}</small>}</div><div className="field-stop-state"><Status value={stop.status}/>{stop.visit_id?<span className="field-visit-link">{t('visitLinked')} #{stop.visit_id}</span>:<span className="field-visit-link muted">{t('visitNotLinked')}</span>}</div></li>)}</ol>}</section>
  {plan.status==='partially_completed'&&<p className="field-note">{t('visitNotLinked')}</p>}
  <div className="dialog-actions">{editable&&<button type="button" disabled={busy} onClick={onEdit}>{t('editItinerary')}</button>}{['planned','partially_completed'].includes(plan.status)&&(admin||plan.salesperson_id===profile.id)&&<button type="button" disabled={busy} onClick={()=>void onRun(()=>rpc('start_itinerary',{p_id:plan.id}),'itineraryStarted')}>{t('startItinerary')}</button>}{['planned','in_progress','partially_completed'].includes(plan.status)&&(admin||plan.salesperson_id===profile.id)&&<button type="button" className="primary" disabled={busy} onClick={()=>void onRun(()=>rpc('finish_itinerary',{p_id:plan.id,p_cancel:false}),'itineraryFinished')}>{t('finishItinerary')}</button>}{!CLOSED_PLAN.includes(plan.status)&&(admin||plan.salesperson_id===profile.id)&&<button type="button" disabled={busy} onClick={()=>{if(!confirmCancel){setConfirmCancel(true);return;}void onRun(()=>rpc('finish_itinerary',{p_id:plan.id,p_cancel:true}),'itineraryCancelled');}}>{confirmCancel?t('confirmCancel'):t('cancelItinerary')}</button>}<button type="button" onClick={onClose}>{t('close')}</button></div>
 </Dialog>;
}

type ItemDraft={kind:string;label:string;amount:string};

function RequestEditor({scope,profile,request,items,plans,clients,onClose,onSaved}:{scope:string;profile:Profile;request:Row|null;items:Row[];plans:Row[];clients:Row[];onClose:()=>void;onSaved:(message:string)=>void}){
 const {t}=usePreferences();const start=businessDateTimeInput();const [v,set]=useState({purpose:request?.purpose??'',origin:request?.origin??'',destination:request?.destination??'',depart_at:request?.depart_at?businessDateTimeInput(request.depart_at):start,return_at:request?.return_at?businessDateTimeInput(request.return_at):businessDateTimeInput(new Date(Date.now()+86400000)),client_id:request?.client_id?String(request.client_id):'',advance_required:!!request?.advance_required,notes:request?.notes??''});
 const [lines,setLines]=useState<ItemDraft[]>(()=>items.length?items.map(item=>({kind:item.kind,label:item.label,amount:String(item.amount)})):[{kind:'transport',label:'',amount:''}]);
 const [links,setLinks]=useState<string[]>(()=>plans.filter(plan=>plan.travel_request_id===request?.id).map(plan=>String(plan.id)));
 const [key]=useState(()=>crypto.randomUUID());const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();
 const owner=request?.salesperson_id??profile.id;const eligible=plans.filter(plan=>plan.salesperson_id===owner&&(!plan.travel_request_id||plan.travel_request_id===request?.id||profile.role==='admin'));
 const change=(name:string,value:string|boolean)=>set(previous=>({...previous,[name]:value}));
 const total=lines.reduce((sum,line)=>sum+(Number(line.amount)||0),0);
 async function save(submit:boolean){setBusy(true);setError(undefined);try{
  const depart=businessInputToInstant(v.depart_at);const back=businessInputToInstant(v.return_at);if(new Date(back)<=new Date(depart))throw new Error('endBeforeStart');
  if(lines.some(line=>!line.label.trim()||line.amount===''))throw new Error('invalid');
  await rpc('save_travel_request',{p_key:key,p_id:request?.id??null,p_purpose:v.purpose,p_origin:v.origin,p_destination:v.destination,p_depart:depart,p_return:back,p_client:v.client_id?Number(v.client_id):null,p_advance:v.advance_required,p_notes:v.notes||null,p_items:lines.map(line=>({kind:line.kind,label:line.label.trim(),amount:line.amount})),p_itineraries:links.map(Number),p_submit:submit});
  onSaved(submit?'requestSubmitted':'requestSaved');
 }catch(next){setError(next);}finally{setBusy(false);}}
 return <Dialog title={request?t('editTravelRequest'):t('newTravelRequest')} onClose={onClose}><form className="field-form" noValidate onSubmit={event=>{event.preventDefault();void save(false);}}>
  <p className="field-note">{t('timeZoneNote')}</p>
  <Field label="requestPurpose"><textarea required minLength={3} maxLength={10000} value={v.purpose} onChange={event=>change('purpose',event.target.value)}/></Field>
  <div className="field-form-grid"><Field label="origin"><input required minLength={2} maxLength={200} value={v.origin} onChange={event=>change('origin',event.target.value)}/></Field><Field label="destination"><input required minLength={2} maxLength={200} value={v.destination} onChange={event=>change('destination',event.target.value)}/></Field><Field label="departAt"><input required type="datetime-local" value={v.depart_at} onChange={event=>change('depart_at',event.target.value)}/><small>{t('businessTimeZone')}</small></Field><Field label="returnAt"><input required type="datetime-local" value={v.return_at} onChange={event=>change('return_at',event.target.value)}/><small>{t('businessTimeZone')}</small></Field><Field label="requestClient"><select value={v.client_id} onChange={event=>change('client_id',event.target.value)}><option value="">{t('choose')}</option>{clients.map(client=><option key={client.id} value={client.id}>{client.name}</option>)}</select></Field></div>
  <label className="check-line"><input type="checkbox" checked={v.advance_required} onChange={event=>change('advance_required',event.target.checked)}/>{t('advanceRequired')}</label>
  <section className="field-stops"><header><h3>{t('requestItems')}</h3><button type="button" className="text-button" onClick={()=>setLines(previous=>[...previous,{kind:'transport',label:'',amount:''}])}><Plus size={15}/>{t('addItem')}</button></header>{lines.map((line,index)=><div className="field-item-edit" key={index}><Field label="itemKind"><select value={line.kind} aria-label={`${t('itemKind')} ${index+1}`} onChange={event=>setLines(previous=>previous.map((item,position)=>position===index?{...item,kind:event.target.value}:item))}>{ITEM_KINDS.map(kind=><option key={kind} value={kind}>{t(kind)}</option>)}</select></Field><Field label="itemLabel"><input required maxLength={200} value={line.label} aria-label={`${t('itemLabel')} ${index+1}`} onChange={event=>setLines(previous=>previous.map((item,position)=>position===index?{...item,label:event.target.value}:item))}/></Field><Field label="itemAmount"><input required type="number" min="0" step="0.01" value={line.amount} aria-label={`${t('itemAmount')} ${index+1}`} onChange={event=>setLines(previous=>previous.map((item,position)=>position===index?{...item,amount:event.target.value}:item))}/></Field>{lines.length>1&&<button type="button" aria-label={t('removeItem')} onClick={()=>setLines(previous=>previous.filter((_,position)=>position!==index))}><X size={16}/></button>}</div>)}<p className="field-total">{t('totalEstimated')}: <strong>{formatMoney(total,'en')}</strong></p></section>
  <section className="field-stops"><header><h3>{t('selectItineraries')}</h3></header>{eligible.length===0?<p className="field-empty">{t('noItineraries')}</p>:<div className="field-links">{eligible.map(plan=><label key={plan.id}><input type="checkbox" checked={links.includes(String(plan.id))} onChange={event=>setLinks(previous=>event.target.checked?[...previous,String(plan.id)]:previous.filter(id=>id!==String(plan.id)))}/><span>{plan.title||`#${plan.id}`} · {dateOnly(plan.date,'en')} · {t(plan.status)}</span></label>)}</div>}</section>
  <Field label="notes"><textarea maxLength={10000} value={v.notes} onChange={event=>change('notes',event.target.value)}/></Field>
  {!!error&&<ErrorNotice error={error}/>}<div className="dialog-actions"><button type="button" onClick={onClose}>{t('cancel')}</button><button type="button" disabled={busy} onClick={()=>void save(false)}>{t('saveDraft')}</button><button type="button" className="primary" disabled={busy} onClick={()=>void save(true)}>{t('submitRequest')}</button></div>
 </form></Dialog>;
}

function RequestDetail({scope,request,items,documents,plans,client,profile,admin,busy,onClose,onEdit,onDecide,onRun,onRefresh}:{scope:string;request:Row;items:Row[];documents:Row[];plans:Row[];client?:Row;profile:Profile;admin:boolean;busy:boolean;onClose:()=>void;onEdit:()=>void;onDecide:(action:string)=>void;onRun:(action:()=>Promise<unknown>,message:string)=>Promise<void>;onRefresh:()=>Promise<unknown>}){
 const {t,language}=usePreferences();const [fileBusy,setFileBusy]=useState(false);const [fileError,setFileError]=useState<unknown>();const [progress,setProgress]=useState(0);const [confirmCancel,setConfirmCancel]=useState(false);
 const owner=request.salesperson_id===profile.id;const editable=['draft','returned','pending'].includes(request.status)&&(owner||admin);const docsOpen=['draft','returned'].includes(request.status)&&(owner||admin);
 const total=items.reduce((sum,item)=>sum+amount(item.amount),0);
 async function open(document:Row){try{const url=await openPrivateFile(document.path,120);window.open(url,'_blank','noopener');}catch(next){setFileError(next);}}
 async function upload(file:File){setFileBusy(true);setFileError(undefined);setProgress(0);try{const prepared=await prepareDocument(file);const path=`travel/${request.id}/${crypto.randomUUID()}.${documentExtension(prepared.type)}`;await uploadPrivate(path,prepared,setProgress);await rpc('attach_travel_document',{p_id:request.id,p_path:path,p_name:prepared.name,p_type:prepared.type});await onRefresh();}catch(next){setFileError(next);}finally{setFileBusy(false);setProgress(0);}}
 async function remove(document:Row){setFileBusy(true);setFileError(undefined);try{await rpc('remove_travel_document',{p_id:request.id,p_document:document.id});await onRefresh();}catch(next){setFileError(next);}finally{setFileBusy(false);}}
 return <Dialog title={`${t('requestMeta')} · #${request.id}`} onClose={onClose}>
  <dl className="field-meta-list"><div><dt>{t('requestPurpose')}</dt><dd>{request.purpose||'—'}</dd></div><div><dt>{t('status')}</dt><dd><Status value={request.status}/></dd></div><div><dt>{t('origin')}</dt><dd>{request.origin||'—'}</dd></div><div><dt>{t('destination')}</dt><dd>{request.destination||'—'}</dd></div><div><dt>{t('departAt')}</dt><dd>{dateTime(request.depart_at,language)}</dd></div><div><dt>{t('returnAt')}</dt><dd>{dateTime(request.return_at,language)}</dd></div><div><dt>{t('requestClient')}</dt><dd>{client?.name??'—'}</dd></div><div><dt>{t('advanceRequired')}</dt><dd>{request.advance_required?t('yes'):t('no')}</dd></div><div><dt>{t('submittedAt')}</dt><dd>{dateTime(request.submitted_at,language)}</dd></div><div><dt>{t('decidedAt')}</dt><dd>{dateTime(request.decided_at,language)}</dd></div>{request.decision_reason&&<div><dt>{t('decisionReason')}</dt><dd>{request.decision_reason}</dd></div>}</dl>
  <section className="field-stops"><header><h3>{t('requestItems')}</h3><strong>{formatMoney(total,language)}</strong></header>{items.length===0?<p className="field-empty">{t('noRequests')}</p>:<div className="table-wrap"><table><thead><tr><th>{t('itemKind')}</th><th>{t('itemLabel')}</th><th>{t('itemAmount')}</th></tr></thead><tbody>{items.map(item=><tr key={item.id}><td>{t(item.kind)}</td><td>{item.label}</td><td>{formatMoney(item.amount,language)}</td></tr>)}</tbody></table></div>}</section>
  <section className="field-stops"><header><h3>{t('linkedItineraries')}</h3></header>{plans.length===0?<p className="field-empty">{t('noItineraries')}</p>:<div className="field-links read">{plans.map(plan=><span key={plan.id}>{plan.title||`#${plan.id}`} · {dateOnly(plan.date,language)} · {t(plan.status)}</span>)}</div>}</section>
  <section className="field-stops"><header><h3>{t('requestDocuments')}</h3></header><p className="field-note">{t('requestDocumentHint')}</p>{documents.length===0?<p className="field-empty">{t('noDocuments')}</p>:<ul className="field-doc-list">{documents.map(document=><li key={document.id}><FileText size={16}/><div><strong>{document.file_name}</strong><small>{document.content_type||'—'}</small></div><button type="button" onClick={()=>void open(document)}>{t('openDocument')}</button>{docsOpen&&<button type="button" aria-label={t('removeDocument')} disabled={fileBusy} onClick={()=>void remove(document)}><Trash2 size={15}/></button>}</li>)}</ul>}{docsOpen&&<Field label="uploadDocument"><input type="file" disabled={fileBusy} accept="image/jpeg,image/png,image/webp,application/pdf" onChange={event=>{const file=event.target.files?.[0];event.target.value='';if(file)void upload(file);}}/></Field>}{fileBusy&&<p className="field-note" role="status">{t('uploadingDocument')} {progress}%</p>}{!!fileError&&<ErrorNotice error={fileError}/>}</section>
  {request.notes&&<p className="field-note">{request.notes}</p>}
  <div className="dialog-actions">
   {editable&&<button type="button" disabled={busy} onClick={onEdit}>{t('editTravelRequest')}</button>}
   {editable&&request.status!=='pending'&&<button type="button" disabled={busy} onClick={()=>void onRun(()=>rpc('submit_travel_request',{p_id:request.id}),'requestSubmitted')}>{t('submitRequest')}</button>}
   {admin&&(PENDING_REQUEST.includes(request.status)||request.status==='finance_review')&&<><button type="button" className="primary" onClick={()=>onDecide(request.status==='finance_review'?'finance-approve':'approve')}>{request.status==='finance_review'?t('financeApprove'):t('approveRequest')}</button><button type="button" onClick={()=>onDecide(request.status==='finance_review'?'finance-reject':'return')}>{request.status==='finance_review'?t('financeReject'):t('returnRequest')}</button>{request.status!=='finance_review'&&<button type="button" onClick={()=>onDecide('reject')}>{t('rejectRequest')}</button>}</>}
   {admin&&request.status==='approved'&&<button type="button" disabled={busy} onClick={()=>void onRun(()=>rpc('advance_travel_request',{p_id:request.id,p_status:'in_progress'}),'requestAdvanced')}>{t('markInProgress')}</button>}
   {request.status==='in_progress'&&(owner||admin)&&<button type="button" className="primary" disabled={busy} onClick={()=>void onRun(()=>rpc('advance_travel_request',{p_id:request.id,p_status:'completed'}),'requestAdvanced')}>{t('markCompleted')}</button>}
   {!['completed','cancelled'].includes(request.status)&&(owner||admin)&&<button type="button" disabled={busy} onClick={()=>{if(!confirmCancel){setConfirmCancel(true);return;}void onRun(()=>rpc('advance_travel_request',{p_id:request.id,p_status:'cancelled'}),'requestAdvanced');}}>{confirmCancel?t('confirmCancel'):t('cancelRequest')}</button>}
   <button type="button" onClick={onClose}>{t('close')}</button>
  </div>
  <p className="field-note">{t('roleApprovalNote')} {t('estimatedVsActual')}</p>
 </Dialog>;
}

function DecisionDialog({request,action,onClose,onSaved}:{request:Row;action:string;onClose:()=>void;onSaved:(message:string)=>void}){
 const {t}=usePreferences();const finance=action.startsWith('finance-');const decision=action==='approve'||action==='finance-approve'?'approve':action==='return'?'return':'reject';
 const [reason,setReason]=useState('');const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();
 async function submit(){setBusy(true);setError(undefined);try{
  if(decision==='reject'&&reason.trim().length<1)throw new Error('reasonRequired');
  if(decision==='return'&&reason.trim().length<3)throw new Error('reasonRequired');
  await rpc(finance?'finance_decide_travel_request':'decide_travel_request',{p_id:request.id,p_decision:decision,p_reason:reason.trim()||null});
  onSaved('requestDecision');
 }catch(next){setError(next);}finally{setBusy(false);}}
 return <Dialog title={`${t('decision')} · #${request.id}`} onClose={onClose}><p>{request.purpose||request.destination}</p><p className="field-note">{t('roleApprovalNote')} {t('notificationScope')}</p><form className="field-form" noValidate onSubmit={event=>{event.preventDefault();void submit();}}>{decision!=='approve'&&<Field label="decisionReason"><textarea required minLength={decision==='return'?3:1} maxLength={2000} value={reason} onChange={event=>setReason(event.target.value)}/></Field>}{!!error&&<ErrorNotice error={error}/>}<div className="dialog-actions"><button type="button" onClick={onClose}>{t('cancel')}</button><button className="primary" disabled={busy}>{t(decision==='approve'?(finance?'financeApprove':'approveRequest'):decision==='return'?'returnRequest':'rejectRequest')}</button></div></form></Dialog>;
}

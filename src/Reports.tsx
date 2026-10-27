import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { BarChart3, CheckCircle2, Download, FileSpreadsheet, FileText, History, Plane, RefreshCw, ShieldAlert, Sparkles } from 'lucide-react';
import { Dialog, ErrorNotice, Field, Loading, Lookup, Status } from './components';
import { usePreferences } from './i18n';
import { rpc, supabase } from './lib/supabase';
import { nairobiDate, type Profile, type Row } from './lib/data';
import { formatBusinessDate, formatBusinessDateTime, periodBounds } from './lib/dates';
import { formatMoney } from './lib/presentation';
import { csvCell } from './lib/exportCells';
import { csvLetterhead, loadCompanyLogo, pdfLetterhead } from './lib/letterhead';
import { saveXlsx } from './lib/xlsx';

type Period='daily'|'weekly'|'monthly';
type Narrative={executiveSummary:string;salespersonActivity:string;customerIntelligence:string;commercialOutcomes:string;followUpPlan:string;managementInsights:string};
type ReportRow={id:number;period:Period;period_start:string;period_end:string;snapshot:Row;narrative:Narrative|null;ai_status:string;ai_model:string|null;ai_error:string|null;narrative_generated_at:string|null;generated_by:number|null;generated_at:string;is_stale:boolean;version:number};
type VersionRow={id:number;report_id:number;version:number;snapshot:Row;narrative:Narrative|null;ai_status:string;ai_model:string|null;generated_by:number|null;generated_at:string};

const NARRATIVE_SECTIONS:Array<[keyof Narrative,string]>=[['executiveSummary','executiveSummary'],['salespersonActivity','salespersonActivity'],['customerIntelligence','customerIntelligence'],['commercialOutcomes','commercialOutcomes'],['followUpPlan','followUpPlan'],['managementInsights','managementInsights']];
const stamp=(value:string|null|undefined,language:'en'|'zh')=>formatBusinessDateTime(value,language);
const bounds=(period:Period,date:string)=>periodBounds(period,date);
const number=(value:unknown)=>Number(value??0)||0;
const money=(value:unknown)=>formatMoney(number(value).toFixed(2),'en');
const aiLabel=(status:string)=>status==='ready'?'aiReady':status==='template'?'aiTemplate':status==='failed'?'aiFailed':status==='unavailable'?'aiUnavailable':'aiPending';
const aiClass=(status:string)=>status==='ready'?'approved':status==='template'?'pending':status==='failed'?'rejected':'pending';
const outcomeText=(outcomes:Row|undefined)=>Object.entries(outcomes??{}).map(([key,value])=>`${key}: ${value}`).join(' · ')||'—';

function deterministicNarrative(snapshot:Row):Narrative{
 const totals=snapshot.totals??{};const visits:Row[]=snapshot.visits??[];const orders:Row[]=snapshot.orders??[];const people:Row[]=snapshot.salespeople??[];
 const range=`${snapshot.periodStart} to ${snapshot.periodEnd}`;
 const orderTotals=totals.orders??{};
 const travel=totals.travel??{};
 const visitLines=visits.filter(item=>item.discussion||item.feedback||item.opportunities).slice(0,10).map(item=>`${item.client} (${item.salesperson}) · ${item.outcome??'pending'} · ${item.feedback??item.discussion}${item.opportunities?` · Opportunity: ${item.opportunities}`:''}`);
 const followUps=visits.filter(item=>item.nextAction||item.followUpDate).slice(0,12).map(item=>`${item.client} · ${item.nextAction??'Follow-up required'} · owner ${item.followUpOwner??item.salesperson} · due ${item.followUpDate??'not set'}`);
 const activity=people.length?people.map(item=>`${item.name}: ${item.visits} visits, ${item.completed} completed, ${item.clients} clients, outcomes ${outcomeText(item.outcomes)}`):['No salesperson activity was recorded in this period.'];
 return {
  executiveSummary:`Recorded facts for ${range}: ${number(totals.visits)} visits, ${number(totals.completed)} completed and ${number(totals.incomplete)} still open; ${number(totals.clients)} clients were covered by ${number(totals.salespeople)} salespeople. ${number(orderTotals.created)} orders were created with a recorded value of ${money(orderTotals.createdValue)}; ${number(orderTotals.confirmed)} were confirmed with a recorded value of ${money(orderTotals.confirmedValue)}. Field travel: ${number(travel.itineraries)} itineraries with ${number(travel.plannedStops)} planned visits, ${number(travel.completedStops)} linked to saved visits and ${number(travel.outstandingStops)} still outstanding; ${number(travel.requestsSubmitted)} travel requests were submitted and ${number(travel.requestsAwaitingApproval)} await approval. Estimated travel cost ${money(travel.estimatedCost)}, approved ${money(travel.approvedCost)}.`,
  salespersonActivity:activity.join('\n'),
  customerIntelligence:visitLines.length?visitLines.join('\n'):'No customer discussion, feedback or opportunity text was recorded in this period.',
  commercialOutcomes:`Orders created: ${number(orderTotals.created)} (${money(orderTotals.createdValue)}). Orders submitted: ${number(orderTotals.submitted)} (${money(orderTotals.submittedValue)}). Orders confirmed: ${number(orderTotals.confirmed)} (${money(orderTotals.confirmedValue)}). Draft orders: ${number(orderTotals.drafts)}. Rejected or cancelled: ${number(orderTotals.rejected)}. ${orders.length?`Recorded order statuses: ${orders.map(item=>`#${item.id} ${item.status}${item.contractStatus?` / contract ${item.contractStatus}`:''}`).join('; ')}.`:''}`,
  followUpPlan:followUps.length?followUps.join('\n'):'No follow-up actions were recorded. Confirm whether any visits still require a next action.',
  managementInsights:`Interpretation from recorded facts: ${number(totals.gpsExceptions)} GPS exceptions, ${number(totals.followUpsDue)} follow-ups due and ${number(totals.incomplete)} open visits require management attention. Planned field visits: ${number(travel.missedStops)} missed and ${number(travel.rescheduledStops)} rescheduled; ${number(travel.requestsReturned)} travel requests were returned or rejected. Actual paid travel is ${money(travel.actualCost)} from recorded finance disbursements, separate from the estimated and approved amounts. Review the visit detail and order status before setting targets; this section is not a forecast or verified revenue statement.`,
 };
}

function delta(current:number,previous:number){if(!previous)return current?'New activity':'—';const change=Math.round(((current-previous)/previous)*100);return `${change>=0?'+':''}${change}%`;}

function Bars({title,data}:{title:string;data:Array<{label:string;value:number}>}){
 const {t}=usePreferences();const max=Math.max(1,...data.map(item=>item.value));
 if(!data.length)return <div className="report-empty">{t('noVisitsInPeriod')}</div>;
 return <section className="report-bars"><h3><BarChart3 size={17}/>{title}</h3>{data.map(item=><div className="report-bar" key={item.label}><span>{item.label}</span><div><i style={{width:`${Math.max(3,(item.value/max)*100)}%`}}/></div><strong>{item.value}</strong></div>)}</section>;
}

function MetricGrid({snapshot,language}:{snapshot:Row;language:'en'|'zh'}){
 const {t}=usePreferences();const totals=snapshot.totals??{};const previous=snapshot.previous?.totals??{};const orders=totals.orders??{};const previousOrders=previous.orders??{};
 const travel=totals.travel??{};const previousTravel=previous.travel??{};
 const items:Array<[string,number,number,string]>=['visits','completed','incomplete','clients','salespeople','gpsExceptions','followUpsDue'].map(key=>[key,number(totals[key]),number(previous[key]),'count']);
 const orderItems:Array<[string,string,string,string]>=[['newOrders',orders.created,previousOrders.created,'count'],['ordersSubmitted',orders.submitted,previousOrders.submitted,'count'],['ordersConfirmed',orders.confirmed,previousOrders.confirmed,'count'],['createdValue',orders.createdValue,previousOrders.createdValue,'money'],['confirmedValue',orders.confirmedValue,previousOrders.confirmedValue,'money']];
 const travelItems:Array<[string,unknown,unknown,string]>=[['fieldItineraries',travel.itineraries,previousTravel.itineraries,'count'],['plannedVisits',travel.plannedStops,previousTravel.plannedStops,'count'],['completedVisits',travel.completedStops,previousTravel.completedStops,'count'],['missedVisits',travel.missedStops,previousTravel.missedStops,'count'],['outstandingVisits',travel.outstandingStops,previousTravel.outstandingStops,'count'],['pendingApprovals',travel.requestsAwaitingApproval,previousTravel.requestsAwaitingApproval,'count'],['estimatedCost',travel.estimatedCost,previousTravel.estimatedCost,'money'],['approvedCost',travel.approvedCost,previousTravel.approvedCost,'money'],['actualCost',travel.actualCost,previousTravel.actualCost,'money']];
 return <div className="report-metrics">
  {items.map(([key,current,value])=><article key={key}><span>{t(key)}</span><strong>{current}</strong><small>{delta(current,value)} · {t('comparedWithPrevious')}</small></article>)}
  {orderItems.map(([key,current,prior,kind])=><article key={key}><span>{t(key)}</span><strong>{kind==='money'?formatMoney(current,language):number(current)}</strong><small>{delta(number(current),number(prior))} · {t('comparedWithPrevious')}</small></article>)}
  {travelItems.map(([key,current,prior,kind])=><article key={`travel-${key}`}><span>{t(key)}</span><strong>{kind==='money'?formatMoney(number(current),language):number(current)}</strong><small>{delta(number(current),number(prior))} · {t('comparedWithPrevious')}</small></article>)}
 </div>;
}

function NarrativeSections({narrative,status,stale}:{narrative:Narrative|null|undefined;status:string;stale?:boolean}){
 const {t}=usePreferences();
 if(!narrative)return <div className="report-narrative-empty"><Sparkles size={20}/><p>{t(status==='pending'?'narrativePending':'narrativeFailed')}</p></div>;
 const interpretive=status==='ready';
 return <div className="report-narrative-grid">{NARRATIVE_SECTIONS.map(([key,label])=><article key={key} className={`report-narrative ${interpretive?'interpretive':'factual'}`}><header><span className="eyebrow">{interpretive?t('interpretationLabel'):t('factsLabel')}</span><h3>{t(label)}</h3></header><p>{narrative[key]||'—'}</p></article>)}{stale&&<p className="notice">{t('reportStale')}</p>}</div>;
}

export default function Reports({profile,scope}:{profile:Profile;scope:string}){
 const {t,language}=usePreferences();const qc=useQueryClient();const admin=profile.role==='admin';
 const [period,setPeriod]=useState<Period>('daily');const [date,setDate]=useState(nairobiDate());const [salesperson,setSalesperson]=useState('');const [client,setClient]=useState('');
 const [busy,setBusy]=useState(false);const [narrativeBusy,setNarrativeBusy]=useState(false);const [error,setError]=useState<unknown>();const [notice,setNotice]=useState('');const [archived,setArchived]=useState<VersionRow|null>(null);
 const range=useMemo(()=>bounds(period,date),[period,date]);
 const staff=useQuery({queryKey:[scope,'report-staff'],enabled:admin,queryFn:async()=>{const {data,error}=await supabase!.from('users').select('id,name').order('name');if(error)throw new Error(error.message);return data as Row[];}});
 const current=useQuery({queryKey:[scope,'management-report',period,range.start,range.end,salesperson,client],enabled:admin,queryFn:async()=>{let query=supabase!.from('management_reports').select('*').eq('period',period).eq('period_start',range.start).eq('period_end',range.end).order('generated_at',{ascending:false}).limit(1);query=salesperson?query.eq('salesperson_id',Number(salesperson)):query.is('salesperson_id',null);query=client?query.eq('client_id',Number(client)):query.is('client_id',null);const {data,error}=await query;if(error)throw new Error(error.message);return (data?.[0]??null) as ReportRow|null;}});
 const versions=useQuery({queryKey:[scope,'management-report-versions',current.data?.id],enabled:!!current.data?.id,queryFn:async()=>{const {data,error}=await supabase!.from('management_report_versions').select('*').eq('report_id',current.data!.id).order('version',{ascending:false});if(error)throw new Error(error.message);return (data??[]) as VersionRow[];}});
 const people=useMemo(()=>new Map((staff.data??[]).map(person=>[Number(person.id),String(person.name)])),[staff.data]);
 const snapshot=current.data?.snapshot??null;
 const totals=snapshot?.totals??{};
 const orders=totals.orders??{};
 const travel=totals.travel??{};
 const outcomes=totals.outcomes??{};
 const outcomeBars=Object.entries(outcomes).map(([label,value])=>({label,value:number(value)}));
 const salesBars=(snapshot?.salespeople??[]).map((person:Row)=>({label:String(person.name),value:number(person.visits)}));

 async function narrative(report:ReportRow,force=false){
  setNarrativeBusy(true);setError(undefined);
  try{
   let aiAvailable=false;
   try{const {data,error:invokeError}=await supabase!.functions.invoke('report-ai',{body:{report_id:report.id}});aiAvailable=!invokeError&&!!data?.ok;}
   catch{aiAvailable=false;}
   if(!aiAvailable){
    await rpc('store_report_narrative',{p_report_id:report.id,p_narrative:deterministicNarrative(report.snapshot),p_model:'deterministic-v1',p_status:'template',p_error:'AI provider not configured or unavailable; deterministic summary stored.'});
    setNotice(t('narrativeTemplate'));
   }else setNotice(t(force?'narrativeRegenerated':'narrativeReady'));
   await qc.invalidateQueries({queryKey:[scope,'management-report']});
   await qc.invalidateQueries({queryKey:[scope,'management-report-versions']});
  }catch(next){setError(next);}finally{setNarrativeBusy(false);}
 }

 async function generate(){
  setBusy(true);setError(undefined);setNotice('');
  try{
   const result=await rpc<{cached:boolean;report:ReportRow}>('refresh_management_report',{p_period:period,p_date:date,p_salesperson:salesperson?Number(salesperson):null,p_client:client?Number(client):null});
   setNotice(t(result.cached?'reportGenerationCached':'reportGeneratedNotice'));
   await qc.invalidateQueries({queryKey:[scope,'management-report']});
   await qc.invalidateQueries({queryKey:[scope,'management-report-versions']});
   if(result.report.ai_status==='pending')void narrative(result.report);
  }catch(next){setError(next);}finally{setBusy(false);}
 }

 function downloadCsv(){
  if(!current.data||!snapshot)return;
  const lines:string[][]=[];
  lines.push(['Charm Kenya management report']);
  lines.push(['Period',period,'Start',range.start,'End',range.end]);
  lines.push(['Generated',stamp(current.data.generated_at,language),'Version',String(current.data.version)]);
  lines.push([]);
  lines.push(['Key metrics','Current','Previous','Change']);
  [['visits','Visits'],['completed','Completed visits'],['incomplete','Open visits'],['clients','Clients covered'],['gpsExceptions','GPS exceptions'],['followUpsDue','Follow-ups due']].forEach(([key,label])=>lines.push([label,String(totals[key]??0),String(snapshot.previous?.totals?.[key]??0),delta(number(totals[key]),number(snapshot.previous?.totals?.[key]))]));
  [['created','Orders created','createdValue'],['submitted','Orders submitted','submittedValue'],['confirmed','Orders confirmed','confirmedValue']].forEach(([key,label,value])=>lines.push([label,String(orders[key]??0),String(snapshot.previous?.totals?.orders?.[key]??0),money(orders[value])]));
  lines.push([]);
  lines.push(['Field travel · Africa/Nairobi (EAT)','Current','Previous','Change']);
  [['itineraries','Itineraries'],['plannedStops','Planned visits'],['completedStops','Completed visits (linked to saved visits)'],['missedStops','Missed visits'],['rescheduledStops','Rescheduled visits'],['outstandingStops','Outstanding visits'],['requestsSubmitted','Travel requests submitted'],['requestsAwaitingApproval','Travel requests awaiting approval'],['requestsReturned','Travel requests returned or rejected'],['requestsApproved','Travel requests approved']].forEach(([key,label])=>lines.push([label,String(travel[key]??0),String(snapshot.previous?.totals?.travel?.[key]??0),delta(number(travel[key]),number(snapshot.previous?.totals?.travel?.[key]))]));
  [['estimatedCost','Estimated travel cost (KES)'],['approvedCost','Approved travel cost (KES)'],['actualCost','Actual paid travel (KES, finance disbursements)']].forEach(([key,label])=>lines.push([label,money(travel[key]),money(snapshot.previous?.totals?.travel?.[key]),delta(number(travel[key]),number(snapshot.previous?.totals?.travel?.[key]))]));
  lines.push(['Note',t('travelReportNote'),'','']);
  lines.push([]);
  lines.push(['Salespeople','Visits','Completed','Open','Clients','Follow-ups','Outcomes']);
  (snapshot.salespeople??[]).forEach((person:Row)=>lines.push([person.name,String(person.visits),String(person.completed),String(person.incomplete),String(person.clients),String(person.followUps),JSON.stringify(person.outcomes??{})]));
  lines.push([]);
  lines.push(['Visits','Date/time','Salesperson','Client','GPS status','Accuracy (m)','Outcome','Discussion','Feedback','Opportunities','Next action','Follow-up','Owner','Related orders']);
  (snapshot.visits??[]).forEach((visit:Row)=>lines.push([`#${visit.id}`,stamp(visit.checkIn,language),visit.salesperson,visit.client,visit.gpsStatus,String(visit.accuracyM??''),visit.outcome,visit.discussion,visit.feedback,visit.opportunities,visit.nextAction,visit.followUpDate,visit.followUpOwner,String(visit.relatedOrders??0)]));
  lines.push([]);
  lines.push(['Orders','Client','Salesperson','Status','Contract status','Total','Created','Submitted','Confirmed']);
  (snapshot.orders??[]).forEach((order:Row)=>lines.push([`#${order.id}`,order.client,order.salesperson,order.status,order.contractStatus,String(order.total),stamp(order.createdAt,language),stamp(order.submittedAt,language),stamp(order.confirmedAt,language)]));
  lines.push([]);
  lines.push(['Itineraries','Salesperson','Date (EAT)','Status','Start location','Transport','Planned stops','Completed stops','Rescheduled stops']);
  (snapshot.itineraries??[]).forEach((plan:Row)=>lines.push([`#${plan.id}`,plan.title,plan.salesperson,plan.date,plan.status,plan.startLocation,plan.transportMode,String(plan.plannedStops),String(plan.completedStops),String(plan.rescheduledStops)]));
  lines.push([]);
  lines.push(['Travel requests','Salesperson','Purpose','Origin','Destination','Departure (EAT)','Return (EAT)','Status','Estimated (KES)','Actual paid (KES)','Submitted (EAT)','Decided (EAT)','Decision reason','Cash advance']);
  (snapshot.travelRequests??[]).forEach((request:Row)=>lines.push([`#${request.id}`,request.salesperson,request.purpose,request.origin,request.destination,stamp(request.departAt,language),stamp(request.returnAt,language),request.status,String(request.total),String(request.actualPaid??0),stamp(request.submittedAt,language),stamp(request.decidedAt,language),request.decisionReason??'',request.advanceRequired?'Yes':'No']));
  lines.push([]);
  lines.push(['Narrative section','Source','Text']);
  NARRATIVE_SECTIONS.forEach(([key,label])=>lines.push([label,current.data?.ai_status==='ready'?'AI interpretation':'Recorded facts',current.data?.narrative?.[key]??'']));
  const csv=lines.map(row=>row.map(value=>csvCell(value)).join(',')).join('\r\n');
  const link=document.createElement('a');link.href=URL.createObjectURL(new Blob([csvLetterhead(`Management report · ${period} · ${range.start} to ${range.end}`,csv)],{type:'text/csv;charset=utf-8'}));link.download=`charm-management-report-${period}-${range.start}.csv`;document.body.appendChild(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(link.href),2000);
 }

 function downloadXlsx(){
  if(!current.data||!snapshot)return;
  const narrative=current.data.narrative;const source=current.data.ai_status==='ready'?'AI interpretation':'Recorded facts';
  saveXlsx(`charm-management-report-${period}-${range.start}.xlsx`,[
   {name:'Summary',rows:[["Metric","Current","Previous","Change"],['Period',`${range.start} to ${range.end}`,'',''],['Visits',number(totals.visits),number(snapshot.previous?.totals?.visits),delta(number(totals.visits),number(snapshot.previous?.totals?.visits))],['Completed visits',number(totals.completed),number(snapshot.previous?.totals?.completed),delta(number(totals.completed),number(snapshot.previous?.totals?.completed))],['Open visits',number(totals.incomplete),number(snapshot.previous?.totals?.incomplete),delta(number(totals.incomplete),number(snapshot.previous?.totals?.incomplete))],['Clients covered',number(totals.clients),number(snapshot.previous?.totals?.clients),delta(number(totals.clients),number(snapshot.previous?.totals?.clients))],['GPS exceptions',number(totals.gpsExceptions),number(snapshot.previous?.totals?.gpsExceptions),delta(number(totals.gpsExceptions),number(snapshot.previous?.totals?.gpsExceptions))],['Follow-ups due',number(totals.followUpsDue),number(snapshot.previous?.totals?.followUpsDue),delta(number(totals.followUpsDue),number(snapshot.previous?.totals?.followUpsDue))],['Orders created',number(orders.created),number(snapshot.previous?.totals?.orders?.created),delta(number(orders.created),number(snapshot.previous?.totals?.orders?.created))],['Created order value (KES)',number(orders.createdValue),number(snapshot.previous?.totals?.orders?.createdValue),delta(number(orders.createdValue),number(snapshot.previous?.totals?.orders?.createdValue))],['Orders confirmed',number(orders.confirmed),number(snapshot.previous?.totals?.orders?.confirmed),delta(number(orders.confirmed),number(snapshot.previous?.totals?.orders?.confirmed))],['Confirmed order value (KES)',number(orders.confirmedValue),number(snapshot.previous?.totals?.orders?.confirmedValue),delta(number(orders.confirmedValue),number(snapshot.previous?.totals?.orders?.confirmedValue))]]},
   {name:'Travel',rows:[
    ["Field travel · Africa/Nairobi (EAT)","Current","Previous","Change"],
    ['Itineraries',number(travel.itineraries),number(snapshot.previous?.totals?.travel?.itineraries),delta(number(travel.itineraries),number(snapshot.previous?.totals?.travel?.itineraries))],
    ['Planned visits',number(travel.plannedStops),number(snapshot.previous?.totals?.travel?.plannedStops),delta(number(travel.plannedStops),number(snapshot.previous?.totals?.travel?.plannedStops))],
    ['Completed visits (linked to saved visits)',number(travel.completedStops),number(snapshot.previous?.totals?.travel?.completedStops),delta(number(travel.completedStops),number(snapshot.previous?.totals?.travel?.completedStops))],
    ['Missed visits',number(travel.missedStops),number(snapshot.previous?.totals?.travel?.missedStops),delta(number(travel.missedStops),number(snapshot.previous?.totals?.travel?.missedStops))],
    ['Rescheduled visits',number(travel.rescheduledStops),number(snapshot.previous?.totals?.travel?.rescheduledStops),delta(number(travel.rescheduledStops),number(snapshot.previous?.totals?.travel?.rescheduledStops))],
    ['Outstanding visits',number(travel.outstandingStops),number(snapshot.previous?.totals?.travel?.outstandingStops),delta(number(travel.outstandingStops),number(snapshot.previous?.totals?.travel?.outstandingStops))],
    ['Travel requests submitted',number(travel.requestsSubmitted),number(snapshot.previous?.totals?.travel?.requestsSubmitted),delta(number(travel.requestsSubmitted),number(snapshot.previous?.totals?.travel?.requestsSubmitted))],
    ['Travel requests awaiting approval',number(travel.requestsAwaitingApproval),number(snapshot.previous?.totals?.travel?.requestsAwaitingApproval),delta(number(travel.requestsAwaitingApproval),number(snapshot.previous?.totals?.travel?.requestsAwaitingApproval))],
    ['Travel requests returned or rejected',number(travel.requestsReturned),number(snapshot.previous?.totals?.travel?.requestsReturned),delta(number(travel.requestsReturned),number(snapshot.previous?.totals?.travel?.requestsReturned))],
    ['Travel requests approved',number(travel.requestsApproved),number(snapshot.previous?.totals?.travel?.requestsApproved),delta(number(travel.requestsApproved),number(snapshot.previous?.totals?.travel?.requestsApproved))],
    ['Estimated travel cost (KES)',number(travel.estimatedCost),number(snapshot.previous?.totals?.travel?.estimatedCost),delta(number(travel.estimatedCost),number(snapshot.previous?.totals?.travel?.estimatedCost))],
    ['Approved travel cost (KES)',number(travel.approvedCost),number(snapshot.previous?.totals?.travel?.approvedCost),delta(number(travel.approvedCost),number(snapshot.previous?.totals?.travel?.approvedCost))],
    ['Actual paid travel (KES, finance disbursements)',number(travel.actualCost),number(snapshot.previous?.totals?.travel?.actualCost),delta(number(travel.actualCost),number(snapshot.previous?.totals?.travel?.actualCost))],
    ['Note',t('travelReportNote'),'',''],
    [],
    ["Itineraries","Salesperson","Date (EAT)","Status","Start location","Transport","Planned stops","Completed stops","Rescheduled stops"],
    ...(snapshot.itineraries??[]).map((plan:Row)=>[`#${plan.id}`,plan.title,plan.salesperson,String(plan.date),plan.status,plan.startLocation,plan.transportMode,number(plan.plannedStops),number(plan.completedStops),number(plan.rescheduledStops)]),
    [],
    ["Travel requests","Salesperson","Purpose","Origin","Destination","Departure (EAT)","Return (EAT)","Status","Estimated (KES)","Actual paid (KES)","Submitted (EAT)","Decided (EAT)","Decision reason","Cash advance"],
    ...(snapshot.travelRequests??[]).map((request:Row)=>[`#${request.id}`,request.salesperson,request.purpose,request.origin,request.destination,stamp(request.departAt,language),stamp(request.returnAt,language),request.status,number(request.total),number(request.actualPaid),stamp(request.submittedAt,language),stamp(request.decidedAt,language),request.decisionReason??'',request.advanceRequired?'Yes':'No']),
   ]},
   {name:'Salespeople',rows:[["Salesperson","Visits","Completed","Open","Clients","Follow-ups","Outcomes"],...(snapshot.salespeople??[]).map((person:Row)=>[person.name,number(person.visits),number(person.completed),number(person.incomplete),number(person.clients),number(person.followUps),String(outcomeText(person.outcomes))])]},
   {name:'Visits',rows:[["ID","Date/time","Salesperson","Client","GPS status","Accuracy (m)","Outcome","Discussion","Feedback","Opportunities","Next action","Follow-up","Owner","Related orders","Completed"],...(snapshot.visits??[]).map((visit:Row)=>[`#${visit.id}`,stamp(visit.checkIn,language),visit.salesperson,visit.client,visit.gpsStatus,visit.accuracyM==null?'':number(visit.accuracyM),visit.outcome,visit.discussion,visit.feedback,visit.opportunities,visit.nextAction,visit.followUpDate,visit.followUpOwner,number(visit.relatedOrders),visit.completed?'Yes':'No'])]},
   {name:'Orders',rows:[["ID","Client","Salesperson","Status","Contract status","Total (KES)","Created","Submitted","Confirmed"],...(snapshot.orders??[]).map((order:Row)=>[`#${order.id}`,order.client,order.salesperson,order.status,order.contractStatus,number(order.total),stamp(order.createdAt,language),stamp(order.submittedAt,language),stamp(order.confirmedAt,language)])]},
   {name:'Narrative',rows:[["Section","Source","Text"],...NARRATIVE_SECTIONS.map(([key,label])=>[label,source,narrative?.[key]??''])]},
  ]);
 }

 async function downloadPdf(){
  if(!current.data||!snapshot)return;
  try{
   const [{jsPDF},{loadCompanyLogo:logoLoader,pdfLetterhead:letterhead}]=await Promise.all([import('jspdf'),import('./lib/letterhead')]);
   const logo=await logoLoader();const pdf=new jsPDF({orientation:'portrait'});const width=pdf.internal.pageSize.getWidth();let page=1;let y=50;
   const newPage=(title:string)=>{pdf.addPage();page+=1;letterhead(pdf,title,`${range.start} to ${range.end}`,page,logo);y=50;};
   letterhead(pdf,'Management report',`${range.start} to ${range.end}`,page,logo);
   pdf.setTextColor(35,38,58);pdf.setFont('helvetica','bold');pdf.setFontSize(24);pdf.text(`${period.charAt(0).toUpperCase()+period.slice(1)} management report`,15,y);y+=10;pdf.setFont('helvetica','normal');pdf.setFontSize(10);pdf.setTextColor(90,96,112);pdf.text(`Period ${range.start} to ${range.end} · Africa/Nairobi · Version ${current.data.version}`,15,y);y+=6;pdf.text(`Generated ${stamp(current.data.generated_at,language)}${current.data.is_stale?' · NEEDS REFRESH':''}`,15,y);y+=14;
   const kpis:Array<[string,string]>=[['Visits',String(totals.visits??0)],['Completed visits',String(totals.completed??0)],['Clients covered',String(totals.clients??0)],['Orders created',String(orders.created??0)],['Orders confirmed',String(orders.confirmed??0)],['Confirmed order value',money(orders.confirmedValue)]];
   kpis.forEach(([label,value],index)=>{const column=index%2;const row=Math.floor(index/2);const x=15+column*90;const boxY=y+row*24;pdf.setFillColor(244,246,251);pdf.roundedRect(x,boxY,84,20,2,2,'F');pdf.setFontSize(8);pdf.setTextColor(105,110,125);pdf.text(label,x+3,boxY+6);pdf.setFontSize(13);pdf.setTextColor(35,38,58);pdf.setFont('helvetica','bold');pdf.text(value,x+3,boxY+15);pdf.setFont('helvetica','normal');});y+=78;
   const chart=(title:string,entries:Array<{label:string;value:number}>)=>{if(y>230){newPage('Management report');}pdf.setFontSize(11);pdf.setFont('helvetica','bold');pdf.setTextColor(35,38,58);pdf.text(title,15,y);y+=6;const max=Math.max(1,...entries.map(item=>item.value));entries.slice(0,10).forEach(item=>{if(y>272){newPage('Management report');}pdf.setFontSize(8);pdf.setTextColor(80,86,102);pdf.text(item.label.slice(0,35),15,y+3);const barWidth=Math.max(2,(item.value/max)*110);pdf.setFillColor(116,55,164);pdf.roundedRect(70,y-2,barWidth,5,1,1,'F');pdf.setTextColor(55,60,75);pdf.text(String(item.value),185,y+3);y+=6;});};
   chart('Visits by outcome',outcomeBars);y+=4;chart('Visits by salesperson',salesBars);
   if(y>225)newPage('Management report');
   pdf.setFontSize(11);pdf.setFont('helvetica','bold');pdf.setTextColor(35,38,58);pdf.text('Field travel & planning · Africa/Nairobi (EAT)',15,y);y+=7;
   const travelRows:Array<[string,string]>=[['Itineraries',String(number(travel.itineraries))],['Planned visits',String(number(travel.plannedStops))],['Completed visits linked to saved visits',String(number(travel.completedStops))],['Missed visits',String(number(travel.missedStops))],['Rescheduled visits',String(number(travel.rescheduledStops))],['Outstanding visits',String(number(travel.outstandingStops))],['Travel requests submitted',String(number(travel.requestsSubmitted))],['Travel requests awaiting approval',String(number(travel.requestsAwaitingApproval))],['Travel requests returned or rejected',String(number(travel.requestsReturned))],['Travel requests approved',String(number(travel.requestsApproved))],['Estimated travel cost',money(travel.estimatedCost)],['Approved travel cost',money(travel.approvedCost)],['Actual paid travel (finance disbursements)',money(travel.actualCost)]];
   travelRows.forEach(([label,value])=>{if(y>272)newPage('Management report');pdf.setFont('helvetica','normal');pdf.setFontSize(8);pdf.setTextColor(80,86,102);pdf.text(label,15,y);pdf.setTextColor(35,38,58);pdf.text(value,195,y,{align:'right'});y+=5;});
   pdf.setFontSize(7);pdf.setTextColor(105,110,125);const note=pdf.splitTextToSize(t('travelReportNote'),180);for(const line of note){if(y>276)newPage('Management report');pdf.text(line,15,y);y+=3.4;}y+=6;
   const narrative=current.data.narrative;
   NARRATIVE_SECTIONS.forEach(([key,label])=>{const text=narrative?.[key];if(!text)return;if(y>240)newPage('Management report');pdf.setFontSize(11);pdf.setFont('helvetica','bold');pdf.setTextColor(20,89,166);pdf.text(label.replace(/([A-Z])/g,' $1').replace(/^./,value=>value.toUpperCase()),15,y);y+=5;pdf.setFont('helvetica','normal');pdf.setFontSize(9);pdf.setTextColor(55,60,75);const lines=pdf.splitTextToSize(text,180);for(const line of lines){if(y>276){newPage('Management report');pdf.setFontSize(9);pdf.setTextColor(55,60,75);}pdf.text(line,15,y);y+=4.4;}y+=5;});
   if(y>245)newPage('Management report');pdf.setFontSize(8);pdf.setTextColor(105,110,125);pdf.text('Generated from recorded Charm Kenya sales records. AI interpretation, where shown, is labelled separately from facts. No forecast or unverified revenue is included.',15,y,{maxWidth:180});
   pdf.save(`charm-management-report-${period}-${range.start}.pdf`);
   setNotice(t('exportReady'));
  }catch(next){setError(next);}
 }

 if(!admin)return <main className="content"><div className="state"><ShieldAlert size={36}/><h3>{t('forbidden')}</h3></div></main>;
 return <main className="content">
  <div className="page-heading"><div><span className="eyebrow">CHARM KENYA</span><h1>{t('reportingTitle')}</h1><p>{t('reportingIntro')}</p></div><button className="primary" disabled={busy||!date} onClick={()=>void generate()}><RefreshCw size={18}/>{busy?t('loading'):t(current.data?'regenerateReport':'generateReport')}</button></div>
  <section className="card report-controls">
   <div className="report-period-tabs" role="group" aria-label={t('period')}>{(['daily','weekly','monthly'] as Period[]).map(value=><button type="button" key={value} className={period===value?'active':''} onClick={()=>setPeriod(value)}>{t(value)}</button>)}</div>
   <Field label="reportDate"><input type="date" required value={date} onChange={event=>setDate(event.target.value)}/></Field>
   <Field label="salespersonFilter"><select value={salesperson} onChange={event=>setSalesperson(event.target.value)}><option value="">{t('allSalespeople')}</option>{staff.data?.map(person=><option key={person.id} value={person.id}>{person.name}</option>)}</select></Field>
   <Field label="customerFilter"><Lookup kind="clients" scope={scope} value={client} onChange={setClient} label="customerFilter" required={false}/></Field>
   <div className="report-range"><span>{t('reportPeriodStart')} <strong>{range.start}</strong></span><span>{t('reportPeriodEnd')} <strong>{range.end}</strong></span></div>
   <p className="muted-line">{t('generateHint')}</p>
  </section>
  {!!notice&&<div className="notice" role="status">{notice}</div>}{!!error&&<ErrorNotice error={error} retry={()=>setError(undefined)}/>}
  {current.isPending?<Loading/>:current.isError?<ErrorNotice error={current.error} retry={()=>current.refetch()}/>:!current.data?<section className="card state report-empty-state"><FileText size={36}/><h3>{t('noReportYet')}</h3><p>{t('generateHint')}</p><button className="primary" disabled={busy} onClick={()=>void generate()}>{t('generateReport')}</button></section>:<>
   <section className="card report-snapshot">
    <div className="panel-title report-head"><div><span className="eyebrow">{t('reportSnapshot')}</span><h2>{t('reportingTitle')}</h2><p>{range.start} → {range.end} · {t('period')}: {t(period)}</p></div><div className="report-head-actions">{current.data.is_stale?<span className="badge pending">{t('stale')}</span>:<span className="badge approved">{t('currentVersion')}</span>}<span className={`badge ${aiClass(current.data.ai_status)}`}>{t(aiLabel(current.data.ai_status))}</span>{narrativeBusy&&<span className="badge pending">{t('narrativePending')}</span>}</div></div>
    <dl className="contract-meta report-meta"><div><dt>{t('lastGenerated')}</dt><dd>{stamp(current.data.generated_at,language)}</dd></div><div><dt>{t('generatedBy')}</dt><dd>{current.data.generated_by?people.get(Number(current.data.generated_by))??`#${current.data.generated_by}`:'—'}</dd></div><div><dt>{t('reportVersion')}</dt><dd>v{current.data.version}</dd></div><div><dt>{t('aiStatus')}</dt><dd>{t(aiLabel(current.data.ai_status))}{current.data.ai_model?` · ${current.data.ai_model}`:''}</dd></div><div><dt>{t('narrativeGeneratedAt')}</dt><dd>{stamp(current.data.narrative_generated_at,language)}</dd></div></dl>
    {current.data.is_stale&&<p className="notice">{t('reportStale')} {t('staleHint')}</p>}
    {current.data.ai_error&&<p className="doc-private-hint"><ShieldAlert size={14}/>{current.data.ai_error}</p>}
    <MetricGrid snapshot={snapshot!} language={language}/>
    <div className="report-charts"><Bars title={t('visitOutcomes')} data={outcomeBars}/><Bars title={t('reportSalespeople')} data={salesBars}/></div>
    <div className="report-export-row"><span className="eyebrow">{t('reportExports')}</span><button type="button" disabled={narrativeBusy} onClick={()=>current.data&&void narrative(current.data,true)}><Sparkles size={16}/>{t('regenerateNarrative')}</button><button type="button" onClick={downloadPdf}><Download size={16}/>{t('downloadPdf')}</button><button type="button" onClick={downloadXlsx}><FileSpreadsheet size={16}/>{t('downloadXlsx')}</button><button type="button" onClick={downloadCsv}><Download size={16}/>{t('downloadCsv')}</button></div>
   </section>
   <section className="card report-section"><h2>{t(current.data.ai_status==='ready'?'aiNarrative':'recordedFacts')}</h2><p className="muted-line">{t('reportFooter')}</p><NarrativeSections narrative={current.data.narrative} status={current.data.ai_status} stale={current.data.is_stale}/></section>
   <section className="card report-section"><h2>{t('reportSalespeople')}</h2>{(snapshot?.salespeople??[]).length===0?<div className="state">{t('noVisitsInPeriod')}</div>:<div className="table-wrap"><table><thead><tr><th>{t('salespersonFilter')}</th><th>{t('visits')}</th><th>{t('completedVisits')}</th><th>{t('incompleteVisits')}</th><th>{t('clientsCovered')}</th><th>{t('followUpsDue')}</th><th>{t('reportMetrics')}</th></tr></thead><tbody>{(snapshot?.salespeople??[]).map((person:Row)=><tr key={person.id}><td>{person.name}</td><td>{person.visits}</td><td>{person.completed}</td><td>{person.incomplete}</td><td>{person.clients}</td><td>{person.followUps}</td><td>{outcomeText(person.outcomes)}</td></tr>)}</tbody></table></div>}</section>
   <section className="card report-section"><h2>{t('reportVisits')}</h2>{(snapshot?.visits??[]).length===0?<div className="state">{t('noVisitsInPeriod')}</div>:<div className="table-wrap report-table"><table><thead><tr><th>{t('date')}</th><th>{t('salespersonFilter')}</th><th>{t('customerFilter')}</th><th>{t('gpsAccuracy')}</th><th>{t('outcome')}</th><th>{t('followUpOwner')}</th><th>{t('relatedOrders')}</th></tr></thead><tbody>{(snapshot?.visits??[]).map((visit:Row)=><tr key={visit.id}><td>{stamp(visit.checkIn,language)}</td><td>{visit.salesperson}</td><td>{visit.client}</td><td>{visit.gpsStatus}{visit.accuracyM!=null?` · ±${visit.accuracyM} m`:''}</td><td>{visit.outcome??'pending'}</td><td>{visit.nextAction??'—'}{visit.followUpDate?` · ${visit.followUpDate}`:''}</td><td>{visit.relatedOrders??0}</td></tr>)}</tbody></table></div>}</section>
   <section className="card report-section"><h2>{t('reportOrders')}</h2>{(snapshot?.orders??[]).length===0?<div className="state">{t('noOrdersInPeriod')}</div>:<div className="table-wrap report-table"><table><thead><tr><th>#</th><th>{t('customerFilter')}</th><th>{t('salespersonFilter')}</th><th>{t('status')}</th><th>{t('contractStatusLabel')}</th><th>{t('total')}</th><th>{t('created_at')}</th></tr></thead><tbody>{(snapshot?.orders??[]).map((order:Row)=><tr key={order.id}><td>#{order.id}</td><td>{order.client}</td><td>{order.salesperson}</td><td><Status value={order.status}/></td><td><Status value={order.contractStatus??'draft'}/></td><td>{formatMoney(order.total,language)}</td><td>{stamp(order.createdAt,language)}</td></tr>)}</tbody></table></div>}</section>
   <section className="card report-section"><h2><Plane size={18}/>{t('travelReporting')}</h2><p className="muted-line">{t('travelReportNote')}</p><p className="muted-line">{t('travelReportHint')}</p>
    <div className="report-metrics">
     <article><span>{t('fieldItineraries')}</span><strong>{number(travel.itineraries)}</strong><small>{t('completionRate')}: {number(travel.plannedStops)?Math.round(number(travel.completedStops)/number(travel.plannedStops)*100):0}%</small></article>
     <article><span>{t('plannedVisits')}</span><strong>{number(travel.plannedStops)}</strong><small>{t('estimatedVsActual')}</small></article>
     <article><span>{t('completedVisits')}</span><strong>{number(travel.completedStops)}</strong><small>{t('visitLinked')}</small></article>
     <article><span>{t('missedVisits')}</span><strong>{number(travel.missedStops)}</strong><small>{t('rescheduledVisits')}: {number(travel.rescheduledStops)}</small></article>
     <article><span>{t('outstandingVisits')}</span><strong>{number(travel.outstandingStops)}</strong><small>{t('pendingApprovals')}: {number(travel.requestsAwaitingApproval)}</small></article>
     <article><span>{t('estimatedCost')}</span><strong>{formatMoney(number(travel.estimatedCost),language)}</strong><small>{t('fieldRequests')}: {number(travel.requestsSubmitted)}</small></article>
     <article><span>{t('approvedCost')}</span><strong>{formatMoney(number(travel.approvedCost),language)}</strong><small>{t('fieldApprovals')}: {number(travel.requestsApproved)}</small></article>
     <article><span>{t('actualCost')}</span><strong>{formatMoney(number(travel.actualCost),language)}</strong><small>{t('actualCostHint')}</small></article>
    </div>
    {(snapshot?.itineraries??[]).length>0&&<div className="table-wrap report-table"><table><thead><tr><th>{t('fieldItineraries')}</th><th>{t('salespersonFilter')}</th><th>{t('itineraryDate')}</th><th>{t('status')}</th><th>{t('plannedVisits')}</th><th>{t('completedVisits')}</th><th>{t('rescheduledVisits')}</th></tr></thead><tbody>{(snapshot?.itineraries??[]).map((plan:Row)=><tr key={plan.id}><td>{plan.title}</td><td>{plan.salesperson}</td><td>{formatBusinessDate(plan.date,language)}</td><td><Status value={plan.status}/></td><td>{number(plan.plannedStops)}</td><td>{number(plan.completedStops)}</td><td>{number(plan.rescheduledStops)}</td></tr>)}</tbody></table></div>}
    {(snapshot?.travelRequests??[]).length>0&&<div className="table-wrap report-table"><table><thead><tr><th>#</th><th>{t('salespersonFilter')}</th><th>{t('requestPurpose')}</th><th>{t('origin')} → {t('destination')}</th><th>{t('departAt')}</th><th>{t('status')}</th><th>{t('totalEstimated')}</th><th>{t('actualCost')}</th></tr></thead><tbody>{(snapshot?.travelRequests??[]).map((request:Row)=><tr key={request.id}><td>#{request.id}</td><td>{request.salesperson}</td><td>{request.purpose}</td><td>{request.origin} → {request.destination}</td><td>{stamp(request.departAt,language)}</td><td><Status value={request.status}/></td><td>{formatMoney(number(request.total),language)}</td><td>{formatMoney(number(request.actualPaid),language)}</td></tr>)}</tbody></table></div>}
   </section>
   <section className="card report-section"><h2><History size={18}/>{t('reportHistory')}</h2><p className="muted-line">{t('reportHistoryHint')}</p>{versions.isPending?<Loading/>:versions.isError?<ErrorNotice error={versions.error}/>:!versions.data?.length?<div className="state">{t('noReportHistory')}</div>:<div className="report-versions">{versions.data.map(version=><article key={version.id}><div><strong>v{version.version}</strong><Status value={version.ai_status==='ready'?'approved':'pending'}/></div><span>{stamp(version.generated_at,language)} · {version.generated_by?people.get(Number(version.generated_by))??`#${version.generated_by}`:'—'}</span><button type="button" onClick={()=>setArchived(version)}>{t('viewArchivedVersion')}</button></article>)}</div>}</section>
  </>}
  {archived&&<Dialog title={`${t('archivedVersion')} · v${archived.version}`} onClose={()=>setArchived(null)}><p className="muted-line">{t('archivedVersion')} · {stamp(archived.generated_at,language)}</p><MetricGrid snapshot={archived.snapshot} language={language}/><NarrativeSections narrative={archived.narrative} status={archived.ai_status}/><div className="dialog-actions"><button type="button" onClick={()=>setArchived(null)}>{t('close')}</button></div></Dialog>}
 </main>;
}

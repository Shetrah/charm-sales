import { useEffect, useMemo, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { CalendarDays, CircleAlert, ClipboardList, Factory, FileText, PackageCheck, Truck, type LucideIcon } from 'lucide-react';
import { useSearchParams } from 'react-router-dom';
import type { Row } from './lib/data';
import { formatBusinessDate, formatBusinessDateTime, nairobiDate } from './lib/dates';
import { enrich } from './lib/insights';
import { rpc, supabase } from './lib/supabase';
import { usePreferences } from './i18n';
import { Dialog, ErrorNotice, Field, Loading } from './components';
import { OrderDocumentViewer } from './CommercialDocuments';

type Tab = 'intake' | 'deliveries' | 'ledger';
const statusKey = (status:string) => status==='planned'?'statusPlanned':status==='dispatched'?'statusDispatched':status==='delivered'?'statusDelivered':'statusFailed';
const allTabs:[Tab,LucideIcon][]=[['intake',ClipboardList],['deliveries',Truck],['ledger',PackageCheck]];

export default function Logistics({scope,desk=false}:{scope:string;desk?:boolean}){
 const {t,language}=usePreferences();const qc=useQueryClient();const [params,setParams]=useSearchParams();
 const [tab,setTab]=useState<Tab>(desk?'intake':'deliveries');const [filter,setFilter]=useState('');
 const [plan,setPlan]=useState<Row|null>(null);const [production,setProduction]=useState<Row|null>(null);const [action,setAction]=useState<{row:Row;status:'dispatched'|'delivered'|'failed'}|null>(null);const [note,setNote]=useState<Row|null>(null);
 const [busy,setBusy]=useState(false);const [dialogError,setDialogError]=useState<unknown>();const [notice,setNotice]=useState('');
 const autoOpened=useRef<string|null>(null);const today=nairobiDate();
 const money=(value:unknown)=>Number(value??0).toLocaleString(language==='zh'?'zh-CN':'en-KE');
 const deliveries=useQuery({queryKey:[scope,'deliveries'],refetchInterval:10000,queryFn:async()=>{const {data,error}=await supabase!.from('sales_deliveries').select('*').order('id',{ascending:false}).limit(100);if(error)throw error;return enrich(data as Row[]);}});
 const orders=useQuery({queryKey:[scope,'logistics-orders'],queryFn:async()=>{const {data,error}=await supabase!.from('orders').select('id,client_id,salesperson_id,total,status,due_date,confirmed_at').eq('status','confirmed').order('id',{ascending:false}).limit(100);if(error)throw error;return enrich(data as Row[]);}});
 const ledger=useQuery({queryKey:[scope,'inventory-ledger'],enabled:tab==='ledger',refetchInterval:15000,queryFn:async()=>{const result=await rpc<{rows:Row[]}>('sales_inventory_ledger',{p_limit:60});return result.rows;}});
 const intake=useQuery({queryKey:[scope,'logistics-intake'],enabled:desk,refetchInterval:15000,queryFn:async()=>rpc<Row[]>('logistics_order_intake')});
 const summary=useMemo(()=>{const rows=deliveries.data??[];return {planned:rows.filter(r=>r.status==='planned').length,dispatched:rows.filter(r=>r.status==='dispatched').length,deliveredToday:rows.filter(r=>r.status==='delivered'&&r.delivered_at&&nairobiDate(new Date(r.delivered_at))===today).length,failed:rows.filter(r=>r.status==='failed').length};},[deliveries.data,today]);
 const ready=useMemo(()=>{const assigned=new Set((deliveries.data??[]).map(row=>String(row.order_id)));return (orders.data??[]).filter(order=>!assigned.has(String(order.id)));},[orders.data,deliveries.data]);
 const gapsOf=(row:Row):Row[]=>Array.isArray(row.short_items)?row.short_items:[];
 const intakeStats=useMemo(()=>{const rows=intake.data??[];return {waiting:rows.length,covered:rows.filter(row=>row.covered).length,producing:rows.filter(row=>!row.covered&&row.production_required).length,shortLines:rows.reduce((sum,row)=>sum+(Array.isArray(row.short_items)?row.short_items.length:0),0)};},[intake.data]);
 const visible=(deliveries.data??[]).filter(row=>!filter||row.status===filter);
 const tabs=desk?allTabs:allTabs.filter(([key])=>key!=='intake');
 const queue=intake.data??[];
 useEffect(()=>{const record=params.get('record');if(!record||!deliveries.data)return;const row=deliveries.data.find(item=>String(item.id)===record);if(row&&autoOpened.current!==record){autoOpened.current=record;setNote(row);}},[params,deliveries.data]);
 const closeNote=()=>{setNote(null);if(params.get('record')){const next=new URLSearchParams(params);next.delete('record');setParams(next,{replace:true});}};
 const refresh=async(message:string)=>{await qc.invalidateQueries({queryKey:[scope,'deliveries']});await qc.invalidateQueries({queryKey:[scope,'logistics-orders']});await qc.invalidateQueries({queryKey:[scope,'inventory-ledger']});await qc.invalidateQueries({queryKey:[scope,'logistics-intake']});setNotice(t(message));};
 async function submitPlan(form:HTMLFormElement){
  if(!plan)return;const d=new FormData(form);setBusy(true);setDialogError(undefined);
  try{
   await rpc('sales_create_delivery',{p_key:crypto.randomUUID(),p_order:Number(plan.id),p_scheduled:String(d.get('scheduled_on')||''),p_driver:String(d.get('driver_name')||''),p_phone:String(d.get('driver_phone')||''),p_vehicle:String(d.get('vehicle')||''),p_notes:String(d.get('notes')||'')});
   const failed=(deliveries.data??[]).some(row=>String(row.order_id)===String(plan.id)&&row.status==='failed');
   setPlan(null);await refresh(failed?'deliveryRescheduled':'deliveryPlanned');
  }catch(e){setDialogError(e);}finally{setBusy(false);}
 }
 async function submitAction(form:HTMLFormElement){
  if(!action)return;const d=new FormData(form);setBusy(true);setDialogError(undefined);
  try{
   await rpc('sales_update_delivery',{p_id:Number(action.row.id),p_status:action.status,p_note:String(d.get('note')||'')});
   const message=action.status==='dispatched'?'deliveryDispatched':action.status==='delivered'?'deliveryDelivered':'deliveryFailed';
   setAction(null);await refresh(message);
  }catch(e){setDialogError(e);}finally{setBusy(false);}
 }
 const orderFor=(row:Row)=>(orders.data??[]).find(order=>String(order.id)===String(row.order_id))??{id:row.order_id,client_id:row.client_id,_client:row._client,total:null,status:'confirmed'};
 const planFor=(row:Row)=>({id:row.order_id,client_id:row.client_id,_client:row.client_name,total:row.order_total,due_date:row.due_date,status:'confirmed'});
 async function submitProduction(form:HTMLFormElement){
  if(!production)return;const d=new FormData(form);setBusy(true);setDialogError(undefined);
  try{
   await rpc('logistics_arrange_production',{p_key:crypto.randomUUID(),p_order:Number(production.order_id),p_ready_on:String(d.get('ready_on')||'')});
   setProduction(null);await refresh('productionArranged');
  }catch(e){setDialogError(e);}finally{setBusy(false);}
 }
 return <main className="content logistics-page">
  <div className="page-heading"><div><span className="eyebrow">CHARM · FULFILLMENT</span><h1>{t('logisticsTitle')}</h1><p>{t('logisticsIntro')}</p></div>{tab==='deliveries'&&<button className="primary" onClick={()=>setPlan({id:'',_client:''})} disabled={ready.length===0}><Truck size={18}/>{t('planDelivery')}</button>}</div>
  <div className="field-tabs" role="tablist">{tabs.map(([key,Icon])=><button key={key} role="tab" aria-selected={tab===key} className={tab===key?'active':''} onClick={()=>setTab(key)}><Icon size={17}/>{t(`logisticsTab_${key}`)}{key==='deliveries'&&!!(summary.planned+summary.dispatched)&&<em>{summary.planned+summary.dispatched}</em>}{key==='intake'&&!!intakeStats.waiting&&<em>{intakeStats.waiting}</em>}</button>)}</div>
  {!!notice&&<div role="status" className="notice">{notice}</div>}
  {tab==='intake'&&<section className="card field-list-card">
   <header><div><h2>{t('intakeTitle')}</h2><p className="field-note">{t('intakeHint')}</p></div><span className="badge">{intakeStats.waiting}</span></header>
   <div className="field-cards logistics-kpis intake-kpis">
    <article className="field-card"><span className="eyebrow">{t('coveredOrders')}</span><strong>{intakeStats.covered}</strong><small>{t('planDelivery')}</small><PackageCheck size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('productionOrders')}</span><strong>{intakeStats.producing}</strong><small>{t('arrangeProduction')}</small><Factory size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('shortLines')}</span><strong>{intakeStats.shortLines}</strong><small>{t('productionShortfall')}</small><CircleAlert size={18}/></article>
   </div>
   {intake.isPending?<Loading/>:intake.isError?<ErrorNotice error={intake.error} retry={()=>intake.refetch()}/>:queue.length===0?<div className="state"><ClipboardList size={32}/><h3>{t('intakeEmpty')}</h3><p>{t('logisticsEmptyHint')}</p></div>:<div className="field-records intake-board">{queue.map(row=>{const gaps=gapsOf(row);return <article className={`field-record intake-card ${row.covered?'covered':'short'}`} key={row.order_id}>
    <header><div><span className="eyebrow">{t('order_id')} #{row.order_id}</span><h3>{row.client_name}</h3><small>{row.salesperson_name} · {t('total')}: {money(row.order_total)}{row.due_date?` · ${t('due_date')}: ${formatBusinessDate(row.due_date,language)}`:''}</small></div><span className={`badge ${row.production_required?'underProduction':row.covered?'statusDelivered':'needsProduction'}`}>{t(row.production_required?'underProduction':row.covered?'stockAvailable':'needsProduction')}</span></header>
    <div className="field-meta">{row.confirmed_at&&<span><CalendarDays size={14}/>{t('confirmed_at')}: {formatBusinessDateTime(row.confirmed_at,language)}</span>}{row.delivery_status&&<span><Truck size={14}/>{t(statusKey(String(row.delivery_status)))}</span>}{row.production_ready_on&&<span><Factory size={14}/>{t('productionReadyOn')}: {formatBusinessDate(row.production_ready_on,language)}</span>}</div>
    {!!gaps.length&&<ul className="intake-gaps">{gaps.map((gap:Row)=><li key={String(gap.product_id)}><strong>{gap.product}</strong><span>{t('neededQuantity')}: {money(gap.needed)}</span><span className="negative">{t('productionShortfall')}: {money(gap.short)}</span></li>)}</ul>}
    <div className="field-record-actions">{row.covered&&<button className="primary" onClick={()=>setPlan(planFor(row))}><Truck size={15}/>{t(row.delivery_id?'rescheduleDelivery':'planDelivery')}</button>}{!row.covered&&<button className="primary" onClick={()=>setProduction(row)}><Factory size={15}/>{t('arrangeProduction')}</button>}{!!row.delivery_id&&<button onClick={()=>setNote(row)}><FileText size={15}/>{t('openDeliveryNote')}</button>}</div>
   </article>;})}</div>}
  </section>}
  {tab==='deliveries'&&<>
   <div className="field-cards logistics-kpis">
    <article className="field-card"><span className="eyebrow">{t('plannedDeliveries')}</span><strong>{summary.planned}</strong><small>{t('readyToDispatch')}</small><CalendarDays size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('inTransit')}</span><strong>{summary.dispatched}</strong><small>{t('dispatch')}</small><Truck size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('deliveredToday')}</span><strong>{summary.deliveredToday}</strong><small>{t('statusDelivered')}</small><PackageCheck size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('failedDeliveries')}</span><strong>{summary.failed}</strong><small>{t('rescheduleDelivery')}</small><CircleAlert size={18}/></article>
   </div>
   <section className="card field-list-card logistics-ready">
    <header><div><h2>{t('readyToDispatch')}</h2><p className="field-note">{t('readyToDispatchHint')}</p></div><span className="badge">{ready.length}</span></header>
    {orders.isPending?<Loading/>:orders.isError?<ErrorNotice error={orders.error} retry={()=>orders.refetch()}/>:ready.length===0?<p className="field-empty">{t('noReadyOrders')}</p>:<div className="field-rows">{ready.map(order=><div className="field-row static logistics-ready-row" key={order.id}><div><strong>{order._client??`#${order.client_id}`}</strong><span>{t('order')} #{order.id} · {t('total')}: {money(order.total)} · {t('due_date')}: {order.due_date?formatBusinessDate(order.due_date,language):'—'}</span></div><button onClick={()=>setPlan(order)}>{t('planDelivery')}</button></div>)}</div>}
   </section>
   <section className="card field-list-card">
    <header><h2>{t('deliveryBoard')}</h2><select aria-label={t('status')} value={filter} onChange={e=>setFilter(e.target.value)}><option value="">{t('all')}</option>{['planned','dispatched','delivered','failed'].map(status=><option key={status} value={status}>{t(statusKey(status))}</option>)}</select></header>
    {deliveries.isPending?<Loading/>:deliveries.isError?<ErrorNotice error={deliveries.error} retry={()=>deliveries.refetch()}/>:visible.length===0?<div className="state"><Truck size={32}/><h3>{t('logisticsEmpty')}</h3><p>{t('logisticsEmptyHint')}</p></div>:<div className="field-records logistics-board">{visible.map(row=><article className="field-record logistics-card" key={row.id}><header><div><span className="eyebrow">{row.delivery_number}</span><h3>{row._client??`#${row.client_id}`}</h3><small>{t('order')} #{row.order_id}{row._people?.[row.salesperson_id]?` · ${row._people[row.salesperson_id]}`:''}</small></div><span className={`badge ${row.status}`}>{t(statusKey(row.status))}</span></header><div className="field-meta"><span><CalendarDays size={14}/>{t('scheduledFor')}: {formatBusinessDate(row.scheduled_on,language)}</span>{row.driver_name&&<span><Truck size={14}/>{row.driver_name}{row.vehicle?` · ${row.vehicle}`:''}</span>}{row.delivered_at&&<span><PackageCheck size={14}/>{formatBusinessDateTime(row.delivered_at,language)}</span>}</div>{row.failure_reason&&<p className="field-rejection">{row.failure_reason}</p>}<div className="field-record-actions"><button onClick={()=>setNote(row)}><FileText size={15}/>{t('openDeliveryNote')}</button>{row.status==='planned'&&<button className="primary" onClick={()=>setAction({row,status:'dispatched'})}><Truck size={15}/>{t('dispatch')}</button>}{row.status==='dispatched'&&<button className="primary" onClick={()=>setAction({row,status:'delivered'})}><PackageCheck size={15}/>{t('markDelivered')}</button>}{(row.status==='planned'||row.status==='dispatched')&&<button className="text-button" onClick={()=>setAction({row,status:'failed'})}>{t('reportFailure')}</button>}{row.status==='failed'&&<button onClick={()=>setPlan(orderFor(row))}>{t('rescheduleDelivery')}</button>}</div></article>)}</div>}
   </section>
  </>}
  {tab==='ledger'&&<section className="card field-list-card">
   <header><div><h2>{t('ledgerTitle')}</h2><p className="field-note">{t('ledgerHint')}</p></div></header>
   {ledger.isPending?<Loading/>:ledger.isError?<ErrorNotice error={ledger.error} retry={()=>ledger.refetch()}/>:(ledger.data??[]).length===0?<p className="field-empty">{t('ledgerEmpty')}</p>:<div className="logistics-ledger">{(ledger.data??[]).map((row,index)=><article className={`logistics-ledger-row ${row.kind}`} key={`${row.reference}-${row.sku}-${index}`}><span className={`badge ${row.kind==='receipt'?'statusDelivered':'statusDispatched'}`}>{t(row.kind==='receipt'?'ledgerReceipt':'ledgerDispatch')}</span><div><strong>{row.product}</strong><small>{row.sku} · {row.reference} · {row.detail}</small></div><span className={Number(row.quantity)<0?'negative':'positive'}>{Number(row.quantity)>0?'+':''}{money(row.quantity)} <small>{t('ledgerQuantity')}</small></span><time>{formatBusinessDateTime(row.occurred_at,language)}</time></article>)}</div>}
  </section>}
  {plan&&<Dialog title={t('planDelivery')} onClose={()=>{setPlan(null);setDialogError(undefined);}}><form onSubmit={e=>{e.preventDefault();void submitPlan(e.currentTarget);}}>
   {(()=>{const options=[plan,...ready].filter((order,index,list)=>order.id&&list.findIndex(item=>String(item.id)===String(order.id))===index);return <Field label="confirmedOrder"><select name="order_id" required value={String(plan.id||'')} onChange={e=>{const order=options.find(item=>String(item.id)===e.target.value);if(order)setPlan(order);}}><option value="">{t('choose')}</option>{options.map(order=><option key={order.id} value={order.id}>#{order.id} · {order._client??`#${order.client_id}`} · {money(order.total)}</option>)}</select></Field>;})()}
   {!!plan.id&&<div className="field-meta-list"><div><dt>{t('order')}</dt><dd>#{plan.id}</dd></div><div><dt>{t('client')}</dt><dd>{plan._client??`#${plan.client_id}`}</dd></div>{plan.total!=null&&<div><dt>{t('total')}</dt><dd>{money(plan.total)}</dd></div>}</div>}
   <div className="field-form-grid"><Field label="scheduledFor"><input name="scheduled_on" type="date" required min={today} defaultValue={today}/></Field><Field label="driverName"><input name="driver_name" required maxLength={120}/></Field><Field label="driverPhone"><input name="driver_phone" maxLength={40}/></Field><Field label="vehicle"><input name="vehicle" maxLength={80}/></Field></div>
   <Field label="deliveryNotes"><textarea name="notes" rows={3} maxLength={1000}/></Field>
   <p className="field-note">{t('readyToDispatchHint')}</p>
   {!!dialogError&&<ErrorNotice error={dialogError}/>}
   <div className="dialog-actions"><button type="button" onClick={()=>{setPlan(null);setDialogError(undefined);}}>{t('cancel')}</button><button className="primary" disabled={busy||!plan.id}>{t(busy?'saving':'save')}</button></div>
  </form></Dialog>}
  {action&&<Dialog title={t(action.status==='dispatched'?'dispatch':action.status==='delivered'?'markDelivered':'reportFailure')} onClose={()=>{setAction(null);setDialogError(undefined);}}><form onSubmit={e=>{e.preventDefault();void submitAction(e.currentTarget);}}>
   <div className="field-meta-list"><div><dt>{t('deliveryNumber')}</dt><dd>{action.row.delivery_number}</dd></div><div><dt>{t('order')}</dt><dd>#{action.row.order_id}</dd></div><div><dt>{t('client')}</dt><dd>{action.row._client??`#${action.row.client_id}`}</dd></div><div><dt>{t('status')}</dt><dd>{t(statusKey(action.status))}</dd></div></div>
   {action.status==='failed'?<Field label="failureReason"><textarea name="note" rows={3} required minLength={3} maxLength={1000}/></Field>:<p className="field-note">{t(action.status==='dispatched'?'dispatchHint':'deliveredHint')}</p>}
   {!!dialogError&&<ErrorNotice error={dialogError}/>}
   <div className="dialog-actions"><button type="button" onClick={()=>{setAction(null);setDialogError(undefined);}}>{t('cancel')}</button><button className="primary" disabled={busy}>{t(busy?'saving':action.status==='dispatched'?'dispatch':action.status==='delivered'?'markDelivered':'reportFailure')}</button></div>
  </form></Dialog>}
  {production&&<Dialog title={`${t('arrangeProduction')} · ${t('order')} #${production.order_id}`} onClose={()=>{setProduction(null);setDialogError(undefined);}}><form onSubmit={e=>{e.preventDefault();void submitProduction(e.currentTarget);}}>
   <div className="field-meta-list"><div><dt>{t('order')}</dt><dd>#{production.order_id}</dd></div><div><dt>{t('client')}</dt><dd>{production.client_name}</dd></div><div><dt>{t('total')}</dt><dd>{money(production.order_total)}</dd></div>{production.salesperson_name&&<div><dt>{t('salesperson_id')}</dt><dd>{production.salesperson_name}</dd></div>}</div>
   {(()=>{const gaps=gapsOf(production);return gaps.length?<ul className="intake-gaps scheduled">{gaps.map((gap:Row)=><li key={String(gap.product_id)}><strong>{gap.product}</strong><span>{t('neededQuantity')}: {money(gap.needed)}</span><span className="negative">{t('productionShortfall')}: {money(gap.short)}</span></li>)}</ul>:<p className="field-note">{t('intakeHint')}</p>;})()}
   <Field label="readyOn"><input name="ready_on" type="date" required min={today} max={nairobiDate(new Date(Date.now()+180*86400000))} defaultValue={nairobiDate(new Date(Date.now()+3*86400000))}/><small>{t('readyOnHint')}</small></Field>
   <p className="field-note">{t('arrangeProductionHint')}</p>
   {!!dialogError&&<ErrorNotice error={dialogError}/>}
   <div className="dialog-actions"><button type="button" onClick={()=>{setProduction(null);setDialogError(undefined);}}>{t('cancel')}</button><button className="primary" disabled={busy}>{t(busy?'saving':'arrangeProduction')}</button></div>
  </form></Dialog>}
  {note&&<OrderDocumentViewer scope={scope} orderId={Number(note.order_id)} initial="delivery" onClose={closeNote}/>}
 </main>;
}

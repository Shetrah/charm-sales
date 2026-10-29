import { useEffect, useMemo, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { CalendarDays, CircleAlert, FileText, PackageCheck, Truck } from 'lucide-react';
import { useSearchParams } from 'react-router-dom';
import type { Row } from './lib/data';
import { formatBusinessDate, formatBusinessDateTime, nairobiDate } from './lib/dates';
import { enrich } from './lib/insights';
import { rpc, supabase } from './lib/supabase';
import { usePreferences } from './i18n';
import { Dialog, ErrorNotice, Field, Loading } from './components';

type Tab = 'deliveries' | 'ledger';
const statusKey = (status:string) => status==='planned'?'statusPlanned':status==='dispatched'?'statusDispatched':status==='delivered'?'statusDelivered':'statusFailed';

export default function Logistics({scope}:{scope:string}){
 const {t,language}=usePreferences();const qc=useQueryClient();const [params,setParams]=useSearchParams();
 const [tab,setTab]=useState<Tab>('deliveries');const [filter,setFilter]=useState('');
 const [plan,setPlan]=useState<Row|null>(null);const [action,setAction]=useState<{row:Row;status:'dispatched'|'delivered'|'failed'}|null>(null);const [note,setNote]=useState<Row|null>(null);
 const [busy,setBusy]=useState(false);const [dialogError,setDialogError]=useState<unknown>();const [notice,setNotice]=useState('');
 const autoOpened=useRef<string|null>(null);const today=nairobiDate();
 const money=(value:unknown)=>Number(value??0).toLocaleString(language==='zh'?'zh-CN':'en-KE');
 const deliveries=useQuery({queryKey:[scope,'deliveries'],refetchInterval:10000,queryFn:async()=>{const {data,error}=await supabase!.from('sales_deliveries').select('*').order('id',{ascending:false}).limit(100);if(error)throw error;return enrich(data as Row[]);}});
 const orders=useQuery({queryKey:[scope,'logistics-orders'],queryFn:async()=>{const {data,error}=await supabase!.from('orders').select('id,client_id,salesperson_id,total,status,due_date,confirmed_at').eq('status','confirmed').order('id',{ascending:false}).limit(100);if(error)throw error;return enrich(data as Row[]);}});
 const ledger=useQuery({queryKey:[scope,'inventory-ledger'],enabled:tab==='ledger',refetchInterval:15000,queryFn:async()=>{const result=await rpc<{rows:Row[]}>('sales_inventory_ledger',{p_limit:60});return result.rows;}});
 const document=useQuery({queryKey:[scope,'delivery-document',note?.order_id],enabled:!!note,queryFn:()=>rpc<Row>('sales_order_documents',{p_order:Number(note!.order_id)})});
 const summary=useMemo(()=>{const rows=deliveries.data??[];return {planned:rows.filter(r=>r.status==='planned').length,dispatched:rows.filter(r=>r.status==='dispatched').length,deliveredToday:rows.filter(r=>r.status==='delivered'&&r.delivered_at&&nairobiDate(new Date(r.delivered_at))===today).length,failed:rows.filter(r=>r.status==='failed').length};},[deliveries.data,today]);
 const ready=useMemo(()=>{const assigned=new Set((deliveries.data??[]).map(row=>String(row.order_id)));return (orders.data??[]).filter(order=>!assigned.has(String(order.id)));},[orders.data,deliveries.data]);
 const visible=(deliveries.data??[]).filter(row=>!filter||row.status===filter);
 useEffect(()=>{const record=params.get('record');if(!record||!deliveries.data)return;const row=deliveries.data.find(item=>String(item.id)===record);if(row&&autoOpened.current!==record){autoOpened.current=record;setNote(row);}},[params,deliveries.data]);
 const closeNote=()=>{setNote(null);if(params.get('record')){const next=new URLSearchParams(params);next.delete('record');setParams(next,{replace:true});}};
 const refresh=async(message:string)=>{await qc.invalidateQueries({queryKey:[scope,'deliveries']});await qc.invalidateQueries({queryKey:[scope,'logistics-orders']});await qc.invalidateQueries({queryKey:[scope,'inventory-ledger']});setNotice(t(message));};
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
 return <main className="content logistics-page">
  <div className="page-heading"><div><span className="eyebrow">CHARM · FULFILLMENT</span><h1>{t('logisticsTitle')}</h1><p>{t('logisticsIntro')}</p></div>{tab==='deliveries'&&<button className="primary" onClick={()=>setPlan({id:'',_client:''})} disabled={ready.length===0}><Truck size={18}/>{t('planDelivery')}</button>}</div>
  <div className="field-tabs" role="tablist">{([['deliveries','Truck'],['ledger','PackageCheck']] as const).map(([key,icon])=><button key={key} role="tab" aria-selected={tab===key} className={tab===key?'active':''} onClick={()=>setTab(key)}>{icon==='Truck'?<Truck size={17}/>:<PackageCheck size={17}/>}{t(`logisticsTab_${key}`)}{key==='deliveries'&&!!(summary.planned+summary.dispatched)&&<em>{summary.planned+summary.dispatched}</em>}</button>)}</div>
  {!!notice&&<div role="status" className="notice">{notice}</div>}
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
  {note&&<Dialog title={t('deliveryNote')} onClose={closeNote}>
   {document.isPending?<Loading/>:document.isError?<ErrorNotice error={document.error} retry={()=>document.refetch()}/>:document.data&&<DeliveryNote document={document.data} language={language} t={t}/>}
   <div className="dialog-actions delivery-note-actions"><button type="button" onClick={closeNote}>{t('close')}</button><button className="primary" type="button" disabled={document.isPending} onClick={()=>window.print()}>{t('printDocument')}</button></div>
  </Dialog>}
 </main>;
}

function DeliveryNote({document,language,t}:{document:Row;language:'en'|'zh';t:(key:string)=>string}){
 const {client,order,delivery,invoice,items,credit_notes}=document;const money=(value:unknown)=>Number(value??0).toLocaleString(language==='zh'?'zh-CN':'en-KE');
 return <div className="delivery-note">
  <header><div><span className="eyebrow">CHARM KENYA</span><h3>{t('deliveryNote')}</h3><strong>{delivery?.delivery_number??`#${order.id}`}</strong></div>{delivery&&<span className={`badge ${delivery.status}`}>{t(statusKey(delivery.status))}</span>}</header>
  <dl className="delivery-note-meta"><div><dt>{t('client')}</dt><dd>{client.name}</dd></div><div><dt>{t('phone')}</dt><dd>{client.phone||'—'}</dd></div><div><dt>{t('location')}</dt><dd>{client.location||'—'}</dd></div><div><dt>{t('order')}</dt><dd>#{order.id}</dd></div><div><dt>{t('salesperson_id')}</dt><dd>{document.salesperson}</dd></div><div><dt>{t('scheduledFor')}</dt><dd>{delivery?.scheduled_on?formatBusinessDate(delivery.scheduled_on,language):'—'}</dd></div></dl>
  <div className="delivery-note-table"><table><thead><tr><th>{t('product_description')}</th><th>{t('quantity')}</th><th>{t('unit_price')}</th><th>{t('line_total')}</th></tr></thead><tbody>{(delivery?.items?.length?delivery.items:items).map((line:Row,index:number)=><tr key={index}><td>{line.description}{line.sku?<small>{line.sku}</small>:null}</td><td>{line.quantity} {t(line.unit==='carton'?'cartonUnit':'bottle')}</td><td>{money(line.unit_price)}</td><td>{money(line.line_total)}</td></tr>)}</tbody></table></div>
  <div className="delivery-note-totals"><div><span>{t('total')}</span><strong>{money(order.total)}</strong></div><div><span>{t('invoice')}</span><strong>{invoice?`${invoice.invoice_number} · ${money(invoice.total)}`:'—'}</strong>{!invoice&&<small>{t('invoiceNotIssued')}</small>}</div></div>
  {(credit_notes??[]).length>0&&<div className="delivery-note-credits"><h4>{t('creditNotes')}</h4>{credit_notes.map((credit:Row)=><p key={credit.id}><strong>{credit.credit_note}</strong> · {money(credit.amount)} · #{credit.id}</p>)}</div>}
  {delivery?.failure_reason&&<p className="field-rejection">{delivery.failure_reason}</p>}
  <div className="delivery-note-sign"><div><span>{t('receivedBy')}</span><i/></div><div><span>{t('date')}</span><i/></div></div>
  <p className="field-note">{t('deliveryNoteFooter')}</p>
  <p className="field-note">{t('deliveryDocumentHint')}</p>
 </div>;
}

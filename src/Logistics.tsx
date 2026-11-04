import { useEffect, useMemo, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { ArrowRight, Boxes, CalendarDays, CircleAlert, ClipboardList, Factory, FileText, PackageCheck, PackagePlus, Plus, Search, Truck, type LucideIcon } from 'lucide-react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import type { Row } from './lib/data';
import { formatBusinessDate, formatBusinessDateTime, nairobiDate } from './lib/dates';
import { enrich } from './lib/insights';
import { rpc, supabase } from './lib/supabase';
import { usePreferences } from './i18n';
import { Dialog, ErrorNotice, Field, Loading } from './components';
import { OrderDocumentViewer } from './CommercialDocuments';

type Tab = 'overview' | 'intake' | 'deliveries' | 'inventory' | 'ledger';
const statusKey = (status:string) => status==='planned'?'statusPlanned':status==='dispatched'?'statusDispatched':status==='delivered'?'statusDelivered':'statusFailed';
const inventoryTabs:[Tab,LucideIcon][]=[['inventory',Boxes],['ledger',PackageCheck]];

export default function Logistics({scope,desk=false,initial='overview'}:{scope:string;desk?:boolean;initial?:Tab}){
 const {t,language}=usePreferences();const qc=useQueryClient();const [params,setParams]=useSearchParams();const navigate=useNavigate();
 const requestedTab=params.get('tab');const initialTab:Tab=initial==='inventory'&&requestedTab==='ledger'?'ledger':initial;
 const [tab,setTab]=useState<Tab>(initialTab);const [filter,setFilter]=useState('');const [stockSearch,setStockSearch]=useState('');const [receiveProduct,setReceiveProduct]=useState('');const [receiveQuantity,setReceiveQuantity]=useState('');
 useEffect(()=>{setTab(initial==='inventory'&&params.get('tab')==='ledger'?'ledger':initial);},[initial,params]);
 const [plan,setPlan]=useState<Row|null>(null);const [production,setProduction]=useState<Row|null>(null);const [action,setAction]=useState<{row:Row;status:'dispatched'|'delivered'|'failed'}|null>(null);const [note,setNote]=useState<Row|null>(null);const [documentKind,setDocumentKind]=useState<'invoice'|'delivery'>('delivery');const [countProduct,setCountProduct]=useState<Row|null>(null);
 const [busy,setBusy]=useState(false);const [dialogError,setDialogError]=useState<unknown>();const [notice,setNotice]=useState('');
 const autoOpened=useRef<string|null>(null);const today=nairobiDate();
 const money=(value:unknown)=>Number(value??0).toLocaleString(language==='zh'?'zh-CN':'en-KE');
 const deliveries=useQuery({queryKey:[scope,'deliveries'],refetchInterval:10000,queryFn:async()=>{const {data,error}=await supabase!.from('sales_deliveries').select('*').order('id',{ascending:false}).limit(100);if(error)throw error;return enrich(data as Row[]);}});
 const orders=useQuery({queryKey:[scope,'logistics-orders'],queryFn:async()=>{const {data,error}=await supabase!.from('orders').select('id,client_id,salesperson_id,total,status,due_date,confirmed_at').eq('status','confirmed').order('id',{ascending:false}).limit(100);if(error)throw error;return enrich(data as Row[]);}});
 const ledger=useQuery({queryKey:[scope,'inventory-ledger'],enabled:tab==='ledger'||tab==='inventory',refetchInterval:15000,queryFn:async()=>{const result=await rpc<{rows:Row[]}>('sales_inventory_ledger',{p_limit:60});return result.rows;}});
 const inventory=useQuery({queryKey:[scope,'logistics-inventory-summary'],enabled:tab==='overview'||tab==='inventory',refetchInterval:15000,queryFn:()=>rpc<{rows:Row[]}>('logistics_inventory_summary')});
 const intake=useQuery({queryKey:[scope,'logistics-intake'],enabled:desk,refetchInterval:15000,queryFn:async()=>rpc<Row[]>('logistics_order_intake')});
 const summary=useMemo(()=>{const rows=deliveries.data??[];return {planned:rows.filter(r=>r.status==='planned').length,dispatched:rows.filter(r=>r.status==='dispatched').length,deliveredToday:rows.filter(r=>r.status==='delivered'&&r.delivered_at&&nairobiDate(new Date(r.delivered_at))===today).length,failed:rows.filter(r=>r.status==='failed').length};},[deliveries.data,today]);
 const ready=useMemo(()=>{const assigned=new Set((deliveries.data??[]).map(row=>String(row.order_id)));return (orders.data??[]).filter(order=>!assigned.has(String(order.id)));},[orders.data,deliveries.data]);
 const gapsOf=(row:Row):Row[]=>Array.isArray(row.short_items)?row.short_items:[];
 const intakeStats=useMemo(()=>{const rows=intake.data??[];return {waiting:rows.length,covered:rows.filter(row=>row.covered).length,producing:rows.filter(row=>!row.covered&&row.production_required).length,shortLines:rows.reduce((sum,row)=>sum+(Array.isArray(row.short_items)?row.short_items.length:0),0)};},[intake.data]);
 const stockRows=inventory.data?.rows??[];const stockStats=useMemo(()=>({variants:stockRows.length,onHand:stockRows.reduce((n,row)=>n+Number(row.on_hand??0),0),available:stockRows.reduce((n,row)=>n+Number(row.available??0),0),reserved:stockRows.reduce((n,row)=>n+Number(row.reserved??0),0),scheduled:stockRows.reduce((n,row)=>n+Number(row.scheduled??0),0),attention:stockRows.filter(row=>Number(row.available??0)<=0).length}),[stockRows]);const filteredStockRows=useMemo(()=>{const term=stockSearch.trim().toLocaleLowerCase();return term?stockRows.filter(row=>[row.sku,row.category,row.capacity,row.fragrance,row.packaging_type].some(value=>String(value??'').toLocaleLowerCase().includes(term))):stockRows;},[stockRows,stockSearch]);
 const visible=(deliveries.data??[]).filter(row=>!filter||row.status===filter);
 const tabs=initial==='inventory'?inventoryTabs:[];
 const selectTab=(next:Tab)=>{setTab(next);if(next==='overview')navigate('/logistics-dashboard');else if(next==='intake')navigate('/orders');else if(next==='deliveries')navigate('/logistics');else if(next==='inventory')navigate('/inventory');else navigate('/inventory?tab=ledger');};
 const queue=intake.data??[];
 useEffect(()=>{const record=params.get('record');if(!record||!deliveries.data)return;const row=deliveries.data.find(item=>String(item.id)===record);if(row&&autoOpened.current!==record){autoOpened.current=record;setNote(row);}},[params,deliveries.data]);
 const closeNote=()=>{setNote(null);if(params.get('record')){const next=new URLSearchParams(params);next.delete('record');setParams(next,{replace:true});}};
 const refresh=async(message:string)=>{await qc.invalidateQueries({queryKey:[scope,'deliveries']});await qc.invalidateQueries({queryKey:[scope,'logistics-orders']});await qc.invalidateQueries({queryKey:[scope,'inventory-ledger']});await qc.invalidateQueries({queryKey:[scope,'logistics-inventory-summary']});await qc.invalidateQueries({queryKey:[scope,'logistics-intake']});setNotice(t(message));};
 async function saveStockCount(form:HTMLFormElement){if(!countProduct)return;const d=new FormData(form);setBusy(true);setDialogError(undefined);try{await rpc('logistics_set_finished_stock',{p_key:crypto.randomUUID(),p_product:Number(countProduct.product_id),p_count:Number(d.get('count')),p_reason:String(d.get('reason')||''),p_lot:String(d.get('lot')||'')});setCountProduct(null);await refresh('stockCountSaved');}catch(e){setDialogError(e);}finally{setBusy(false);}}
 async function receiveFinishedGoods(form:HTMLFormElement){const d=new FormData(form);setBusy(true);setDialogError(undefined);try{await rpc('logistics_receive_finished_stock',{p_key:crypto.randomUUID(),p_product:Number(d.get('product_id')),p_quantity:Number(d.get('quantity')),p_lot:String(d.get('lot')||''),p_expiry:String(d.get('expiry')||'')||null,p_reference:String(d.get('reference')||'')});setReceiveProduct('');setReceiveQuantity('');form.reset();await refresh('finishedGoodsReceived');}catch(e){setDialogError(e);}finally{setBusy(false);}}
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
 return <main className={`content logistics-page ${desk?'logistics-executive':''}`}>
  <div className="page-heading"><div><span className="eyebrow">CHARM · FULFILLMENT</span><h1>{t(initial==='overview'?'logisticsDashboard':initial==='intake'?'orders':initial==='inventory'?'inventoryWorkspace':'logisticsNav')}</h1><p>{t(initial==='overview'?'logisticsIntro':initial==='intake'?'intakeHint':initial==='inventory'?'inventoryCountHint':'deliveryBoard')}</p></div>{initial==='deliveries'&&<button className="primary" onClick={()=>setPlan({id:'',_client:''})} disabled={ready.length===0}><Truck size={18}/>{t('planDelivery')}</button>}</div>
  {!!tabs.length&&<div className="field-tabs" role="tablist">{tabs.map(([key,Icon])=><button key={key} role="tab" aria-selected={tab===key} className={tab===key?'active':''} onClick={()=>selectTab(key)}><Icon size={17}/>{t(`logisticsTab_${key}`)}</button>)}</div>}
  {!!notice&&<div role="status" className="notice">{notice}</div>}
  {initial==='overview'&&tab==='overview'&&<>
   <section className="logistics-dashboard-hero">
    <div><span className="eyebrow">{t('fulfilmentOperations')}</span><h2>{t('logisticsHeroTitle')}</h2><p>{t('logisticsHeroHint')}</p><div className="logistics-hero-actions">{desk&&<button onClick={()=>selectTab('intake')}><ClipboardList size={16}/>{t('reviewOrders')}</button>}<button onClick={()=>selectTab('deliveries')}><Truck size={16}/>{t('deliveryBoard')}</button></div></div>
    <div className="logistics-hero-mark"><Truck size={42}/></div>
   </section>
   <div className="field-cards logistics-kpis logistics-overview-kpis">
    <article className="field-card logistics-kpi-primary"><span className="eyebrow">{t('ordersAwaitingReview')}</span><strong>{intakeStats.waiting}</strong><small>{t('confirmedOrderIntake')}</small><ClipboardList size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('stockReadyOrders')}</span><strong>{intakeStats.covered}</strong><small>{t('readyToDispatch')}</small><PackageCheck size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('productionOrders')}</span><strong>{intakeStats.producing}</strong><small>{t('shortLines')}: {intakeStats.shortLines}</small><Factory size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('inTransit')}</span><strong>{summary.dispatched}</strong><small>{t('plannedDeliveries')}: {summary.planned}</small><Truck size={18}/></article>
   </div>
   <section className="card field-list-card logistics-overview">
    <header><div><h2>{t('logisticsOverview')}</h2><p className="field-note">{t('logisticsOverviewHint')}</p></div><span className="connection-status"><span className="sync-dot"/>{t('autoRefresh')}</span></header>
    <div className="logistics-overview-grid">
     {desk&&<button className="logistics-overview-link" onClick={()=>selectTab('intake')}><ClipboardList/><span><strong>{t('orders')}</strong><small>{intakeStats.waiting} · {t('ordersAwaitingReview')}</small></span><ArrowRight/></button>}
     <button className="logistics-overview-link" onClick={()=>selectTab('deliveries')}><Truck/><span><strong>{t('deliveryBoard')}</strong><small>{summary.planned} {t('plannedDeliveries')} · {summary.dispatched} {t('inTransit')}</small></span><ArrowRight/></button>
     <button className="logistics-overview-link" onClick={()=>selectTab('inventory')}><Boxes/><span><strong>{t('finishedGoods')}</strong><small>{stockStats.variants} {t('activeProducts')} · {t('reserved')}: {money(stockStats.reserved)}</small></span><ArrowRight/></button>
     <button className="logistics-overview-link" onClick={()=>selectTab('ledger')}><PackageCheck/><span><strong>{t('ledgerTitle')}</strong><small>{t('ledgerHint')}</small></span><ArrowRight/></button>
    </div>
    <div className="logistics-overview-facts">
     <article><span className="eyebrow">{t('deliveryPulse')}</span><strong>{summary.deliveredToday}</strong><p>{t('deliveredToday')}</p><div className="logistics-pulse-stats"><span>{t('plannedDeliveries')} <b>{summary.planned}</b></span><span>{t('inTransit')} <b>{summary.dispatched}</b></span><span>{t('failedDeliveries')} <b>{summary.failed}</b></span></div></article>
     <article><span className="eyebrow">{t('inventoryPosition')}</span><strong>{money(stockStats.available)}</strong><p>{t('unitsAvailableForOrders')}</p><div className="logistics-pulse-stats"><span>{t('reserved')} <b>{money(stockStats.reserved)}</b></span><span>{t('scheduledProduction')} <b>{money(stockStats.scheduled)}</b></span><span>{t('lowStockProducts')} <b>{stockStats.attention}</b></span></div></article>
    </div>
   </section>
  </>}
  {initial==='intake'&&tab==='intake'&&<section className="card field-list-card">
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
    <div className="field-record-actions"><button onClick={()=>{setDocumentKind('invoice');setNote({order_id:row.order_id});}}><FileText size={15}/>{t('invoice')}</button>{row.covered&&<button className="primary" onClick={()=>setPlan(planFor(row))}><Truck size={15}/>{t(row.delivery_id?'rescheduleDelivery':'planDelivery')}</button>}{!row.covered&&<button className="primary" onClick={()=>setProduction(row)}><Factory size={15}/>{t('arrangeProduction')}</button>}{!!row.delivery_id&&<button onClick={()=>{setDocumentKind('delivery');setNote(row);}}><FileText size={15}/>{t('openDeliveryNote')}</button>}</div>
   </article>;})}</div>}
  </section>}
  {initial==='deliveries'&&tab==='deliveries'&&<>
   <div className="field-cards logistics-kpis">
    <article className="field-card"><span className="eyebrow">{t('plannedDeliveries')}</span><strong>{summary.planned}</strong><small>{t('readyToDispatch')}</small><CalendarDays size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('inTransit')}</span><strong>{summary.dispatched}</strong><small>{t('dispatch')}</small><Truck size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('deliveredToday')}</span><strong>{summary.deliveredToday}</strong><small>{t('statusDelivered')}</small><PackageCheck size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('failedDeliveries')}</span><strong>{summary.failed}</strong><small>{t('rescheduleDelivery')}</small><CircleAlert size={18}/></article>
   </div>
   <section className="card field-list-card logistics-ready">
    <header><div><h2>{t('readyToDispatch')}</h2><p className="field-note">{t('readyToDispatchHint')}</p></div><span className="badge">{ready.length}</span></header>
    {orders.isPending?<Loading/>:orders.isError?<ErrorNotice error={orders.error} retry={()=>orders.refetch()}/>:ready.length===0?<p className="field-empty">{t('noReadyOrders')}</p>:<div className="field-rows">{ready.map(order=><div className="field-row static logistics-ready-row" key={order.id}><div><strong>{order._client??`#${order.client_id}`}</strong><span>{t('order')} #{order.id} · {t('total')}: {money(order.total)} · {t('due_date')}: {order.due_date?formatBusinessDate(order.due_date,language):'—'}</span></div><div className="row-actions"><button onClick={()=>{setDocumentKind('invoice');setNote({order_id:order.id});}}><FileText size={15}/>{t('invoice')}</button><button className="primary" onClick={()=>setPlan(order)}>{t('planDelivery')}</button></div></div>)}</div>}
   </section>
   <section className="card field-list-card">
    <header><h2>{t('deliveryBoard')}</h2><select aria-label={t('status')} value={filter} onChange={e=>setFilter(e.target.value)}><option value="">{t('all')}</option>{['planned','dispatched','delivered','failed'].map(status=><option key={status} value={status}>{t(statusKey(status))}</option>)}</select></header>
    {deliveries.isPending?<Loading/>:deliveries.isError?<ErrorNotice error={deliveries.error} retry={()=>deliveries.refetch()}/>:visible.length===0?<div className="state"><Truck size={32}/><h3>{t('logisticsEmpty')}</h3><p>{t('logisticsEmptyHint')}</p></div>:<div className="field-records logistics-board">{visible.map(row=><article className="field-record logistics-card" key={row.id}><header><div><span className="eyebrow">{row.delivery_number}</span><h3>{row._client??`#${row.client_id}`}</h3><small>{t('order')} #{row.order_id}{row._people?.[row.salesperson_id]?` · ${row._people[row.salesperson_id]}`:''}</small></div><span className={`badge ${row.status}`}>{t(statusKey(row.status))}</span></header><div className="field-meta"><span><CalendarDays size={14}/>{t('scheduledFor')}: {formatBusinessDate(row.scheduled_on,language)}</span>{row.driver_name&&<span><Truck size={14}/>{row.driver_name}{row.vehicle?` · ${row.vehicle}`:''}</span>}{row.delivered_at&&<span><PackageCheck size={14}/>{formatBusinessDateTime(row.delivered_at,language)}</span>}</div>{row.failure_reason&&<p className="field-rejection">{row.failure_reason}</p>}<div className="field-record-actions"><button onClick={()=>setNote(row)}><FileText size={15}/>{t('openDeliveryNote')}</button>{row.status==='planned'&&<button className="primary" onClick={()=>setAction({row,status:'dispatched'})}><Truck size={15}/>{t('dispatch')}</button>}{row.status==='dispatched'&&<button className="primary" onClick={()=>setAction({row,status:'delivered'})}><PackageCheck size={15}/>{t('markDelivered')}</button>}{(row.status==='planned'||row.status==='dispatched')&&<button className="text-button" onClick={()=>setAction({row,status:'failed'})}>{t('reportFailure')}</button>}{row.status==='failed'&&<button onClick={()=>setPlan(orderFor(row))}>{t('rescheduleDelivery')}</button>}</div></article>)}</div>}
   </section>
  </>}
  {initial==='inventory'&&tab==='inventory'&&<>
   <section className="card finished-goods-receive">
    <header><div><h2>{t('receiveFinishedGoods')}</h2><p className="field-note">{t('receiveFinishedGoodsHint')}</p></div><Plus size={19}/></header>
    <form onSubmit={e=>{e.preventDefault();void receiveFinishedGoods(e.currentTarget);}}>
     <div className="field-form-grid">
      <Field label="product"><select name="product_id" required value={receiveProduct} onChange={e=>setReceiveProduct(e.target.value)}><option value="">{t('chooseProduct')}</option>{stockRows.map(row=><option key={row.product_id} value={row.product_id}>{row.sku} · {row.category} {row.capacity} {row.fragrance}</option>)}</select></Field>
      <Field label="receiveQuantity"><input name="quantity" type="number" min="1" step="1" required value={receiveQuantity} onChange={e=>setReceiveQuantity(e.target.value)}/><small>{t('receiveQuantityHint')}</small></Field>
      <Field label="lotNumber"><input name="lot" maxLength={120} placeholder={t('optionalLot')}/></Field>
      <Field label="expiry"><input name="expiry" type="date" min={today}/></Field>
      <Field label="reference"><input name="reference" maxLength={160} placeholder={t('optionalReference')}/></Field>
     </div>
     {receiveProduct&&(()=>{const product=stockRows.find(row=>String(row.product_id)===receiveProduct);return product&&<div className="receive-stock-preview"><span>{t('currentStock')}: <strong>{money(product.on_hand)} {t('stockUnitHint')}</strong></span><span>{t('afterReceiptHint')}</span>{Number(receiveQuantity)>0&&<strong className="receive-stock-total">{money(Number(product.on_hand??0)+Number(receiveQuantity))} {t('stockUnitHint')}</strong>}</div>;})()}
     {!!dialogError&&<ErrorNotice error={dialogError}/>}
     <button className="primary" disabled={busy||!receiveProduct}><PackagePlus size={16}/>{t(busy?'saving':'receiveFinishedGoods')}</button>
    </form>
   </section>
   <div className="field-cards logistics-kpis inventory-kpis">
    <article className="field-card"><span className="eyebrow">{t('finishedGoods')}</span><strong>{stockStats.onHand.toLocaleString(language==='zh'?'zh-CN':'en-KE')}</strong><small>{stockStats.variants} {t('activeProducts')}</small><Boxes size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('reservedForOrders')}</span><strong>{stockStats.reserved.toLocaleString(language==='zh'?'zh-CN':'en-KE')}</strong><small>{t('confirmedOrderStock')}</small><ClipboardList size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('scheduledProduction')}</span><strong>{stockStats.scheduled.toLocaleString(language==='zh'?'zh-CN':'en-KE')}</strong><small>{t('productionReleaseAutoHint')}</small><Factory size={18}/></article>
    <article className="field-card"><span className="eyebrow">{t('needsReconciliation')}</span><strong>{stockStats.attention}</strong><small>{t('noAvailableStock')}</small><CircleAlert size={18}/></article>
   </div>
   <section className="card field-list-card logistics-inventory">
    <header><div><h2>{t('finishedGoods')}</h2><p className="field-note">{t('inventoryCountHint')}</p></div><span className="badge">{filteredStockRows.length} / {stockStats.variants}</span></header>
    <label className="logistics-inventory-search"><Search size={18}/><input type="search" value={stockSearch} onChange={e=>setStockSearch(e.target.value)} placeholder={t('searchFinishedGoods')} aria-label={t('searchFinishedGoods')}/>{!!stockSearch&&<button type="button" onClick={()=>setStockSearch('')}>{t('clear')}</button>}</label>
    {inventory.isPending?<Loading/>:inventory.isError?<ErrorNotice error={inventory.error} retry={()=>inventory.refetch()}/>:stockRows.length===0?<p className="field-empty">{t('noInventoryProducts')}</p>:filteredStockRows.length===0?<p className="field-empty">{t('noMatchingProducts')}</p>:<div className="logistics-stock-grid">{filteredStockRows.map(row=><article className="logistics-stock-card" key={row.product_id}>
     <div className="logistics-stock-title"><div><span className="eyebrow">{row.sku}</span><h3>{row.category} · {row.capacity}</h3><small>{row.fragrance||row.packaging_type}</small></div><span className={`stock-pill ${Number(row.available)>0?'stock-ok':'stock-low'}`}>{Number(row.available)>0?t('available'):t('outOfStock')}</span></div>
     <div className="logistics-stock-metrics"><div><span>{t('onHand')}</span><strong>{money(row.on_hand)}</strong></div><div><span>{t('reserved')}</span><strong>{money(row.reserved)}</strong></div><div><span>{t('available')}</span><strong>{money(row.available)}</strong></div><div><span>{t('scheduled')}</span><strong>{money(row.scheduled)}</strong></div></div>
     <small className="logistics-stock-unit">{t('stockUnitHint')} · {row.volume_ml?`${row.volume_ml} ml`:'—'} · {row.carton} {t('perCarton')}</small>
     <button className="stock-count-button" onClick={()=>{setDialogError(undefined);setCountProduct(row);}}><PackagePlus size={16}/>{t('recordStockCount')}</button>
    </article>)}</div>}
   </section>
  </>}
  {initial==='inventory'&&tab==='ledger'&&<section className="card field-list-card">
   <header><div><h2>{t('ledgerTitle')}</h2><p className="field-note">{t('ledgerHint')}</p></div></header>
   {ledger.isPending?<Loading/>:ledger.isError?<ErrorNotice error={ledger.error} retry={()=>ledger.refetch()}/>:(ledger.data??[]).length===0?<p className="field-empty">{t('ledgerEmpty')}</p>:<div className="logistics-ledger">{(ledger.data??[]).map((row,index)=><article className={`logistics-ledger-row ${row.kind}`} key={`${row.reference}-${row.sku}-${index}`}><span className={`badge ${row.kind==='dispatch'?'statusDispatched':row.kind==='adjustment'?'needsProduction':'statusDelivered'}`}>{t(row.kind==='dispatch'?'ledgerDispatch':row.kind==='adjustment'?'ledgerAdjustment':'ledgerReceipt')}</span><div><strong>{row.product}</strong><small>{row.sku} · {row.reference} · {row.detail}</small></div><span className={Number(row.quantity)<0?'negative':'positive'}>{Number(row.quantity)>0?'+':''}{money(row.quantity)} <small>{t('ledgerQuantity')}</small></span><time>{formatBusinessDateTime(row.occurred_at,language)}</time></article>)}</div>}
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
  {countProduct&&<Dialog title={`${t('recordStockCount')} · ${countProduct.sku}`} onClose={()=>{if(!busy){setCountProduct(null);setDialogError(undefined);}}}><form onSubmit={e=>{e.preventDefault();void saveStockCount(e.currentTarget);}}>
   <div className="field-meta-list"><div><dt>{t('product')}</dt><dd>{countProduct.category} · {countProduct.capacity} · {countProduct.fragrance}</dd></div><div><dt>{t('onHand')}</dt><dd>{money(countProduct.on_hand)} {t('stockUnitHint')}</dd></div><div><dt>{t('reserved')}</dt><dd>{money(countProduct.reserved)}</dd></div></div>
   <Field label="physicalCount"><input name="count" type="number" min="0" step="1" required defaultValue={Number(countProduct.on_hand??0)}/><small>{t('physicalCountHint')}</small></Field>
   <Field label="stockCountReason"><textarea name="reason" rows={3} required minLength={3} maxLength={500}/></Field>
   <Field label="lotNumber"><input name="lot" maxLength={120} placeholder={t('optionalLot')}/></Field>
   {!!dialogError&&<ErrorNotice error={dialogError}/>}
   <div className="dialog-actions"><button type="button" disabled={busy} onClick={()=>setCountProduct(null)}>{t('cancel')}</button><button className="primary" disabled={busy}>{t(busy?'saving':'saveCount')}</button></div>
  </form></Dialog>}
  {note&&<OrderDocumentViewer scope={scope} orderId={Number(note.order_id)} initial={documentKind} onClose={closeNote}/>}
 </main>;
}

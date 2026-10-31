import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, ListTree, Plus, Search, Wallet } from 'lucide-react';
import { Dialog, ErrorNotice, Field, Loading, Lookup, useDebounce } from './components';
import { usePreferences } from './i18n';
import { formatMoney } from './finance';
import { nairobiDate, type Profile, type Row } from './lib/data';
import { formatBusinessDate } from './lib/dates';
import { cents, decimal } from './lib/money';
import { downloadCsv, downloadPdf, financeRpc as rpc, register, uploadFinance, type FinanceFilters } from './lib/financePortal';

const registerColumns=['expense_number','reference','expense_on','description','category_name','department_name','classification','payment_status','amount','paid','outstanding','payment_method','account_name','recipient','owner_name','source_type','status'];
const headerLabels:Record<string,string>={description:'expenseDescription',recipient:'expensePaidTo',account_name:'expensePaidFrom',payment_method:'paymentMethod'};
const moneyFields=['amount','paid','outstanding'];
const classes=['expense','cost_of_sales','advance','committed'];
const paymentStates=['unpaid','partial','paid'];
const methods=['Cash','Bank','M-Pesa','Cheque','Other'];
const moneyPattern='[0-9]{1,11}(\\.[0-9]{1,2})?';
const quantityPattern='[0-9]{1,9}(\\.[0-9]{1,4})?';

export default function FinanceExpenses({scope,profile,meta,filters,onFilter,onOpen}:{scope:string;profile:Profile;meta:Row;filters:FinanceFilters;onFilter:(key:keyof FinanceFilters,value:string)=>void;onOpen:(id:number)=>void}){
 const {t,language}=usePreferences();const qc=useQueryClient();
 const [states,setStates]=useState<Record<string,string>>({classification:'',category:'',department:'',account:'',payment:''});
 const [search,setSearch]=useState('');const debounced=useDebounce(search);
 const [page,setPage]=useState(1);const [dialog,setDialog]=useState<{kind:string;id?:number}|null>(null);
 const [notice,setNotice]=useState('');const [error,setError]=useState<unknown>();const [exporting,setExporting]=useState(false);
 const live={retry:false,refetchInterval:15000,refetchIntervalInBackground:false,refetchOnWindowFocus:true};
 const totals=useQuery({queryKey:[scope,'expense-totals',filters.from,filters.to],queryFn:()=>rpc<Row>('finance_expense_totals',{p_from:filters.from,p_to:filters.to}),...live});
 const args={p_from:filters.from,p_to:filters.to,p_classification:states.classification,p_category:states.category?Number(states.category):null,p_department:states.department?Number(states.department):null,p_account:states.account?Number(states.account):null,p_payment:states.payment,p_search:debounced,p_page:page};
 const listed=useQuery({queryKey:[scope,'expense-register',args],queryFn:()=>rpc<{rows:Row[];total:number}>('finance_expense_register',args),...live});
 const drafted=useQuery({queryKey:[scope,'expense-drafts',filters],queryFn:async()=>{
  const queues=await Promise.all(['draft','returned'].map(status=>register('requests',{...filters,status,owner:''},1)));
  return {rows:queues.flatMap(queue=>queue.rows).filter(row=>row.kind==='expense').sort((a,b)=>Number(b.id)-Number(a.id))};
 },...live});
 const drafts=drafted.data?.rows??[];
 const refresh=async()=>{setDialog(null);try{await qc.invalidateQueries({queryKey:[scope]},{throwOnError:true});setNotice('financeUpdated');}catch{setNotice('financeRefreshFailed');}};
 useEffect(()=>{if(!notice)return;const timer=setTimeout(()=>setNotice(''),5000);return()=>clearTimeout(timer);},[notice]);
 const choose=(key:string,label:string,values:[string,string][])=> <Field label={label}><select value={states[key]} onChange={e=>{setStates({...states,[key]:e.target.value});setPage(1);}}><option value="">{t('anyOption')}</option>{values.map(([value,text])=><option key={value} value={value}>{text}</option>)}</select></Field>;
 async function exportData(pdf=false){setExporting(true);setError(undefined);
  try{const all=(await rpc<{rows:Row[]}>('finance_expense_register',{...args,p_page:0})).rows;
   if(pdf)await downloadPdf(all,registerColumns,'expenses',`${filters.from} to ${filters.to}`);else downloadCsv(all,registerColumns,`charm-expenses-${filters.from}-${filters.to}.csv`);
  }catch(e){setError(e);}finally{setExporting(false);}}
 const data=totals.data;const cash:Row=data?.cashOutByKind??{};const cashOut=Number(data?.cashOut??'0');
 const cell=(key:string,row:Row)=>{
  const value=row[key];
  if(moneyFields.includes(key))return formatMoney(value??'0',language);
  if(key==='classification')return <span className={`badge class-${value}`}>{t(`classification_${value}`)}</span>;
  if(key==='source_type')return t(`source_${value}`);
  if(key==='payment_status')return <span className={`badge ${value}`}>{t(`paymentState_${value}`)}</span>;
  if(key==='status')return <span className={`badge ${value}`}>{t(String(value==='paid'?'fullyDisbursed':value))}</span>;
  if(key==='expense_on')return formatBusinessDate(value,language);
  if(key==='recipient')return value||t('expenseNoRecipient');
  if(value===null||value===undefined||value==='')return '—';
  return String(value);
 };
 const bars=(rows:Row[],label:(row:Row)=>string)=>rows.length===0?<p>{t('empty')}</p>:<div className="finance-category-bars">{rows.map(row=>{const max=Math.max(1,...rows.map(x=>Number(x.amount)));return <div key={label(row)}><span>{label(row)}</span><strong>{formatMoney(row.amount,language)}</strong><div className="bar-track"><div style={{width:`${Number(row.amount)/max*100}%`}}/></div></div>;})}</div>;
 return <section className="expense-workspace">
  <div className="expense-actionbar"><div className="row-actions">
   <button className="primary" onClick={()=>setDialog({kind:'expense'})}><Plus size={18}/>{t('recordExpense')}</button>
   <button onClick={()=>setDialog({kind:'lists'})}><ListTree size={17}/>{t('manageExpenseLists')}</button>
  </div></div>
  {notice&&<div className="notice" role="status">{t(notice)}</div>}
  <section className="card finance-filters">
   <Field label="fromDate"><input type="date" value={filters.from} onChange={e=>onFilter('from',e.target.value)}/></Field>
   <Field label="toDate"><input type="date" value={filters.to} onChange={e=>onFilter('to',e.target.value)}/></Field>
   <div className="field expense-search-field"><span>{t('searchExpenses')}</span><span className="expense-search"><Search size={17}/><input aria-label={t('searchExpenses')} value={search} onChange={e=>{setSearch(e.target.value);setPage(1);}} placeholder={t('searchExpensesHint')}/></span></div>
   {choose('classification','classification',classes.map(value=>[value,t(`classification_${value}`)]))}
   {choose('payment','payment_status',paymentStates.map(value=>[value,t(`paymentState_${value}`)]))}
   {choose('category','expenseCategory',meta.categories.map((c:Row)=>[String(c.id),c.name]))}
   {choose('department','department',meta.departments.map((d:Row)=>[String(d.id),d.name]))}
   {choose('account','expensePaidFrom',meta.refund_accounts.map((a:Row)=>[String(a.id),a.name]))}
  </section>
  {totals.isPending?<Loading/>:totals.isError?<ErrorNotice error={totals.error} retry={()=>totals.refetch()}/>:<>
   <div className="finance-kpis">
    {['today','week','month','year'].map(key=><article className="card" key={key}><span>{t(`expense${key[0].toUpperCase()}${key.slice(1)}`)}</span><strong>{formatMoney(data?.[key],language)}</strong></article>)}
    <article className="card"><span>{t('expensePeriodTotal')}</span><strong>{formatMoney(data?.period,language)}</strong><small>{filters.from} — {filters.to}</small></article>
    <article className="card"><span>{t('expenseRecords')}</span><strong>{String(data?.records??0)}</strong><small>{t('expenseRecordsHint')}</small></article>
   </div>
   <div className="finance-charts">
    <section className="card"><h2>{t('expenseSplit')}</h2><p className="chart-note">{t('expenseSplitHint')}</p>
     <div className="expense-split">
      {[['classification_expense',data?.period],['costOfSales',data?.costOfSales],['classification_advance',data?.advances],['classification_committed',data?.committed],['expenseUnpaid',data?.unpaid],['expensePaid',data?.paidAmount]].map(([label,value])=><div key={String(label)}><span>{t(String(label))}</span><strong>{formatMoney(value,language)}</strong></div>)}
     </div>
    </section>
    <section className="card"><h2>{t('cashReconciliation')}</h2><p className="chart-note">{t('cashReconciliationHint')}</p>
     <div className="account-balance grand"><span>{t('totalCashOut')}</span><strong>{formatMoney(data?.cashOut,language)}</strong></div>
     {([['advance','cashAdvance'],['expense','cashExpense'],['supplier','cashSupplier'],['purchase','cashPurchase']] as const).map(([key,label])=><div className="account-balance" key={key}><span>{t(label)}{cashOut>0&&<small>{Math.round(Number(cash[key]??0)/cashOut*100)}%</small>}</span><strong>{formatMoney(cash[key]??'0',language)}</strong></div>)}
     <div className="account-balance"><span>{t('financeAccounts')}</span><strong>{formatMoney(data?.balance,language)}</strong></div>
     <div className="account-balance"><span>{t('receivable')}</span><strong>{formatMoney(data?.receivable,language)}</strong></div>
     <div className="account-balance"><span>{t('payable')}</span><strong>{formatMoney(data?.payable,language)}</strong></div>
    </section>
   </div>
   <div className="finance-charts expense-analysis">
    <section className="card"><h2>{t('byCategory')}</h2>{bars(data?.categories??[],row=>row.category_name)}</section>
    <section className="card"><h2>{t('byDepartment')}</h2>{bars(data?.departments??[],row=>row.department_name)}</section>
    <section className="card"><h2>{t('bySource')}</h2>{bars(data?.sources??[],row=>t(`classification_${row.classification}`))}</section>
    <section className="card"><h2>{t('monthlyTrend')}</h2>{bars(data?.trend??[],row=>row.month)}</section>
    <section className="card expense-pipeline"><h2>{t('expensePipeline')}</h2><p className="chart-note">{t('expensePipelineHint')}</p>
     {[['pendingReview','pending'],['awaiting_payment','approved'],['closed','settled']].map(([label,key])=><div className="account-balance" key={key}><span>{t(label)}<small>{String(data?.[key]?.count??0)}</small></span><strong>{formatMoney(data?.[key]?.amount??'0',language)}</strong></div>)}
    </section>
   </div>
  </>}
  {drafts.length>0&&<section className="card expense-drafts"><div className="toolbar"><h2>{t('expenseDrafts')}</h2><span>{t('expenseDraftsHint')}</span></div>
   <div className="expense-draft-grid">{drafts.map(row=><article className="card" key={String(row.id)}><div><strong>{row.expense_number??`#${row.id}`}</strong><span className={`badge ${row.status}`}>{t(String(row.status))}</span></div><p>{row.purpose}</p><small>{formatBusinessDate(row.expense_on,language)} · {row.category_name}</small><strong>{formatMoney(row.amount,language)}</strong><div className="row-actions"><button onClick={()=>setDialog({kind:'expense',id:Number(row.id)})}>{t('continueDraft')}</button><button onClick={()=>onOpen(Number(row.id))}>{t('details')}</button></div></article>)}</div>
  </section>}
  <section className="card records expense-register">
   <div className="toolbar"><h2>{t('expenseRegister')}</h2><span>{t('expenseRegisterHint')}</span>
    <button disabled={exporting||listed.isPending} onClick={()=>void exportData()}><Download size={16}/> CSV</button>
    <button disabled={exporting||listed.isPending} onClick={()=>void exportData(true)}><Download size={16}/> PDF</button>
   </div>
   {!!error&&<ErrorNotice error={error}/ >}
   {listed.isPending?<Loading/>:listed.isError?<ErrorNotice error={listed.error} retry={()=>listed.refetch()}/>:listed.data.rows.length===0?<div className="state"><Wallet size={32}/><h3>{t('empty')}</h3><p>{t('expenseRegisterEmpty')}</p></div>:<>
    <div className="table-wrap desktop-records"><table><thead><tr>{registerColumns.map(key=><th key={key}>{t(headerLabels[key]??key)}</th>)}<th>{t('actions')}</th></tr></thead>
     <tbody>{listed.data.rows.map(row=><tr key={String(row.line_id)}>{registerColumns.map(key=><td key={key}>{cell(key,row)}</td>)}<td><div className="row-actions"><button onClick={()=>onOpen(Number(row.request_id))}>{t('details')}</button></div></td></tr>)}</tbody></table></div>
    <div className="finance-mobile-cards">{listed.data.rows.map(row=><article key={String(row.line_id)}><div><strong>{row.expense_number??`#${String(row.request_id)}`}</strong><span className={`badge ${row.payment_status}`}>{t(`paymentState_${row.payment_status}`)}</span></div>
     <dl>{registerColumns.filter(key=>!['expense_number','payment_status','description'].includes(key)).map(key=><div key={key}><dt>{t(headerLabels[key]??key)}</dt><dd>{cell(key,row)}</dd></div>)}</dl>
     <p className="expense-card-description">{row.description}</p>
     <div className="row-actions"><button onClick={()=>onOpen(Number(row.request_id))}>{t('details')}</button></div></article>)}</div>
    <div className="pagination"><span>{listed.data.total} · {t('page')} {page}</span><button disabled={page===1} onClick={()=>setPage(page-1)}>{t('previous')}</button><button disabled={page*100>=listed.data.total} onClick={()=>setPage(page+1)}>{t('next')}</button></div>
   </>}
  </section>
  {dialog?.kind==='expense'&&<ExpenseForm scope={scope} profile={profile} meta={meta} id={dialog.id} onClose={()=>setDialog(null)} onSaved={refresh}/>}
  {dialog?.kind==='lists'&&<ExpenseLists onClose={()=>setDialog(null)} onSaved={refresh}/>}
 </section>;
}

function ExpenseForm({scope,profile,meta,id,onClose,onSaved}:{scope:string;profile:Profile;meta:Row;id?:number;onClose:()=>void;onSaved:()=>void}){
 const {t,language}=usePreferences();
 const detail=useQuery({queryKey:['expense-record',id],enabled:!!id,queryFn:()=>rpc<Row>('finance_expense_detail',{p_id:id!}),retry:false});
 const [head,setHead]=useState<Row>({category:String(meta.categories[0]?.id??''),department:'',date:nairobiDate(),payee:'',recipient:'',order:'',method:'Cash',purpose:''});
 const [lines,setLines]=useState<Row[]>([{description:'',quantity:'1',unit_price:'',discount:'',tax:''}]);
 const [files,setFiles]=useState<File[]>([]);
 const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();
 const form=useRef<HTMLFormElement>(null);const submission=useRef<{body:string;key:string}|null>(null);
 useEffect(()=>{if(!detail.data)return;const record=detail.data;
  setHead({category:String(record.category_id??meta.categories[0]?.id??''),department:record.department_id?String(record.department_id):'',date:String(record.expense_on??nairobiDate()),payee:record.payee_id?String(record.payee_id):'',recipient:record.recipient??'',order:record.order_id?String(record.order_id):'',method:record.payment_method??'Cash',purpose:record.purpose??''});
  setLines(record.items.length?record.items.map((item:Row)=>({description:item.description,quantity:item.quantity,unit_price:item.unit_price,discount:item.discount,tax:item.tax})):[{description:'',quantity:'1',unit_price:'',discount:'',tax:''}]);
 },[detail.data]);
 const set=(key:string,value:string)=>setHead({...head,[key]:value});
 const change=(index:number,key:string,value:string)=>setLines(lines.map((line,i)=>i===index?{...line,[key]:value}:line));
 const total=lines.reduce((sum,line)=>sum+(String(line.description).trim()?cents(previewTotal(line)):0n),0n);
 const suppliers=meta.payees.filter((p:Row)=>!p.staff_id);
 async function save(submit:boolean){
  if(busy)return;
  const paidTo=String(head.recipient??'').trim();
  if(!form.current?.checkValidity()){setError(new Error('invalid'));return;}
  const items=lines.filter(line=>String(line.description).trim()).map(line=>({description:String(line.description).trim(),quantity:String(line.quantity)||'1',unit_price:String(line.unit_price)||'0',discount:String(line.discount)||'0',tax:String(line.tax)||'0'}));
  if(!head.payee&&!paidTo){setError(new Error('payeeMissing'));return;}
  if(items.length===0){setError(new Error('invalid'));return;}
  const payload={p_id:id??null,p_category:Number(head.category),p_department:head.department?Number(head.department):null,p_expense_on:head.date,p_purpose:String(head.purpose),p_recipient:paidTo||null,p_payee:head.payee?Number(head.payee):null,p_order:head.order?Number(head.order):null,p_payment_method:head.method,p_items:items,p_submit:submit};
  const body=JSON.stringify({payload,files:files.map(file=>[file.name,file.size,file.lastModified])});
  if(submission.current?.body!==body)submission.current={body,key:crypto.randomUUID()};
  setBusy(true);setError(undefined);
  try{
   const savedId=await rpc<number>('finance_record_expense',{p_key:submission.current.key,...payload});
   for(const file of files)await uploadFinance(savedId,'support',profile.id,file);
   onSaved();
  }catch(e){setError(e);}finally{setBusy(false);}
 }
 return <Dialog title={t(id?'editExpense':'recordExpense')} onClose={()=>{if(!busy)onClose();}}>
  {id&&detail.isPending?<Loading/>:id&&detail.isError?<ErrorNotice error={detail.error}/>:<form ref={form} noValidate onSubmit={e=>{e.preventDefault();void save(true);}}>
   <div className="expense-grid">
    <Field label="expense_on"><input type="date" required max={nairobiDate()} value={String(head.date)} onChange={e=>set('date',e.target.value)}/></Field>
    <Field label="expenseCategory"><select required value={String(head.category)} onChange={e=>set('category',e.target.value)}>{meta.categories.map((c:Row)=><option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
    <Field label="department"><select value={String(head.department)} onChange={e=>set('department',e.target.value)}><option value="">{t('unassigned')}</option>{meta.departments.map((d:Row)=><option key={d.id} value={d.id}>{d.name}</option>)}</select></Field>
    <Field label="paymentMethod"><select value={String(head.method)} onChange={e=>set('method',e.target.value)}>{methods.map(m=><option key={m}>{m}</option>)}</select></Field>
   </div>
   <div className="expense-grid">
    <Field label="expensePayeeList"><select value={String(head.payee)} onChange={e=>set('payee',e.target.value)}><option value="">{t('expenseChoosePayee')}</option>{suppliers.map((p:Row)=><option key={p.id} value={p.id}>{p.name}</option>)}</select></Field>
    <Field label="expenseRecipientName"><input maxLength={200} value={String(head.recipient)} onChange={e=>set('recipient',e.target.value)}/></Field>
   </div>
   <p className="notice">{t('expensePayeeHint')}</p>
   <p className="chart-note">{t('expensePaidFromHint')}</p>
   <Field label="purpose"><textarea required maxLength={10000} rows={3} value={String(head.purpose)} onChange={e=>set('purpose',e.target.value)}/></Field>
   <h3>{t('expenseLines')}</h3>
   {lines.map((line,index)=><div className="expense-line" key={index}>
    <Field label="expenseDescription"><input required maxLength={300} value={String(line.description)} onChange={e=>change(index,'description',e.target.value)}/></Field>
    <Field label="quantity"><input inputMode="decimal" pattern={quantityPattern} required value={String(line.quantity)} onChange={e=>change(index,'quantity',e.target.value)}/></Field>
    <Field label="expenseUnitPrice"><input inputMode="decimal" pattern={moneyPattern} required value={String(line.unit_price)} onChange={e=>change(index,'unit_price',e.target.value)}/></Field>
    <Field label="discount"><input inputMode="decimal" pattern={moneyPattern} value={String(line.discount)} onChange={e=>change(index,'discount',e.target.value)}/></Field>
    <Field label="tax"><input inputMode="decimal" pattern={moneyPattern} value={String(line.tax)} onChange={e=>change(index,'tax',e.target.value)}/></Field>
    <div className="expense-line-total"><span>{t('expenseLineTotal')}</span><strong>{formatMoney(previewTotal(line),language)}</strong></div>
    {lines.length>1&&<button type="button" className="text-button" onClick={()=>setLines(lines.filter((_,i)=>i!==index))}>{t('removeLine')}</button>}
   </div>)}
   <div className="row-actions"><button type="button" disabled={lines.length>=50} onClick={()=>setLines([...lines,{description:'',quantity:'1',unit_price:'',discount:'',tax:''}])}><Plus size={15}/>{t('addExpenseLine')}</button></div>
   <div className="expense-line-total grand"><span>{t('expenseTotal')}</span><strong>{formatMoney(decimal(total),language)}</strong></div>
   <Field label="relatedOrder"><Lookup kind="orders" scope={scope} label="relatedOrder" value={String(head.order??'')} onChange={value=>set('order',value)} required={false}/></Field>
   <Field label="supportingDocuments"><input type="file" accept="application/pdf,image/jpeg,image/png,image/webp" multiple onChange={e=>setFiles(Array.from(e.target.files??[]))}/><small>{t('financeFileHint')}</small></Field>
   <p className="notice">{t('expenseFormHint')}</p>
   <p className="chart-note">{t('expenseDateHint')}</p>
   {!!error&&<ErrorNotice error={error}/ >}
   <div className="dialog-actions">
    <button type="button" disabled={busy} onClick={onClose}>{t('cancel')}</button>
    <button type="button" disabled={busy} onClick={()=>void save(false)}>{t('saveExpenseDraft')}</button>
    <button className="primary" disabled={busy||(!!id&&detail.isError)}>{t(busy?'saving':'submitExpense')}</button>
   </div>
  </form>}
 </Dialog>;
}

function ExpenseLists({onClose,onSaved}:{onClose:()=>void;onSaved:()=>void}){
 const {t}=usePreferences();
 const lists=useQuery({queryKey:['expense-lists'],queryFn:()=>rpc<Row>('finance_expense_lists'),retry:false});
 const [names,setNames]=useState<Row>({category:'',department:''});
 const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();
 async function call(kind:string,payload:Row){setBusy(true);setError(undefined);try{await rpc('finance_expense_settings',{p_key:crypto.randomUUID(),p_kind:kind,p_data:payload});await lists.refetch();setNames({...names,[kind]:''});}catch(e){setError(e);}finally{setBusy(false);}}
 return <Dialog title={t('manageExpenseLists')} onClose={()=>{if(!busy)onClose();}}>
  {lists.isPending?<Loading/>:lists.isError?<ErrorNotice error={lists.error} retry={()=>lists.refetch()}/>:<>
   <p className="chart-note">{t('manageExpenseListsHint')}</p>
   {([['category','categories'],['department','departments']] as const).map(([kind,listKey])=><section className="expense-list-group" key={kind}>
    <h3>{t(kind==='category'?'expenseCategory':'department')}</h3>
    <div className="expense-list-items">{(lists.data[listKey]??[]).map((row:Row)=><div key={String(row.id)}><span className={row.active?'':'retired'}>{row.name}</span><button disabled={busy} onClick={()=>void call(kind,{id:Number(row.id),active:!row.active})}>{t(row.active?'retire':'reinstate')}</button></div>)}</div>
    <form noValidate onSubmit={e=>{e.preventDefault();const name=String(names[kind]??'').trim();if(!name){setError(new Error('invalid'));return;}void call(kind,{name});}}>
     <Field label={kind==='category'?'newCategory':'newDepartment'}><input maxLength={120} value={String(names[kind]??'')} onChange={e=>setNames({...names,[kind]:e.target.value})}/></Field>
     <button className="primary" disabled={busy}>{t('add')}</button>
    </form>
   </section>)}
  </>}
  {!!error&&<ErrorNotice error={error}/ >}
  <div className="dialog-actions"><button className="primary" onClick={onSaved}>{t('done')}</button></div>
 </Dialog>;
}

// The preview mirrors the server's round(quantity × unit price − discount + tax, 2), so the officer sees the
// figure the register will store; SQL always recomputes the authoritative total.
function micro(value:string){const [whole='0',fraction='']=(value||'0').split('.');return BigInt(whole)*1000000n+BigInt((fraction+'000000').slice(0,6));}
function previewTotal(line:Row){
 const raw=micro(String(line.quantity||'1'))*micro(String(line.unit_price||'0'))-micro(String(line.discount||'0'))*1000000n+micro(String(line.tax||'0'))*1000000n;
 return raw>0n?decimal((raw+5000000000n)/10000000000n):'0.00';
}

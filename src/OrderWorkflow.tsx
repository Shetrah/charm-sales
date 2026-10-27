import { useEffect, useMemo, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import {
  Camera, Check, ChevronLeft, ChevronRight, Download, ExternalLink, FileText,
  History, Lock, PackageCheck, PenLine, Send, ShieldCheck, Trash2, ZoomIn, ZoomOut,
} from 'lucide-react';
import { Dialog, ErrorNotice, Field, Lookup, Loading, Status } from './components';
import { usePreferences } from './i18n';
import { rpc, supabase } from './lib/supabase';
import { type Profile, type Row } from './lib/data';
import { formatBusinessDateTime } from './lib/dates';
import { cents, decimal, lineTotal } from './lib/money';
import {
  documentExtension, formatBytes, openPrivateFile, prepareDocument, uploadPrivate, validateDocument,
} from './lib/documents';

export type OrderDocument = {
  id:number;order_id:number;kind:'contract'|'supporting'|'amendment';storage_path:string;file_name:string;
  mime_type:string;size_bytes:number|null;page_count:number|null;document_key:string;contract_version:number;uploaded_at:string;
};
export type ContractVersion = {
  id:number;order_id:number;version:number;reference:string;signed_by:string;terms:string;customer_type:string;
  status:string;submitted_by:number;submitted_at:string;amendment_reason:string|null;
  documents:Array<{id:number;name:string;kind:string;mime:string;pages:number|null}>;
};
type PendingUpload = {
  id:string;kind:'contract'|'supporting';file:File;path:string;prepared?:File;uploaded?:boolean;
  stage:'preparing'|'uploading'|'saving'|'error';progress:number;error?:unknown;
};

const stamp=(value:string|null|undefined,language:'en'|'zh')=>formatBusinessDateTime(value,language);
const mimeLabel=(mime:string)=>mime==='application/pdf'?'PDF':mime==='image/png'?'PNG':mime==='image/webp'?'WebP':'JPEG';
export const contractStatusKey=(status:string)=>status==='submitted'?'contractSubmitted':status==='approved'?'contractApproved':status==='rejected'?'contractRejected':status==='amendment_required'?'contractAmendmentRequired':status==='superseded'?'contractSuperseded':'contractDraft';

function useOrderDocuments(orderId:number|null,scope:string){
 return useQuery({queryKey:[scope,'order-docs',orderId],enabled:!!orderId,queryFn:async()=>{
  const {data,error}=await supabase!.from('order_documents').select('*').eq('order_id',orderId).order('id');
  if(error)throw new Error(error.message);return (data??[]) as OrderDocument[];
 }});
}
function useOrderVersions(orderId:number|null,scope:string){
 return useQuery({queryKey:[scope,'order-versions',orderId],enabled:!!orderId,queryFn:async()=>{
  const {data,error}=await supabase!.from('order_contract_versions').select('*').eq('order_id',orderId).order('version',{ascending:false});
  if(error)throw new Error(error.message);return (data??[]) as ContractVersion[];
 }});
}
async function fetchOrderStatus(id:number){
 const {data,error}=await supabase!.from('orders').select('id,status,contract_status,contract_version,contract_file_count,contract_page_count,contract_file_name,receipt_status').eq('id',id).limit(1);
 if(error)throw new Error(error.message);return data?.[0] as Row|undefined;
}

export function ContractSummary({row,onOpen}:{row:Row;onOpen?:(documentId?:number)=>void}){
 const {t}=usePreferences();const status=String(row.contract_status??'draft');const count=Number(row.contract_file_count??0);
 return <div className="contract-summary">
  <span className="contract-summary-icon"><FileText size={17}/></span>
  <div className="contract-summary-text">
   <span className="contract-summary-title"><Status value={status}/>{Number(row.contract_version??0)>0&&<em>{t('versionLabel')} {row.contract_version}</em>}</span>
   {count>0?<small>{row.contract_file_name||t('noContractFile')} · {count} {t(count===1?'documentFile':'documentFiles')}{Number(row.contract_page_count??0)>0?` · ${row.contract_page_count} ${t(Number(row.contract_page_count)===1?'documentPage':'documentPages')}`:''}</small>:<small>{t('noContract')}</small>}
  </div>
  {onOpen&&<button type="button" className="text-button contract-open" onClick={()=>onOpen()}>{t('viewContract')}</button>}
 </div>;
}

export function ContractPreview({orderId,scope,initialId,onClose,order}:{orderId:number;scope:string;initialId?:number|null;onClose:()=>void;order?:Row|null}){
 const {t,language}=usePreferences();const docs=useOrderDocuments(orderId,scope);const versions=useOrderVersions(orderId,scope);
 const [selected,setSelected]=useState<number|null>(initialId??null);const [url,setUrl]=useState('');const [zoom,setZoom]=useState(1);const [error,setError]=useState<unknown>();const [downloading,setDownloading]=useState(false);
 useEffect(()=>{if(selected==null&&docs.data?.length)setSelected(docs.data[0].id);},[docs.data,selected]);
 const document=docs.data?.find(item=>item.id===selected)??null;const index=docs.data?.findIndex(item=>item.id===document?.id)??-1;
 useEffect(()=>{let alive=true;setUrl('');setError(undefined);if(!document)return;openPrivateFile(document.storage_path,120).then(next=>{if(alive)setUrl(next);}).catch(next=>{if(alive)setError(next);});return()=>{alive=false;};},[document?.id,document?.storage_path]);
 async function download(){if(!document)return;setDownloading(true);setError(undefined);try{const next=await openPrivateFile(document.storage_path,60,document.file_name);const link=window.document.createElement('a');link.href=next;link.download=document.file_name;link.rel='noopener';window.document.body.appendChild(link);link.click();link.remove();}catch(next){setError(next);}finally{setDownloading(false);}}
 const move=(direction:number)=>{if(!docs.data?.length)return;const next=(index+direction+docs.data.length)%docs.data.length;setSelected(docs.data[next].id);setZoom(1);};
 return <Dialog title={`${t('contract')} · ${t('orders')} #${orderId}`} onClose={onClose}>
  {order&&<ContractSummary row={order}/>}
  {docs.isPending?<Loading/>:docs.isError?<ErrorNotice error={docs.error} retry={()=>docs.refetch()}/>:!docs.data?.length?<div className="state"><FileText size={30}/><p>{t('noDocuments')}</p></div>:<>
   <div className="doc-preview-head">
    <div className="doc-preview-title"><strong>{document?.file_name}</strong><small>{document?`${mimeLabel(document.mime_type)} · ${formatBytes(document.size_bytes)}${document.page_count?` · ${document.page_count} ${t(document.page_count===1?'documentPage':'documentPages')}`:''} · ${stamp(document.uploaded_at,language)}`:''}</small></div>
    <div className="doc-preview-tools">
     <button type="button" className="icon-button" aria-label={t('previousDocument')} disabled={(docs.data?.length??0)<2} onClick={()=>move(-1)}><ChevronLeft size={18}/></button>
     <span>{index+1} {t('of')} {docs.data?.length}</span>
     <button type="button" className="icon-button" aria-label={t('nextDocument')} disabled={(docs.data?.length??0)<2} onClick={()=>move(1)}><ChevronRight size={18}/></button>
    </div>
   </div>
   {document?.mime_type.startsWith('image/')&&<div className="doc-zoom"><button type="button" className="icon-button" aria-label={t('zoomOut')} onClick={()=>setZoom(value=>Math.max(.5,Math.round((value-.25)*100)/100))}><ZoomOut size={18}/></button><button type="button" className="text-button" onClick={()=>setZoom(1)}>{t('resetZoom')}</button><button type="button" className="icon-button" aria-label={t('zoomIn')} onClick={()=>setZoom(value=>Math.min(3,Math.round((value+.25)*100)/100))}><ZoomIn size={18}/></button></div>}
   {!!error&&<ErrorNotice error={error}/>}
   <div className="doc-viewer">
    {!url?<Loading/>:document?.mime_type==='application/pdf'?<iframe className="doc-iframe" src={url} title={document.file_name}/>:<div className="doc-image-scroll"><img src={url} alt={document?.file_name??t('contract')} style={{transform:`scale(${zoom})`}}/></div>}
   </div>
   <div className="doc-preview-actions">
    <button type="button" onClick={()=>document&&window.open(url||undefined,'_blank','noopener,noreferrer')} disabled={!url}><ExternalLink size={16}/>{t('openInNewTab')}</button>
    <button type="button" onClick={()=>void download()} disabled={downloading||!url}><Download size={16}/>{t('downloadFile')}</button>
   </div>
   <p className="doc-private-hint"><ShieldCheck size={14}/>{t('documentViewerHint')}</p>
  </>}
  {!!versions.data?.length&&<section className="contract-history"><h3><History size={17}/>{t('contractHistory')}</h3>{versions.data.map(version=><details key={version.id} className="version-row"><summary><strong>{t('versionLabel')} {version.version}</strong><Status value={version.status}/><span>{stamp(version.submitted_at,language)}</span><small>{version.documents?.length??0} {t((version.documents?.length??0)===1?'documentFile':'documentFiles')}</small></summary><dl className="contract-meta"><div><dt>{t('contractReference')}</dt><dd>{version.reference}</dd></div><div><dt>{t('contractSignedBy')}</dt><dd>{version.signed_by}</dd></div><div><dt>{t('customerType')}</dt><dd>{t(version.customer_type==='wholesaler'?'orderTypeWholesaler':'orderTypeRetailer')}</dd></div>{version.amendment_reason&&<div><dt>{t('amendmentReason')}</dt><dd>{version.amendment_reason}</dd></div>}</dl><p className="contract-terms-read">{version.terms}</p></details>)}</section>}
  <div className="dialog-actions"><button type="button" onClick={onClose}>{t('close')}</button></div>
 </Dialog>;
}

export function OrderContractPanel({row,scope,profile,onPreview,onEdit,onSaved}:{row:Row;scope:string;profile?:Profile;onPreview:(documentId?:number)=>void;onEdit?:()=>void;onSaved:()=>void}){
 const {t,language}=usePreferences();const qc=useQueryClient();const docs=useOrderDocuments(Number(row.id),scope);const versions=useOrderVersions(Number(row.id),scope);
 const [action,setAction]=useState<'amend'|'receive'|null>(null);const [reason,setReason]=useState('');const [notes,setNotes]=useState('');const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();const [notice,setNotice]=useState('');
 const status=String(row.contract_status??'draft');const canAccess=profile?.role==='admin'||(profile?.role==='salesperson'&&row.salesperson_id===profile?.id);
 const draftEditable=row.status==='draft'&&['draft','amendment_required'].includes(status);
 const canAmend=!!canAccess&&(row.status==='pending'||row.status==='rejected'||(row.status==='draft'&&status==='submitted'));
 const canReceive=profile?.role==='admin'&&row.status==='confirmed'&&status==='approved'&&row.receipt_status!=='received';
 async function run(work:()=>Promise<unknown>,message:string){setBusy(true);setError(undefined);try{await work();setNotice(t(message));setAction(null);setReason('');setNotes('');await qc.invalidateQueries({queryKey:[scope,'order-docs',row.id]});await qc.invalidateQueries({queryKey:[scope,'order-versions',row.id]});onSaved();}catch(next){setError(next);}finally{setBusy(false);}}
 return <section className="contract-panel">
  <div className="panel-title"><div><span className="eyebrow">{t('contractFirst')}</span><h3>{t('contractDetails')}</h3></div><Status value={status}/></div>
  {notice&&<div className="notice" role="status">{notice}</div>}
  <dl className="contract-meta">
   <div><dt>{t('contractReference')}</dt><dd>{row.contract_reference??'—'}</dd></div>
   <div><dt>{t('contractSignedBy')}</dt><dd>{row.contract_signed_by??'—'}</dd></div>
   <div><dt>{t('customerType')}</dt><dd>{t(row.customer_type==='wholesaler'?'orderTypeWholesaler':'orderTypeRetailer')}</dd></div>
   <div><dt>{t('versionLabel')}</dt><dd>{row.contract_version?`v${row.contract_version}`:'—'}</dd></div>
   <div><dt>{t('contractSubmittedAt')}</dt><dd>{stamp(row.contract_submitted_at,language)}</dd></div>
   <div><dt>{t('contractSubmittedBy')}</dt><dd>{row.contract_submitted_by?(row._people?.[row.contract_submitted_by]??`#${row.contract_submitted_by}`):'—'}</dd></div>
   <div><dt>{t('contractApprovedAt')}</dt><dd>{stamp(row.contract_approved_at,language)}</dd></div>
   <div><dt>{t('contractApprovedBy')}</dt><dd>{row.contract_approved_by?(row._people?.[row.contract_approved_by]??`#${row.contract_approved_by}`):'—'}</dd></div>
   <div><dt>{t('receiptStatus')}</dt><dd><Status value={row.receipt_status==='received'?'received':'receiptPending'}/></dd></div>
  </dl>
  {row.contract_terms&&<details className="contract-terms"><summary>{t('contractTerms')}</summary><p>{row.contract_terms}</p></details>}
  <div className="contract-document-head"><h4>{t('contractDocuments')}</h4><button type="button" className="text-button" onClick={()=>onPreview()} disabled={!row.contract_file_count}><FileText size={15}/>{t('viewContract')}</button></div>
  {docs.isPending?<Loading/>:docs.isError?<ErrorNotice error={docs.error}/>:!docs.data?.length?<p className="muted-line">{t('noDocuments')}</p>:<div className="document-list">{docs.data.map(item=><article key={item.id} className="document-row"><span className="document-icon"><FileText size={18}/></span><div><strong>{item.file_name}</strong><small>{item.kind==='contract'?t('documentContract'):t('documentSupporting')} · {mimeLabel(item.mime_type)} · {formatBytes(item.size_bytes)}{item.page_count?` · ${item.page_count} ${t(item.page_count===1?'documentPage':'documentPages')}`:''}</small></div><button type="button" className="text-button" onClick={()=>onPreview(item.id)}>{t('viewContract')}</button></article>)}</div>}
  {!!versions.data?.length&&<details className="contract-history"><summary><History size={16}/>{t('contractHistory')} ({versions.data.length})</summary>{versions.data.map(version=><article key={version.id} className="version-line"><strong>{t('versionLabel')} {version.version}</strong><Status value={version.status}/><span>{stamp(version.submitted_at,language)}</span>{version.amendment_reason&&<small>{version.amendment_reason}</small>}</article>)}</details>}
  {row.receipt_notes&&<p className="notice">{t('receiptNotes')}: {row.receipt_notes}</p>}
  {!!error&&<ErrorNotice error={error}/>}
  {action==='amend'&&<div className="contract-action-box">
   <p>{t('amendmentReasonHint')}</p>
   <Field label="amendmentReason"><textarea required minLength={5} maxLength={1000} value={reason} onChange={event=>setReason(event.target.value)}/></Field>
   <div className="row-actions"><button type="button" onClick={()=>setAction(null)} disabled={busy}>{t('cancel')}</button><button type="button" className="primary" disabled={busy||reason.trim().length<5} onClick={()=>void run(()=>rpc('amend_order_contract',{p_id:row.id,p_reason:reason.trim()}),'amendmentRequested')}>{t('requestAmendment')}</button></div>
  </div>}
  {action==='receive'&&<div className="contract-action-box">
   <p>{t('confirmReceiptHint')}</p>
   <Field label="receiptNotes"><textarea maxLength={2000} value={notes} onChange={event=>setNotes(event.target.value)}/></Field>
   <div className="row-actions"><button type="button" onClick={()=>setAction(null)} disabled={busy}>{t('cancel')}</button><button type="button" className="primary" disabled={busy} onClick={()=>void run(()=>rpc('confirm_order_receipt',{p_id:row.id,p_notes:notes.trim()||null}),'orderReceived')}>{t('confirmReceiptAction')}</button></div>
  </div>}
  <div className="contract-panel-actions">
   {draftEditable&&onEdit&&<button type="button" className="primary" onClick={onEdit}><PenLine size={16}/>{t('contractDetails')}</button>}
   {canAmend&&action==null&&<button type="button" onClick={()=>setAction('amend')}><PenLine size={16}/>{t('requestAmendment')}</button>}
   {canReceive&&action==null&&<button type="button" className="primary" onClick={()=>setAction('receive')}><PackageCheck size={16}/>{t('confirmReceipt')}</button>}
   {row.status==='pending'&&status==='submitted'&&<p className="doc-private-hint"><Lock size={14}/>{t('contractLockedHint')}</p>}
  </div>
 </section>;
}

export function OrderReviewContract({row,scope,onPreview}:{row:Row;scope:string;onPreview:(documentId?:number)=>void}){
 const {t}=usePreferences();const docs=useOrderDocuments(Number(row.id),scope);
 return <section className="contract-review-summary">
  <ContractSummary row={row} onOpen={onPreview}/>
  {docs.isPending?<Loading/>:docs.isError?<ErrorNotice error={docs.error}/>:<div className="review-document-list">{docs.data?.filter(item=>item.kind==='contract').map(item=><button type="button" key={item.id} className="review-document" onClick={()=>onPreview(item.id)}><FileText size={17}/><span>{item.file_name}</span><small>{formatBytes(item.size_bytes)}{item.page_count?` · ${item.page_count} ${t('documentPages')}`:''}</small></button>)}</div>}
 </section>;
}

export function OrderEditor({scope,profile,row,onClose,onSaved}:{scope:string;profile:Profile;row:Row|null;onClose:()=>void;onSaved:()=>void}){
 const {t,language}=usePreferences();const qc=useQueryClient();
 const [clientId,setClientId]=useState(String(row?.client_id??''));const [customerType,setCustomerType]=useState(String(row?.customer_type??'retailer'));
 const [dueDate,setDueDate]=useState(String(row?.due_date??''));const [lines,setLines]=useState([{product_id:'',quantity:'1',unit:'bottle',unit_price:''}]);
 const [draftId,setDraftId]=useState<number|null>(row?.status==='draft'&&row?.id?Number(row.id):null);
 const [orderStatus,setOrderStatus]=useState(String(row?.status??'draft'));const [contractStatus,setContractStatus]=useState(String(row?.contract_status??'draft'));
 const [reference,setReference]=useState(String(row?.contract_reference??''));const [signedBy,setSignedBy]=useState(String(row?.contract_signed_by??''));const [terms,setTerms]=useState(String(row?.contract_terms??''));
 const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();const [notice,setNotice]=useState('');
 const [reviewOpen,setReviewOpen]=useState(false);const [confirmed,setConfirmed]=useState(false);
 const [pending,setPending]=useState<PendingUpload[]>([]);const [removeId,setRemoveId]=useState<number|null>(null);const [previewId,setPreviewId]=useState<number|null>(null);const [previewOpen,setPreviewOpen]=useState(false);
 const items=useQuery({queryKey:[scope,'order-edit-items',row?.id],enabled:!!row?.id,queryFn:async()=>{const {data,error}=await supabase!.from('order_items').select('product_id,quantity,unit,unit_price').eq('order_id',row!.id).order('id');if(error)throw new Error(error.message);return data as Row[];}});
 useEffect(()=>{if(items.data?.length)setLines(items.data.map(item=>({product_id:String(item.product_id),quantity:String(item.quantity),unit:String(item.unit),unit_price:String(item.unit_price)})));},[items.data]);
 const docs=useOrderDocuments(draftId,scope);const versions=useOrderVersions(draftId,scope);
 const client=useQuery({queryKey:[scope,'client-name',clientId],enabled:/^\d+$/.test(clientId),queryFn:async()=>{const {data,error}=await supabase!.from('clients').select('id,name').eq('id',Number(clientId)).limit(1);if(error)throw new Error(error.message);return data?.[0] as Row|undefined;}});
 const editorKey=useRef<{body:string;key:string}|null>(null);const submitKey=useRef(crypto.randomUUID());
 const contractDocs=useMemo(()=>docs.data?.filter(item=>item.kind==='contract')??[],[docs.data]);
 const supportingDocs=useMemo(()=>docs.data?.filter(item=>item.kind!=='contract')??[],[docs.data]);
 const editable=orderStatus==='draft'&&['draft','amendment_required'].includes(contractStatus);
 const contractSubmitted=contractStatus==='submitted';
 const moneyValid=(value:string)=>{try{return cents(value)>=1n;}catch{return false;}};
 const validLines=lines.length>0&&lines.every(line=>!!line.product_id&&Number(line.quantity)>=1&&Number(line.quantity)<=100000&&moneyValid(line.unit_price));
 const contractValuesValid=reference.trim().length>=3&&signedBy.trim().length>=2&&terms.trim().length>=20;
 const missing=useMemo(()=>{
  const result:string[]=[];if(!clientId)result.push('missingClient');if(!validLines)result.push('missingOrderLines');
  if(reference.trim().length<3)result.push('contractReferenceRequired');if(signedBy.trim().length<2)result.push('contractSignedByRequired');
  if(terms.trim().length<20)result.push('contractTermsRequired');if(draftId&&!docs.isPending&&contractDocs.length===0)result.push('contractDocumentRequired');
  return result;
 },[clientId,validLines,reference,signedBy,terms,draftId,docs.isPending,contractDocs.length]);
 let total='—';try{total=decimal(lines.reduce((sum,line)=>sum+cents(lineTotal(line.unit_price,Number(line.quantity||0))),0n));}catch{/* incomplete line */}
 function addFiles(files:FileList|null,kind:'contract'|'supporting'){if(!files?.length)return;if(!draftId){setNotice(t('orderDraftHint'));return;}for(const file of Array.from(files)){try{validateDocument(file);}catch(next){setError(next);continue;}const item:PendingUpload={id:crypto.randomUUID(),kind,file,path:'',stage:'preparing',progress:0};setPending(current=>[...current,item]);void processUpload(item);}}
 async function processUpload(item:PendingUpload){const update=(patch:Partial<PendingUpload>)=>setPending(current=>current.map(entry=>entry.id===item.id?{...entry,...patch}:entry));try{
  let prepared=item.prepared;if(!prepared){update({stage:'preparing'});prepared=await prepareDocument(item.file);}
  const path=item.path||`orders/${draftId}/${item.id}.${documentExtension(prepared.type)}`;
  update({prepared,path,stage:'uploading'});
  if(!item.uploaded){await uploadPrivate(path,prepared,progress=>update({progress}));}
  update({uploaded:true,stage:'saving'});
  await rpc('add_order_document',{p_key:item.id,p_id:draftId,p_kind:item.kind,p_path:path,p_name:prepared.name||item.file.name,p_mime:prepared.type,p_size:prepared.size,p_pages:prepared.type.startsWith('image/')?1:null});
  await qc.invalidateQueries({queryKey:[scope,'order-docs',draftId]});
  setPending(current=>current.filter(entry=>entry.id!==item.id));
 }catch(next){update({stage:'error',error:next});}}
 async function persistOrder(){if(!clientId)throw new Error('missingClient');if(!validLines)throw new Error('missingOrderLines');const payload={p_id:draftId,p_client:Number(clientId),p_due:dueDate||null,p_customer_type:customerType,p_items:lines.map(line=>({product_id:Number(line.product_id),quantity:Number(line.quantity),unit:line.unit,unit_price:line.unit_price}))};const body=JSON.stringify(payload);if(!editorKey.current||editorKey.current.body!==body)editorKey.current={body,key:crypto.randomUUID()};const id=await rpc<number>('save_order_draft',{...payload,p_key:editorKey.current.key});setDraftId(id);if(contractValuesValid)await rpc('save_order_contract',{p_key:crypto.randomUUID(),p_id:id,p_reference:reference.trim(),p_signed_by:signedBy.trim(),p_terms:terms.trim(),p_customer_type:customerType});return id;}
 async function saveDraft(){setBusy(true);setError(undefined);setNotice('');try{const id=await persistOrder();editorKey.current={body:JSON.stringify({p_id:id,p_client:Number(clientId),p_due:dueDate||null,p_customer_type:customerType,p_items:lines.map(line=>({product_id:Number(line.product_id),quantity:Number(line.quantity),unit:line.unit,unit_price:line.unit_price}))}),key:editorKey.current!.key};setNotice(t(contractValuesValid?'draftSavedWithContract':'draftSaved'));await qc.invalidateQueries({queryKey:[scope,'order-docs',id]});}catch(next){setError(next);}finally{setBusy(false);}}
 async function submitContract(){if(missing.length){setError(new Error('contractIncomplete'));setReviewOpen(true);return;}if(!confirmed){setError(new Error('contractConfirmationRequired'));return;}setBusy(true);setError(undefined);try{const id=await persistOrder();await rpc('submit_order_contract',{p_key:submitKey.current,p_id:id,p_confirm:true});const fresh=await fetchOrderStatus(id);setContractStatus(String(fresh?.contract_status??'submitted'));setOrderStatus(String(fresh?.status??'draft'));setReviewOpen(false);setConfirmed(false);setNotice(t('contractSubmittedNotice'));await qc.invalidateQueries({queryKey:[scope,'order-docs',id]});await qc.invalidateQueries({queryKey:[scope,'order-versions',id]});}catch(next){setError(next);}finally{setBusy(false);}}
 async function submitOrder(){if(!draftId)return;setBusy(true);setError(undefined);try{await rpc('submit_order_draft',{p_id:draftId});setOrderStatus('pending');onSaved();}catch(next){setError(next);}finally{setBusy(false);}}
 async function removeDocument(id:number){setBusy(true);setError(undefined);try{await rpc('remove_order_document',{p_id:draftId,p_document_id:id});setRemoveId(null);await qc.invalidateQueries({queryKey:[scope,'order-docs',draftId]});}catch(next){setError(next);}finally{setBusy(false);}}
 return <Dialog title={draftId?`${t('orders')} · #${draftId}`:t('create')} onClose={onClose}>
  <form noValidate onSubmit={event=>{event.preventDefault();if(editable)void saveDraft();}}>
   <ol className="order-steps"><li className="active">{t('orderStepDetails')}</li><li>{t('orderStepContract')}</li><li>{t('orderStepDocuments')}</li><li>{t('orderStepReview')}</li></ol>
   <p className="notice">{t('orderDraftHint')}</p>
   <section className="order-step-section"><h3><span>1</span>{t('orderStepDetails')}</h3>
    <Field label="clientSearch"><Lookup kind="clients" scope={scope} value={clientId} onChange={setClientId} label="clientSearch" required/></Field>
    <div className="form-grid"><Field label="customerType"><select disabled={!editable} value={customerType} onChange={event=>setCustomerType(event.target.value)}><option value="retailer">{t('orderTypeRetailer')}</option><option value="wholesaler">{t('orderTypeWholesaler')}</option></select></Field><Field label="due_date"><input type="date" disabled={!editable} value={dueDate} onChange={event=>setDueDate(event.target.value)}/></Field></div>
    <h3 className="inline-heading">{t('items')}</h3>
    {lines.map((line,index)=><div className="order-line" key={index}>
     <Field label="product_id"><Lookup kind="products" scope={scope} label="productSearch" value={line.product_id} onChange={value=>setLines(current=>current.map((item,itemIndex)=>itemIndex===index?{...item,product_id:value}:item))} required/></Field>
     <div className="form-grid">{(['quantity','unit','unit_price'] as const).map(key=><Field key={key} label={key}>{key==='unit'?<select disabled={!editable} value={line[key]} onChange={event=>setLines(current=>current.map((item,itemIndex)=>itemIndex===index?{...item,unit:event.target.value}:item))}><option value="bottle">{t('bottle')}</option><option value="carton">{t('cartonUnit')}</option></select>:<input required disabled={!editable} type="number" min={key==='quantity'?1:.01} max={key==='quantity'?100000:999999999999} step={key==='quantity'?1:.01} value={line[key]} onChange={event=>setLines(current=>current.map((item,itemIndex)=>itemIndex===index?{...item,[key]:event.target.value}:item))}/>}</Field>)}</div>
     {lines.length>1&&<button type="button" className="text-button" disabled={!editable} onClick={()=>setLines(current=>current.filter((_,itemIndex)=>itemIndex!==index))}>{t('remove')}</button>}
    </div>)}
    <button type="button" disabled={!editable||lines.length>=100} onClick={()=>setLines(current=>[...current,{product_id:'',quantity:'1',unit:'bottle',unit_price:''}])}>{t('addLine')}</button>
    <p className="order-total">{t('total')}: {total}</p>
   </section>
   <section className="order-step-section"><h3><span>2</span>{t('orderStepContract')}</h3>
    <div className="form-grid"><Field label="contractReference"><input required disabled={!editable} minLength={3} maxLength={120} value={reference} onChange={event=>setReference(event.target.value)}/><small>{t('contractReferenceHint')}</small></Field><Field label="contractSignedBy"><input required disabled={!editable} minLength={2} maxLength={200} value={signedBy} onChange={event=>setSignedBy(event.target.value)}/><small>{t('contractSignedByHint')}</small></Field></div>
    <Field label="contractTerms"><textarea required disabled={!editable} minLength={20} maxLength={20000} value={terms} onChange={event=>setTerms(event.target.value)}/><small>{t('contractTermsHint')}</small></Field>
   </section>
   <section className="order-step-section"><h3><span>3</span>{t('orderStepDocuments')}</h3>
    <p className="muted-line">{t('documentTypesHint')}</p>
    {!draftId&&<p className="notice">{t('orderDraftHint')}</p>}
    {contractSubmitted&&<p className="notice"><Lock size={14}/>{t('contractLockedHint')}</p>}
    {editable&&draftId&&<div className="document-uploaders">
     <label className={`doc-button ${busy?'disabled':''}`}><Camera size={18}/><span>{t('captureWithCamera')}</span><input className="sr-only" type="file" accept="image/*" capture="environment" disabled={busy} onChange={event=>{addFiles(event.target.files,'contract');event.target.value='';}}/></label>
     <Field label="addContractDocument"><input type="file" accept="image/jpeg,image/png,image/webp,application/pdf" disabled={busy} onChange={event=>{addFiles(event.target.files,'contract');event.target.value='';}}/></Field>
    </div>}
    <small className="muted-line">{t('cameraHint')}</small>
    {editable&&draftId&&<Field label="addSupportingDocument"><input type="file" multiple accept="image/jpeg,image/png,image/webp,application/pdf" disabled={busy} onChange={event=>{addFiles(event.target.files,'supporting');event.target.value='';}}/></Field>}
    {!!pending.length&&<div className="pending-uploads">{pending.map(item=><article key={item.id} className={`pending-upload ${item.stage}`}><div><strong>{item.file.name}</strong><small>{item.stage==='preparing'?t('documentCompressing'):item.stage==='saving'?t('documentSaving'):item.stage==='error'?t('documentFailed'):t('documentUploading')}</small></div>{item.stage==='error'?<button type="button" onClick={()=>void processUpload(item)}>{t('retryUpload')}</button>:<div className="upload-progress"><span style={{width:`${item.stage==='saving'?100:item.progress}%`}}/></div>}{!!item.error&&<ErrorNotice error={item.error}/>}</article>)}</div>}
    <div className="document-list">{contractDocs.map(item=><article key={item.id} className="document-row"><span className="document-icon"><FileText size={18}/></span><div><strong>{item.file_name}</strong><small>{t('documentContract')} · {mimeLabel(item.mime_type)} · {formatBytes(item.size_bytes)}{item.page_count?` · ${item.page_count} ${t('documentPages')}`:''}</small></div><button type="button" className="text-button" onClick={()=>{setPreviewId(item.id);setPreviewOpen(true);}}>{t('viewContract')}</button>{editable&&(removeId===item.id?<><button type="button" className="text-button danger" disabled={busy} onClick={()=>void removeDocument(item.id)}>{t('removeDocument')}</button><button type="button" className="text-button" onClick={()=>setRemoveId(null)}>{t('cancel')}</button></>:<button type="button" className="text-button" disabled={busy} onClick={()=>setRemoveId(item.id)}><Trash2 size={14}/>{t('removeDocument')}</button>)}</article>)}</div>
    {!!supportingDocs.length&&<><h4>{t('supportingDocuments')}</h4><div className="document-list">{supportingDocs.map(item=><article key={item.id} className="document-row"><span className="document-icon"><FileText size={18}/></span><div><strong>{item.file_name}</strong><small>{t('documentSupporting')} · {mimeLabel(item.mime_type)} · {formatBytes(item.size_bytes)}</small></div><button type="button" className="text-button" onClick={()=>{setPreviewId(item.id);setPreviewOpen(true);}}>{t('details')}</button>{editable&&(removeId===item.id?<button type="button" className="text-button danger" disabled={busy} onClick={()=>void removeDocument(item.id)}>{t('removeDocument')}</button>:<button type="button" className="text-button" disabled={busy} onClick={()=>setRemoveId(item.id)}><Trash2 size={14}/>{t('removeDocument')}</button>)}</article>)}</div></>}
   </section>
   {reviewOpen&&<section className="order-step-section contract-review-section"><h3><span>4</span>{t('orderStepReview')}</h3>
    {!!missing.length&&<div className="notice error" role="alert"><strong>{t('missingBeforeSubmit')}</strong><ul>{missing.map(key=><li key={key}>{t(key)}</li>)}</ul></div>}
    <dl className="contract-meta"><div><dt>{t('client_id')}</dt><dd>{client.data?.name??`#${clientId}`}</dd></div><div><dt>{t('customerType')}</dt><dd>{t(customerType==='wholesaler'?'orderTypeWholesaler':'orderTypeRetailer')}</dd></div><div><dt>{t('contractReference')}</dt><dd>{reference||'—'}</dd></div><div><dt>{t('contractSignedBy')}</dt><dd>{signedBy||'—'}</dd></div><div><dt>{t('documentFiles')}</dt><dd>{contractDocs.length}</dd></div></dl>
    <p className="contract-terms-read">{terms||'—'}</p>
    <label className="check-line"><input type="checkbox" checked={confirmed} onChange={event=>setConfirmed(event.target.checked)}/>{t('confirmContractSubmission')}</label>
    <div className="row-actions"><button type="button" onClick={()=>setReviewOpen(false)} disabled={busy}>{t('cancel')}</button><button type="button" className="primary" disabled={busy||missing.length>0||!confirmed} onClick={()=>void submitContract()}>{busy?t('saving'):t('confirmSubmitContractAction')}</button></div>
   </section>}
   {!!error&&<ErrorNotice error={error}/>}{!!notice&&<div className="notice" role="status">{notice}</div>}
   {!!versions.data?.length&&contractSubmitted&&<p className="doc-private-hint"><History size={14}/>{t('versionLabel')} {versions.data[0]?.version} · {t('contractSubmittedNotice')}</p>}
   <div className="dialog-actions">
    <button type="button" onClick={onClose} disabled={busy}>{t('close')}</button>
    {editable&&<button type="button" disabled={busy} onClick={()=>void saveDraft()}>{t(busy?'saving':draftId?'saveDraftChanges':'saveDraft')}</button>}
    {editable&&!contractSubmitted&&<button type="button" className="primary" disabled={busy} onClick={()=>setReviewOpen(true)}><Send size={16}/>{t('reviewContract')}</button>}
    {contractSubmitted&&orderStatus==='draft'&&<button type="button" className="primary" disabled={busy} onClick={()=>void submitOrder()}><Check size={16}/>{t('submitOrder')}</button>}
   </div>
  </form>
  {previewOpen&&draftId&&<ContractPreview orderId={draftId} scope={scope} initialId={previewId} onClose={()=>setPreviewOpen(false)}/>}
 </Dialog>;
}

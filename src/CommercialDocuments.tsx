import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Printer } from 'lucide-react';
import type { Row } from './lib/data';
import { formatBusinessDate, formatBusinessDateTime } from './lib/dates';
import { formatMoney } from './lib/presentation';
import { rpc, supabase } from './lib/supabase';
import { usePreferences } from './i18n';
import { Dialog, ErrorNotice, Field, Loading } from './components';

const LOGO = '/assets/charm-logo.png';
type Kind = 'invoice' | 'delivery';

const money = (value:unknown, language:string) => formatMoney(String(Number(value ?? 0).toFixed(2)), language);
const dateText = (value:unknown, language:'en'|'zh') => value ? formatBusinessDate(String(value).slice(0,10), language) : '';
const instantText = (value:unknown, language:'en'|'zh') => value ? formatBusinessDateTime(String(value), language) : '';
const DELIVERY_STATUS:Record<string,string> = {planned:'statusPlanned',dispatched:'statusDispatched',delivered:'statusDelivered',failed:'statusFailed'};

function Letterhead({company}:{company:Row}) {
 const {t} = usePreferences();
 const address = [company.address_line1, company.address_line2].filter(Boolean);
 const city = [company.city, company.country].filter(Boolean).join(', ');
 const contacts = [company.phone, company.email, company.website].filter(Boolean);
 return <header className="doc-letterhead">
  <div className="doc-brand"><img src={LOGO} alt="Charm Kenya"/><div><strong>{company.legal_name||'CHARM KENYA'}</strong>{company.trading_name&&<span>{company.trading_name}</span>}</div></div>
  <address className="doc-company-address">
   {address.map(line=><p key={line}>{line}</p>)}
   {!!city&&<p>{city}</p>}
   {!!contacts.length&&<p className="doc-contacts">{contacts.join(' · ')}</p>}
   {!!company.tax_id&&<p className="doc-tax-id">{t('documentTaxId')} · {company.tax_id}</p>}
   {!address.length&&!city&&!contacts.length&&!company.tax_id&&<p className="doc-incomplete">{t('documentCompanyIncomplete')}</p>}
  </address>
 </header>;
}

function Parties({payload,kind}:{payload:Row;kind:Kind}) {
 const {t,language} = usePreferences();
 const client = payload.client ?? {};
 const delivery = payload.delivery ?? {};
 const salesperson = payload.salesperson ?? {};
 const balance = Number(payload.invoice?.total ?? 0) - Number(payload.payments?.verified ?? 0);
 return <section className="doc-parties">
  <div className="doc-party">
   <span className="doc-party-label">{kind==='invoice'?t('documentBillTo'):t('documentClientCopy')}</span>
   <strong>{client.name}</strong>
   {!!client.contact&&<p>{t('documentContactPerson')} · {client.contact}</p>}
   {!!client.phone&&<p>{client.phone}</p>}
   {!!client.location&&<p>{client.location}</p>}
   {kind==='invoice'&&!!payload.invoice&&balance>0&&<p className="doc-party-note">{t('balanceDue')} {money(balance,language)}</p>}
  </div>
  <div className="doc-party">
   <span className="doc-party-label">{kind==='invoice'?t('documentOrderPlacedBy'):t('documentDeliverTo')}</span>
   {!!delivery.scheduled_on&&<p><strong>{t('scheduledFor')}</strong> {dateText(delivery.scheduled_on,language)}</p>}
   {!!delivery.driver_name&&<p>{delivery.driver_name}{delivery.driver_phone?` · ${delivery.driver_phone}`:''}</p>}
   {!!delivery.vehicle&&<p>{t('vehicle')} · {delivery.vehicle}</p>}
   {!!salesperson.name&&<p>{t('documentAccountManager')} · {salesperson.name}{salesperson.staff_code?` · ${salesperson.staff_code}`:''}</p>}
   {!!salesperson.phone&&<p>{salesperson.phone}</p>}
   {!delivery.scheduled_on&&!salesperson.name&&<p>{t('documentCollectionHint')}</p>}
  </div>
 </section>;
}

function Lines({rows,kind}:{rows:Row[];kind:Kind}) {
 const {t,language} = usePreferences();
 const unit = (row:Row) => t(row.unit==='carton'?'cartonUnit':'bottle');
 return <div className="doc-lines table-wrap"><table>
  <thead><tr><th className="doc-num">#</th><th>{t('product_description')}</th><th className="doc-num">{t('quantity')}</th><th>{t('unit')}</th>{kind==='invoice'?<><th className="doc-money">{t('unit_price')}</th><th className="doc-money">{t('amountLabel')}</th></>:<th className="doc-num">{t('documentBottles')}</th>}</tr></thead>
  <tbody>{rows.map((row,index)=><tr key={row.id??index}>
   <td className="doc-num">{index+1}</td>
   <td className="doc-item"><strong>{row.description}</strong>{(row.sku||row.barcode)&&<small>{[row.sku,row.barcode].filter(Boolean).join(' · ')}</small>}</td>
   <td className="doc-num">{row.quantity}</td>
   <td>{unit(row)}</td>
   {kind==='invoice'&&<td className="doc-money">{money(row.unit_price,language)}</td>}
   {kind==='invoice'&&<td className="doc-money">{money(row.line_total,language)}</td>}
   {kind==='delivery'&&<td className="doc-num">{row.bottles??row.quantity}</td>}
  </tr>)}</tbody>
 </table></div>;
}

function Amounts({payload}:{payload:Row}) {
 const {t,language} = usePreferences();
 const invoice = payload.invoice;
 if (!invoice) return <div className="doc-amounts"><p className="doc-incomplete">{t('invoiceNotIssued')}</p></div>;
 const verified = Number(payload.payments?.verified ?? 0);
 const total = Number(invoice.total);
 const rate = Number(invoice.tax_rate ?? 0);
 const rows:[string,string,boolean][] = [
  [t('subtotalLabel'), money(invoice.subtotal,language), false],
  [`${t('vatLabel')}${rate?` · ${(rate*100).toFixed(2).replace(/\.?0+$/,'')}%`:''}`, money(invoice.tax_amount,language), false],
  [t('documentInvoiceTotal'), money(total,language), true],
  [t('paymentsReceived'), money(verified,language), false],
  [t('balanceDue'), money(total-verified,language), true],
 ];
 return <div className="doc-amounts"><table><tbody>{rows.map(([label,value,strong])=><tr key={label} className={strong?'doc-total-row':''}><th>{label}</th><td>{value}</td></tr>)}</tbody></table>
  {!!Number(payload.payments?.pending??0)&&<p className="doc-note-line">{t('documentPendingPayments')} {money(payload.payments.pending,language)}</p>}
  {(payload.credit_notes??[]).length>0&&<ul className="doc-credits">{payload.credit_notes.map((credit:Row)=><li key={credit.id}><strong>{credit.credit_note||`${t('creditNotes')} #${credit.id}`}</strong><span>{money(credit.amount,language)}</span><small>{[credit.reason,credit.lot].filter(Boolean).join(' · ')}{credit.created_at?` · ${dateText(credit.created_at,language)}`:''}</small></li>)}</ul>}
 </div>;
}

function PaymentInstructions({company}:{company:Row}) {
 const {t} = usePreferences();
 const bank = [company.bank_name, company.bank_branch].filter(Boolean).join(' · ');
 const bankAccount = [company.bank_account_name, company.bank_account_number].filter(Boolean).join(' — ');
 const mobile = [company.mobile_money_name, company.mobile_paybill].filter(Boolean).join(' · ');
 if (!bank && !mobile) return <aside className="doc-payment"><h4>{t('paymentInstructions')}</h4><p className="doc-incomplete">{t('documentPaymentMissing')}</p></aside>;
 return <aside className="doc-payment">
  <h4>{t('paymentInstructions')}</h4>
  {bank&&<div><span>{t('documentBank')}</span><p>{bank}</p>{bankAccount&&<p>{t('documentAccount')} {bankAccount}</p>}</div>}
  {mobile&&<div><span>{t('documentMobileMoney')}</span><p>{mobile}</p>{company.mobile_account&&<p>{t('documentAccount')} {company.mobile_account}</p>}</div>}
 </aside>;
}

function Signatures({payload,kind}:{payload:Row;kind:Kind}) {
 const {t} = usePreferences();
 const blocks:[string,string][] = kind==='invoice'
  ? [[t('documentPreparedBy'), String(payload.salesperson?.name??'')], [t('documentAuthorisedSignatory'), ''], [t('documentReceivedBy'), '']]
  : [[t('documentDeliveredBy'), String(payload.delivery?.driver_name??'')], [t('documentReceivedBy'), ''], [t('date'), '']];
 return <footer className="doc-sign">{blocks.map(([label,value])=><div key={label}><i>{value}</i><span>{label}</span></div>)}</footer>;
}

export function DocumentSheet({kind,payload}:{kind:Kind;payload:Row}) {
 const {t,language} = usePreferences();
 const company = payload.company ?? {};
 const order = payload.order ?? {};
 const invoice = payload.invoice;
 const delivery = payload.delivery;
 const rows:Row[] = kind==='invoice' ? (payload.items??[]) : (delivery?.items?.length ? delivery.items : payload.items??[]);
 const number = kind==='invoice' ? invoice?.invoice_number : delivery?.delivery_number;
 const facts:[string,string][] = ((kind==='invoice'
  ? [[t('documentNumber'),String(number??`#${order.id}`)],[t('documentIssueDate'),instantText(invoice?.issued_at,language)],[t('due_date'),dateText(invoice?.due_date,language)],[t('order'),`#${order.id}`],[t('documentContractReference'),String(order.contract_reference??'')],[t('documentLot'),String(invoice?.batch_lot??'')],[t('documentCustomerType'),order.customer_type?t(order.customer_type==='wholesaler'?'orderTypeWholesaler':'orderTypeRetailer'):''],[t('documentTaxStatus'),invoice?.etims_control?`${t('documentTaxSubmitted')} · ${invoice.etims_control}`:t('documentTaxPending')]]
  : [[t('documentNumber'),String(number??'')],[t('scheduledFor'),dateText(delivery?.scheduled_on,language)],[t('order'),`#${order.id}`],[t('documentContractReference'),String(order.contract_reference??'')],[t('status'),delivery?.status?t(DELIVERY_STATUS[delivery.status]??delivery.status):''],[t('documentOrderDate'),instantText(order.confirmed_at,language)],[t('documentClientSignatureBy'),String(order.contract_signed_by??'')]]
 ) as [string,string][]).filter(([,value])=>!!value);
 const bottles = rows.reduce((sum,row)=>sum+Number(row.bottles??(row.unit==='carton'?0:row.quantity??0)),0);
 const terms = kind==='invoice'
  ? String(company.invoice_terms||'') || (invoice?.due_date ? `${t('documentInvoiceTermsFallback')} ${dateText(invoice.due_date,language)}.` : '')
  : String(company.delivery_terms||'') || t('deliveryNoteFooter');
 return <article className={`commercial-doc commercial-${kind}`}>
  <Letterhead company={company}/>
  <section className="doc-headline">
   <div className="doc-headline-title"><span className="doc-kicker">CHARM KENYA</span><h3>{kind==='invoice'?t('documentInvoiceTitle'):t('documentDeliveryTitle')}</h3><strong className="doc-number">{number||`#${order.id}`}</strong></div>
   <dl className="doc-facts">{facts.map(([label,value])=><div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>
  </section>
  <Parties payload={payload} kind={kind}/>
  <Lines rows={rows} kind={kind}/>
  {kind==='invoice'
   ? <section className="doc-summary"><Amounts payload={payload}/><PaymentInstructions company={company}/></section>
   : <section className="doc-summary doc-summary-delivery">
    <div className="doc-amounts"><table><tbody>
     <tr className="doc-total-row"><th>{t('documentTotalLines')}</th><td>{rows.length}</td></tr>
     <tr><th>{t('documentTotalBottles')}</th><td>{bottles.toLocaleString(language==='zh'?'zh-CN':'en-KE')}</td></tr>
     {!!invoice&&<tr><th>{t('invoice')}</th><td>{invoice.invoice_number} · {money(invoice.total,language)}</td></tr>}
     {!!invoice&&<tr className="doc-total-row"><th>{t('balanceDue')}</th><td>{money(Number(invoice.total)-Number(payload.payments?.verified??0),language)}</td></tr>}
    </tbody></table></div>
    {!!delivery?.notes&&<aside className="doc-payment"><h4>{t('deliveryNotes')}</h4><p>{delivery.notes}</p></aside>}
   </section>}
  {!!delivery?.failure_reason&&<p className="doc-reason">{delivery.failure_reason}</p>}
  <Signatures payload={payload} kind={kind}/>
  {!!terms&&<p className="doc-terms">{terms}</p>}
  {!!company.footer_note&&<p className="doc-footer-note">{company.footer_note}</p>}
  <p className="doc-generated">{t('documentGenerated')} {instantText(new Date(),language)} · Africa/Nairobi (EAT)</p>
 </article>;
}

export function OrderDocumentViewer({scope,orderId,initial='invoice',onClose}:{scope:string;orderId:number;initial?:Kind;onClose:()=>void}) {
 const {t}=usePreferences();
 const [kind,setKind]=useState<Kind>(initial);
 const q=useQuery({queryKey:[scope,'order-document-payload',orderId],retry:false,queryFn:()=>rpc<Row>('sales_document_payload',{p_order:orderId})});
 const hasDelivery=!!q.data?.delivery;
 return <Dialog className="doc-dialog" title={t(kind==='invoice'?'documentInvoiceTitle':'documentDeliveryTitle')} onClose={onClose}>
  <div className="doc-toolbar">
   <div className="field-tabs doc-tabs" role="tablist" aria-label={t('documentTabs')}>
    <button type="button" role="tab" aria-selected={kind==='invoice'} className={kind==='invoice'?'active':''} onClick={()=>setKind('invoice')}>{t('documentInvoiceTitle')}</button>
    {hasDelivery&&<button type="button" role="tab" aria-selected={kind==='delivery'} className={kind==='delivery'?'active':''} onClick={()=>setKind('delivery')}>{t('documentDeliveryTitle')}</button>}
   </div>
   <button className="primary" type="button" disabled={q.isPending} onClick={()=>window.print()}><Printer size={16}/>{t('printDocument')}</button>
  </div>
  {q.isPending?<Loading/>:q.isError?<ErrorNotice error={q.error} retry={()=>q.refetch()}/>:q.data&&<><div className="doc-scroll"><DocumentSheet kind={kind} payload={q.data}/></div><p className="field-note doc-hint">{t(kind==='invoice'?'documentPrintHint':'deliveryDocumentHint')}</p></>}
  <div className="dialog-actions doc-actions"><button type="button" onClick={onClose}>{t('close')}</button></div>
 </Dialog>;
}

const COMPANY_FIELDS:[string,string,number][] = [
 ['legal_name','documentLegalName',120],['trading_name','documentTradingName',120],
 ['address_line1','documentAddressLine1',200],['address_line2','documentAddressLine2',200],
 ['city','documentCity',120],['country','documentCountry',120],
 ['phone','phone',40],['email','documentEmail',200],['website','documentWebsite',200],['tax_id','documentTaxId',40],
 ['bank_name','documentBank',120],['bank_account_name','documentAccountName',120],['bank_account_number','documentAccountNumber',60],['bank_branch','documentBankBranch',120],
 ['mobile_money_name','documentMobileMoney',120],['mobile_paybill','documentPaybill',40],['mobile_account','documentMobileAccount',60],
];
const COMPANY_TEXTS:[string,string][] = [['delivery_terms','documentDeliveryTerms'],['invoice_terms','documentInvoiceTerms'],['footer_note','documentFooterNote']];

export function useCompanyProfile(scope:string) {
 return useQuery({queryKey:[scope,'company-profile'],retry:false,queryFn:async()=>{const {data,error}=await supabase!.from('company_profile').select('*').limit(1);if(error)throw error;return ((data as Row[])??[])[0]??{};}});
}

export function CompanyLetterheadCard({scope,profile,onOpen}:{scope:string;profile:Row;onOpen:()=>void}) {
 const {t}=usePreferences();
 const q=useCompanyProfile(scope);
 const company=q.data??{};
 const missing=COMPANY_FIELDS.filter(([key])=>!company[key]&&['address_line1','phone','email','tax_id'].includes(key)).map(([,label])=>t(label));
 const details=[company.address_line1,company.address_line2,[company.city,company.country].filter(Boolean).join(', '),company.phone,company.email,company.website].filter(Boolean);
 return <section className="card finance-config company-card">
  <header className="company-card-head"><div><h2>{t('companyLetterhead')}</h2><p>{t('companyLetterheadHint')}</p></div><button type="button" onClick={onOpen}>{t('documentEditCompany')}</button></header>
  {q.isPending?<Loading/>:q.isError?<ErrorNotice error={q.error} retry={()=>q.refetch()}/>:<div className="company-identity">
   <img src={LOGO} alt=""/>
   <div><strong>{company.legal_name||'CHARM KENYA'}</strong>{company.trading_name&&<span>{company.trading_name}</span>}{details.map(line=><p key={line}>{line}</p>)}{company.tax_id&&<p>{t('documentTaxId')} · {company.tax_id}</p>}</div>
   <div className="company-payment">{(company.bank_name||company.mobile_paybill)&&<><p><strong>{t('paymentInstructions')}</strong></p>{[company.bank_name,company.bank_account_number,company.mobile_money_name,company.mobile_paybill,company.mobile_account].filter(Boolean).map((line:string,index:number)=><span key={`${line}-${index}`}>{line}</span>)}</>}</div>
  </div>}
  {!!missing.length&&<p className="notice">{t('documentCompanyMissingFields')}: {missing.join(', ')}</p>}
  {profile.role!=='admin'&&<p className="field-note">{t('documentAdminOnlyEdit')}</p>}
 </section>;
}

export function CompanyLetterheadDialog({scope,onClose,onSaved}:{scope:string;onClose:()=>void;onSaved:(message:string)=>void}) {
 const {t}=usePreferences();const qc=useQueryClient();
 const [error,setError]=useState<unknown>();const [busy,setBusy]=useState(false);
 const q=useCompanyProfile(scope);
 async function submit(form:HTMLFormElement){
  const data=Object.fromEntries(new FormData(form));setBusy(true);setError(undefined);
  const args:Record<string,unknown>={};
  for(const [key] of COMPANY_FIELDS) args[`p_${key}`]=String(data[key]??'');
  for(const [key] of COMPANY_TEXTS) args[`p_${key}`]=String(data[key]??'');
  try{
   await rpc('company_profile_save',args);
   await qc.invalidateQueries({queryKey:[scope,'company-profile']});await qc.invalidateQueries({queryKey:[scope,'order-document-payload']});
   onSaved('documentCompanySaved');onClose();
  }catch(e){setError(e);}finally{setBusy(false);}
 }
 return <Dialog title={t('companyLetterhead')} onClose={onClose}>
  {q.isPending?<Loading/>:q.isError?<ErrorNotice error={q.error} retry={()=>q.refetch()}/>:<form onSubmit={e=>{e.preventDefault();if(!e.currentTarget.reportValidity())return;void submit(e.currentTarget);}}>
   <p className="field-note">{t('companyLetterheadHint')}</p>
   <div className="field-form-grid">{COMPANY_FIELDS.map(([key,label,max])=><Field key={key} label={label}><input name={key} defaultValue={String(q.data?.[key]??'')} maxLength={max} required={['legal_name','city'].includes(key)}/></Field>)}</div>
   {COMPANY_TEXTS.map(([key,label])=><Field key={key} label={label}><textarea name={key} rows={2} maxLength={key==='footer_note'?300:600} defaultValue={String(q.data?.[key]??'')}/></Field>)}
   {!!error&&<ErrorNotice error={error}/>}
   <div className="dialog-actions"><button type="button" onClick={onClose}>{t('close')}</button><button className="primary" disabled={busy}>{t(busy?'saving':'documentSaveCompany')}</button></div>
  </form>}
 </Dialog>;
}

import { useQuery } from '@tanstack/react-query';
import { Check, Clock3, ShieldCheck, Wallet } from 'lucide-react';
import { usePreferences } from './i18n';
import { supabase } from './lib/supabase';
import { databaseError } from './lib/errors';
import type { Row } from './lib/data';
import { ErrorNotice } from './components';
import { formatMoney, settlement } from './lib/presentation';
export { formatMoney, settlement } from './lib/presentation';
export function RecordJourney({section,row}:{section:string;row:Row}) {
 const {t}=usePreferences();
 const completed=['confirmed','verified','approved'].includes(row.status)||section==='balances'||(section==='visits'&&!!row.check_out_at);
 const rejected=['rejected','cancelled'].includes(row.status);
 const final=['orders','balances'].includes(section)?'confirmed':section==='payments'?'verified':section==='visits'?'checkedOut':'approved';
 if(!['orders','payments','plans','expenses','reports','visits','balances'].includes(section))return null;
 return <div className={`journey ${rejected?'stopped':''}`} aria-label={t('submissionJourney')}>
  <div className="journey-step done"><span><Check size={15}/></span><strong>{t('submitted')}</strong></div>
  <div className={`journey-step ${completed||rejected?'done':'current'}`}><span><Clock3 size={15}/></span><strong>{t(section==='visits'?'checkedIn':'adminReview')}</strong></div>
  <div className={`journey-step ${completed?'done':''}`}><span><ShieldCheck size={15}/></span><strong>{t(rejected?row.status:final)}</strong></div>
 </div>;
}
export function FinancePanel({section,row,scope}:{section:string;row:Row;scope:string}) {
 const {t,language}=usePreferences();const orderId=section==='payments'?row.order_id:row.id;
 const q=useQuery({queryKey:[scope,'finance',orderId],enabled:['orders','payments','balances'].includes(section)&&section!=='balances',queryFn:async()=>{
  const {data,error}=await supabase!.from('order_balances').select('*').eq('id',orderId).limit(1);if(error)throw databaseError(error);return data?.[0] as Row|undefined;
 },refetchInterval:30000});
 if(['orders','payments','balances'].includes(section)){
  const balance=section==='balances'?row:q.data;
  const ratio=balance&&Number(balance.total)>0?Math.min(100,Number(balance.paid)/Number(balance.total)*100):0;
  return <section className="finance-panel"><div className="panel-title"><h3><Wallet size={18}/>{t('financialImpact')}</h3>{balance&&<span className={`badge ${settlement(balance)}`}>{t(settlement(balance))}</span>}</div>
   <div className="finance-facts"><div><span>{t(section==='payments'?'amount':'total')}</span><strong>{formatMoney(row.amount??row.total,language)}</strong></div><div><span>{t('salesImpact')}</span><strong>{formatMoney((section==='orders'&&row.status==='confirmed')||section==='balances'?row.total:0,language)}</strong></div></div>
   <p>{t(section==='payments'?(row.status==='verified'?'verifiedImpact':row.status==='rejected'?'rejectedPaymentImpact':'pendingPaymentImpact'):row.status==='pending'?'pendingOrderImpact':['rejected','cancelled'].includes(row.status)?'excludedOrderImpact':'confirmedOrderImpact')}</p>
   {q.isError&&<ErrorNotice error={q.error}/>} {q.isFetching&&!balance&&<p role="status">{t('loading')}</p>}
   {balance&&<><div className="collection-track" role="progressbar" aria-label={t('collectionProgress')} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(ratio)}><div style={{width:`${ratio}%`}}/></div><div className="finance-facts compact"><div><span>{t('paid')}</span><strong>{formatMoney(balance.paid,language)}</strong></div><div><span>{t('balance')}</span><strong>{formatMoney(balance.balance,language)}</strong></div></div></>}
  </section>;
 }
 if(['plans','expenses'].includes(section))return <section className="finance-panel"><h3>{t('travelCommitment')}</h3><div className="finance-facts"><div><span>{t('budget')}</span><strong>{formatMoney(row.budget,language)}</strong></div><div><span>{t('approvedBudget')}</span><strong>{formatMoney(row.status==='approved'?row.budget:0,language)}</strong></div></div><p>{t('expenseImpact')}</p></section>;
 return null;
}
export function SubmissionPreview({kind,value}:{kind:string;value:string}) {
 const {t,language}=usePreferences();
 if(!['orders','payments','plans','expenses','reports','visits'].includes(kind))return null;
 const financial=['orders','payments','plans','expenses'].includes(kind);
 return <aside className="submission-preview"><div><ShieldCheck size={18}/><strong>{t('submissionPreview')}</strong><span>{t('reviewRequired')}</span></div>{financial&&<strong className="preview-value">{formatMoney(value,language)}</strong>}<p>{t(kind==='orders'?'orderPreview':kind==='payments'?'paymentPreview':['plans','expenses'].includes(kind)?'travelPreview':'recordPreview')}</p></aside>;
}

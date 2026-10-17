import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { ArrowUpRight, CreditCard, Clock, ShieldCheck, Wallet } from 'lucide-react';
import { usePreferences } from './i18n';
import { formatMoney } from './finance';
import { register, type FinanceFilters } from './lib/financePortal';
import type { Row } from './lib/data';

export default function FinanceWorkQueues({scope,filters,summary,rows,accounts}:{scope:string;filters:FinanceFilters;summary?:Row;rows:Row[];accounts:Row[]}){
 const {t,language}=usePreferences();
 const approved=useQuery({queryKey:[scope,'finance-ready',filters],queryFn:()=>register('requests',{...filters,status:'awaiting_payment'},1),refetchInterval:15000,refetchIntervalInBackground:false,refetchOnWindowFocus:true});
 const partial=useQuery({queryKey:[scope,'finance-partial',filters],queryFn:()=>register('requests',{...filters,status:'partial_payments'},1),refetchInterval:15000,refetchIntervalInBackground:false,refetchOnWindowFocus:true});
 const path=(page:string,status='')=>`/finance/${page}?${new URLSearchParams({status,from:filters.from,to:filters.to,...(filters.owner?{staff:filters.owner}:{})})}`;
 const queues=[{label:'readyToDisburse',value:approved.data?.total??'—',page:'disbursements',status:'awaiting_payment',Icon:CreditCard},
 {label:'continuePartialPayments',value:partial.data?.total??'—',page:'disbursements',status:'partial_payments',Icon:Clock},
 {label:'outstandingAdvances',value:summary?formatMoney(summary.outstanding,language):'—',page:'accountability',status:'outstanding',Icon:ShieldCheck},
 {label:'financeAccounts',value:accounts.length,page:'accounts',status:'',Icon:Wallet}];
 return <><section className="finance-work-queues"><div className="finance-section-heading"><h2>{t('financeWorkQueues')}</h2><span>{t('financeNextStep')}</span></div><div className="finance-queue-grid">{queues.map(({label,value,page,status,Icon})=><Link className="card finance-queue" key={label} to={path(page,status)}><Icon size={23}/><span>{t(label)}</span><strong>{value}</strong><small>{t('openWorkQueue')} <ArrowUpRight size={15}/></small></Link>)}</div>{(approved.isError||partial.isError)&&<p role="alert">{t('genericError')}</p>}</section><section className="card finance-recent"><div className="finance-section-heading"><h2>{t('financeRecentRequests')}</h2><Link to={path('requests')}>{t('viewAll')} <ArrowUpRight size={16}/></Link></div>{rows.length===0?<p>{t('financeEmptyHint')}</p>:rows.slice(0,6).map(row=><Link className="finance-recent-row" key={row.id} to={`${path(['approved','part_paid'].includes(row.status)?'disbursements':'requests',row.status)}&request=${row.id}`}><div><strong>#{row.id} · {row.owner_name}</strong><span>{row.purpose}</span></div><div><strong>{formatMoney(row.amount,language)}</strong><span>{t(row.status==='paid'?'fullyDisbursed':row.status)}</span></div><ArrowUpRight size={18}/></Link>)}</section></>;
}

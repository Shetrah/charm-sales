import { useEffect, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { ArrowUpRight, Package, Search, ShoppingBag, Truck, Users } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import type { Row } from './lib/data';
import { formatBusinessDate } from './lib/dates';
import { rpc } from './lib/supabase';
import { usePreferences } from './i18n';
import { Dialog, ErrorNotice, Loading, useDebounce } from './components';

type SearchResults = {clients:Row[];orders:Row[];deliveries:Row[];products:Row[]};

export default function SearchCentre({scope}:{scope:string}){
 const {t,language}=usePreferences();const navigate=useNavigate();const [open,setOpen]=useState(false);const [term,setTerm]=useState('');const debounced=useDebounce(term.trim());const input=useRef<HTMLInputElement>(null);
 const money=(value:unknown)=>Number(value??0).toLocaleString(language==='zh'?'zh-CN':'en-KE');
 const q=useQuery({queryKey:[scope,'search',debounced],enabled:open&&debounced.length>=2,queryFn:()=>rpc<SearchResults>('search_centre',{p_query:debounced})});
 useEffect(()=>{if(!open)return;const timer=setTimeout(()=>input.current?.focus(),40);return()=>clearTimeout(timer);},[open]);
 const close=()=>{setOpen(false);setTerm('');};
 const go=(path:string)=>{close();navigate(path);};
 const results=q.data??{clients:[],orders:[],deliveries:[],products:[]};
 const groups=[
  {key:'clients',label:t('searchClients'),icon:<Users size={15}/>,rows:results.clients},
  {key:'orders',label:t('searchOrders'),icon:<ShoppingBag size={15}/>,rows:results.orders},
  {key:'deliveries',label:t('searchDeliveries'),icon:<Truck size={15}/>,rows:results.deliveries},
  {key:'products',label:t('searchProducts'),icon:<Package size={15}/>,rows:results.products}
 ].filter(group=>group.rows.length>0);
 const total=groups.reduce((sum,group)=>sum+group.rows.length,0);
 const describe=(key:string,row:Row)=>key==='clients'?[row.contact,row.phone,row.location].filter(Boolean).join(' · ')
  :key==='orders'?`${row.client} · ${t('total')} ${money(row.total)}${row.due_date?` · ${t('due_date')} ${formatBusinessDate(row.due_date,language)}`:''}`
  :key==='deliveries'?`${row.client} · ${formatBusinessDate(row.scheduled_on,language)}`
  :`${row.category} · ${row.capacity} · ${row.fragrance??''} · ${row.barcode??''}`;
 const path=(key:string,row:Row)=>key==='clients'?`/clients?record=${row.id}`:key==='orders'?`/orders?record=${row.id}`:key==='deliveries'?`/logistics?record=${row.id}`:`/products?record=${row.id}`;
 return <><button type="button" className="icon-button search-trigger" aria-label={t('searchOpen')} onClick={()=>setOpen(true)}><Search size={20}/></button>{open&&<Dialog title={t('searchCentre')} onClose={close}>
  <div className="search-centre">
   <input ref={input} type="search" value={term} onChange={e=>setTerm(e.target.value)} placeholder={t('searchPlaceholder')} aria-label={t('searchPlaceholder')} autoComplete="off"/>
   {debounced.length<2?<p className="field-note">{t('searchHint')}</p>:q.isPending?<Loading/>:q.isError?<ErrorNotice error={q.error} retry={()=>q.refetch()}/>:total===0?<div className="state"><Search size={30}/><h3>{t('searchNoResults')}</h3><p>{t('searchNoResultsHint')}</p></div>:<div className="search-groups">{groups.map(group=><section className="search-group" key={group.key}><h3>{group.icon}{group.label}<span>{group.rows.length}</span></h3><div>{group.rows.map(row=><button type="button" className="search-hit" key={row.id} onClick={()=>go(path(group.key,row))}><div><strong>{group.key==='clients'?row.name:group.key==='orders'?`#${row.id} · ${row.client}`:group.key==='deliveries'?`${row.delivery_number} · ${row.client}`:`${row.sku} · ${row.category} ${row.capacity}`}</strong><small>{describe(group.key,row)}</small></div><ArrowUpRight size={15}/></button>)}</div></section>)}</div>}
  </div>
 </Dialog>}</>;
}

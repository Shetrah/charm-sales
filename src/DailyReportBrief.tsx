import { useEffect, useState } from 'react';
import { CalendarDays, CheckCheck, ClipboardList, RefreshCw, Sparkles, Target } from 'lucide-react';
import { ErrorNotice, Loading } from './components';
import { usePreferences } from './i18n';
import { supabase } from './lib/supabase';
import type { Row } from './lib/data';

export default function DailyReportBrief({scope,date,visits}:{scope:string;date:string;visits:Row[]}){
 const {t,language}=usePreferences();const [summary,setSummary]=useState('');const [source,setSource]=useState('ai');const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();
 const generate=async(force=false)=>{const key=`charm-daily-report:${scope}:${date}:${language}`;if(!force){const cached=localStorage.getItem(key);if(cached){setSummary(cached);setSource(localStorage.getItem(`${key}:source`)??'ai');return;}}if(!visits.length){setSummary('');return;}setBusy(true);setError(undefined);try{const {data,error}=await supabase!.functions.invoke('daily-report-ai',{body:{date,language}});if(error){let code='dailyReportUnavailable';const context='context'in error?error.context:undefined;if(context instanceof Response){try{const body=await context.clone().json();if(typeof body?.error==='string')code=body.error;}catch{}}throw new Error(code);}if(!data?.summary)throw new Error('dailyReportUnavailable');setSummary(data.summary);setSource(data.source==='deterministic'?'deterministic':'ai');localStorage.setItem(key,data.summary);localStorage.setItem(`${key}:source`,data.source==='deterministic'?'deterministic':'ai');}catch(next){setError(next instanceof Error?next:new Error('dailyReportUnavailable'));}finally{setBusy(false);}};
 useEffect(()=>{let live=true;const load=async()=>{if(!visits.length){setSummary('');return;}const key=`charm-daily-report:${scope}:${date}:${language}`;const cached=localStorage.getItem(key);if(cached){setSummary(cached);setSource(localStorage.getItem(`${key}:source`)??'ai');return;}if(live)await generate();};void load();return()=>{live=false;};},[scope,date,language,visits.length]);
 if(!visits.length)return null;
 const outcomeCounts=visits.reduce<Record<string,number>>((counts,visit)=>{const outcome=String(visit.outcome??'otherOutcome');counts[outcome]=(counts[outcome]??0)+1;return counts;},{});
 const followUps=visits.filter(visit=>String(visit.next_action??'').trim());
 const opportunities=[...new Set(visits.map(visit=>String(visit.sales_opportunities??'').trim()).filter(Boolean))];
 return <section className="card ai-daily-report">
  <header className="daily-report-header"><div className="daily-report-heading"><span className="daily-report-kicker"><Sparkles size={14}/>{source==='deterministic'?t('deterministicNarrative'):t('aiDailyReport')}</span><h2>{t('dailyFieldReport')}</h2><p>{t('preparedFromVisitReports')}</p></div><div className="daily-report-controls"><span className="daily-report-date"><CalendarDays size={15}/>{date}</span><button type="button" className="daily-report-refresh" disabled={busy} onClick={()=>void generate(true)}><RefreshCw size={15} className={busy?'is-spinning':''}/>{busy?t('preparingSummary'):t('regenerate')}</button></div></header>
  <div className="daily-report-metrics">
   <article className="daily-report-metric metric-visits"><span className="daily-report-metric-icon"><ClipboardList size={17}/></span><span className="daily-report-metric-label">{t('submittedVisits')}</span><strong>{visits.length}</strong><small>{t('completedReports')}</small></article>
   <article className="daily-report-metric"><span className="daily-report-metric-icon"><CheckCheck size={17}/></span><span className="daily-report-metric-label">{t('visitOutcomesLabel')}</span><strong>{Object.keys(outcomeCounts).length}</strong><small>{Object.entries(outcomeCounts).map(([name,count])=>`${count} ${t(name)}`).join(' · ')}</small></article>
   <article className="daily-report-metric"><span className="daily-report-metric-icon"><CalendarDays size={17}/></span><span className="daily-report-metric-label">{t('followUpActionsLabel')}</span><strong>{followUps.length}</strong><small>{followUps.filter(visit=>visit.follow_up_date).length} {t('dueDateRecorded')}</small></article>
   <article className="daily-report-metric"><span className="daily-report-metric-icon"><Target size={17}/></span><span className="daily-report-metric-label">{t('opportunitiesLabel')}</span><strong>{opportunities.length}</strong><small>{t('recordedDuringVisits')}</small></article>
  </div>
  {busy?<div className="daily-report-summary-loading"><Loading/></div>:error?<ErrorNotice error={error} retry={()=>void generate(true)}/>:<div className="daily-report-narrative"><span className="daily-report-narrative-icon"><Sparkles size={17}/></span><div><span className="daily-report-narrative-label">{t('fieldSummary')}</span><p>{summary}</p></div></div>}
 </section>;
}

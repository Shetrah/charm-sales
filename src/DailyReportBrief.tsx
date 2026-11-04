import { useEffect, useState } from 'react';
import { Sparkles, RefreshCw } from 'lucide-react';
import { ErrorNotice, Loading } from './components';
import { usePreferences } from './i18n';
import { supabase } from './lib/supabase';
import type { Row } from './lib/data';

export default function DailyReportBrief({scope,date,visits}:{scope:string;date:string;visits:Row[]}){
 const {t}=usePreferences();const [summary,setSummary]=useState('');const [busy,setBusy]=useState(false);const [error,setError]=useState<unknown>();
 const generate=async(force=false)=>{const key=`charm-daily-report:${scope}:${date}`;if(!force){const cached=localStorage.getItem(key);if(cached){setSummary(cached);return;}}if(!visits.length){setSummary('');return;}setBusy(true);setError(undefined);try{const {data,error}=await supabase!.functions.invoke('daily-report-ai',{body:{date}});if(error){let code='dailyReportUnavailable';const context='context'in error?error.context:undefined;if(context instanceof Response){try{const body=await context.clone().json();if(typeof body?.error==='string')code=body.error;}catch{}}throw new Error(code);}if(!data?.summary)throw new Error('dailyReportUnavailable');setSummary(data.summary);localStorage.setItem(key,data.summary);}catch(next){setError(next instanceof Error?next:new Error('dailyReportUnavailable'));}finally{setBusy(false);}};
 useEffect(()=>{let live=true;const load=async()=>{if(!visits.length){setSummary('');return;}const cached=localStorage.getItem(`charm-daily-report:${scope}:${date}`);if(cached){setSummary(cached);return;}if(live)await generate();};void load();return()=>{live=false;};},[scope,date,visits.length]);
 if(!visits.length)return null;
 return <section className="card ai-daily-report"><header><div><span className="eyebrow"><Sparkles size={13}/> {t('aiDailyReport')}</span><h2>{t('autoPreparedFromVisits')} · {date}</h2></div><button type="button" disabled={busy} onClick={()=>void generate(true)} aria-label={t('refreshData')}><RefreshCw size={15}/>{t('regenerate')}</button></header>{busy?<Loading/>:error?<ErrorNotice error={error} retry={()=>void generate(true)}/>:<p>{summary}</p>}</section>;
}

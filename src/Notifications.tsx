import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Bell, Volume2, VolumeX } from 'lucide-react';
import { Link } from 'react-router-dom';
import { rpc, supabase } from './lib/supabase';
import type { Row } from './lib/data';
import { Dialog, ErrorNotice, Loading } from './components';
import { usePreferences } from './i18n';
export default function Notifications({scope}:{scope:string}){
 const {t,language}=usePreferences();const qc=useQueryClient();const [open,setOpen]=useState(false);const [page,setPage]=useState(1);const [sound,setSound]=useState(false);const [error,setError]=useState<unknown>();const audio=useRef<AudioContext|null>(null);const latest=useRef<number|null>(null);
 const feed=useQuery({queryKey:[scope,'notifications'],retry:false,refetchInterval:10000,queryFn:async()=>{
  const {data,error}=await supabase!.from('finance_notifications').select('*').order('id',{ascending:false}).limit(25);if(error)throw new Error('migrationMissing');
  const count=await supabase!.from('finance_notifications').select('id',{count:'exact',head:true}).is('read_at',null);if(count.error)throw new Error('genericError');return {rows:data as Row[],unread:count.count??0};
 }});
 const history=useQuery({queryKey:[scope,'notification-history',page],enabled:open,queryFn:async()=>{const {data,error}=await supabase!.from('finance_notifications').select('*',{count:'exact'}).order('id',{ascending:false}).range((page-1)*25,page*25-1);if(error)throw new Error('migrationMissing');return data as Row[];}});
 useEffect(()=>{const newest=Number(feed.data?.rows[0]?.id??0);if(!feed.data)return;if(latest.current===null){latest.current=newest;return;}const fresh=feed.data.rows.filter(row=>row.id>latest.current!&&!row.read_at);latest.current=Math.max(latest.current,newest);if(!fresh.length||!sound)return;
  const claim=async()=>{const key=`charm-notification-sound:${scope}`;const handled=Number(localStorage.getItem(key)??0);if(newest<=handled)return;localStorage.setItem(key,String(newest));if(audio.current?.state!=='running')return;const oscillator=audio.current.createOscillator(),gain=audio.current.createGain();oscillator.connect(gain);gain.connect(audio.current.destination);oscillator.frequency.value=740;gain.gain.setValueAtTime(.06,audio.current.currentTime);gain.gain.exponentialRampToValueAtTime(.001,audio.current.currentTime+.2);oscillator.start();oscillator.stop(audio.current.currentTime+.2);};
  if(navigator.locks)void navigator.locks.request(`charm-alert:${scope}`,claim);else void claim();
 },[feed.data,sound,scope]);
 useEffect(()=>()=>{void audio.current?.close();},[]);
 const read=async(id?:number)=>{try{await rpc('finance_mark_read',{p_id:id??null});await qc.invalidateQueries({queryKey:[scope]});}catch(e){setError(e);}};
 return <><button className="icon-button notification-button" aria-label={`${t('notifications')} (${feed.data?.unread??0})`} onClick={()=>setOpen(true)}><Bell size={20}/>{!!feed.data?.unread&&<span>{feed.data.unread>99?'99+':feed.data.unread}</span>}</button>{open&&<Dialog title={t('notifications')} onClose={()=>setOpen(false)}><div className="notification-controls"><button onClick={async()=>{if(sound){setSound(false);return;}try{audio.current??=new AudioContext();await audio.current.resume();if(audio.current.state!=='running')throw new Error('soundUnavailable');setSound(true);}catch{setError(new Error('soundUnavailable'));}}}>{sound?<Volume2 size={16}/>:<VolumeX size={16}/>} {t(sound?'muteAlerts':'enableSound')}</button><button onClick={()=>void read()}>{t('markAllRead')}</button></div><p className="chart-note">{t('soundHint')}</p>{!!error&&<ErrorNotice error={error}/ >}{history.isPending?<Loading/>:history.isError?<ErrorNotice error={history.error}/>:<div className="notification-history">{history.data?.length===0&&<p>{t('empty')}</p>}{history.data?.map(row=><Link className={row.read_at?'read':'unread'} key={row.id} to={`/finance?request=${row.request_id}`} onClick={()=>{void read(row.id);setOpen(false);}}><strong>{t(row.event)} · #{row.request_id}</strong><small>{new Date(row.created_at).toLocaleString(language==='zh'?'zh-CN':'en-KE',{timeZone:'Africa/Nairobi'})}</small></Link>)}</div>}<div className="pagination"><button disabled={page===1} onClick={()=>setPage(page-1)}>{t('previous')}</button><span>{page}</span><button disabled={(history.data?.length??0)<25} onClick={()=>setPage(page+1)}>{t('next')}</button></div></Dialog>}</>;
}

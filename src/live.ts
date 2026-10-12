import { useEffect, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { supabase } from './lib/supabase';
export function useLiveUpdates(scope:string) {
 const qc=useQueryClient();const [connected,setConnected]=useState(false);
 useEffect(()=>{
  if(!supabase)return;let timer:ReturnType<typeof setTimeout>|undefined;let refreshTrend=false;
  const refresh=(withTrend=false)=>{if(document.visibilityState!=='visible')return;refreshTrend ||= withTrend;if(timer)return;timer=setTimeout(()=>{timer=undefined;const includeTrend=refreshTrend;refreshTrend=false;qc.invalidateQueries({predicate:q=>q.queryKey[0]===scope&&(includeTrend||q.queryKey[1]!=='trend')});},350);};
  // The isolated browser-test transport has REST but no hosted Realtime service.
  const channel=import.meta.env.VITE_REALTIME_ENABLED==='false'?null:supabase.channel(`workspace-${scope}`).on('postgres_changes',{event:'*',schema:'charm'},payload=>refresh(payload.table==='orders')).subscribe(status=>setConnected(status==='SUBSCRIBED'));
  const interval=setInterval(()=>refresh(),10000);
  const visible=()=>{if(document.visibilityState==='visible')refresh();};document.addEventListener('visibilitychange',visible);
  return()=>{clearInterval(interval);if(timer)clearTimeout(timer);document.removeEventListener('visibilitychange',visible);if(channel)supabase?.removeChannel(channel);};
 },[scope,qc]);
 return connected;
}

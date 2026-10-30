import { useState, type ReactNode } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { Camera, ImageOff, Trash2 } from 'lucide-react';
import { usePreferences } from './i18n';
import { ErrorNotice } from './components';
import { attachMedia, clearMedia, useMediaUrl, type MediaKind } from './lib/media';

const IMAGE_ACCEPT = 'image/jpeg,image/png,image/webp';

export function MediaImage({path, alt, className, fallback}:{path?:string|null; alt:string; className:string; fallback:ReactNode}) {
 const url = useMediaUrl(path);
 if (!path || !url) return <>{fallback}</>;
 return <img className={`${className} photographed`} src={url} alt={alt} loading="lazy" decoding="async" />;
}

export function MediaPlaceholder({label}:{label:string}) {
 return <span className="media-placeholder" aria-hidden="true"><ImageOff size={18}/><small>{label}</small></span>;
}

export function MediaUpload({kind, id, path, label, removeLabel, onSaved}:{kind:MediaKind; id:number; path?:string|null; label:string; removeLabel:string; onSaved:()=>void}) {
 const {t}=usePreferences();const qc=useQueryClient();
 const [busy,setBusy]=useState(false);const [progress,setProgress]=useState(0);const [error,setError]=useState<unknown>();
 async function pick(file?:File|null){
  if(!file||busy)return;
  setBusy(true);setProgress(0);setError(undefined);
  try{
   await attachMedia(kind,id,file,setProgress);
   await qc.invalidateQueries({queryKey:['media']});
   onSaved();
  }catch(next){setError(next);}finally{setBusy(false);setProgress(0);}
 }
 async function remove(){
  if(busy)return;
  setBusy(true);setError(undefined);
  try{
   await clearMedia(kind,id);
   await qc.invalidateQueries({queryKey:['media']});
   onSaved();
  }catch(next){setError(next);}finally{setBusy(false);}
 }
 return <div className="media-upload">
  <label className={`media-button${busy?' busy':''}`}>
   <Camera size={15}/><span>{busy&&progress?`${t('uploading')} ${progress}%`:t(busy?'saving':label)}</span>
   <input type="file" accept={IMAGE_ACCEPT} aria-label={t(label)} hidden disabled={busy} onChange={event=>{void pick(event.target.files?.[0]);event.target.value='';}}/>
  </label>
  {!!path&&<button type="button" className="text-button" disabled={busy} onClick={()=>void remove()}><Trash2 size={15}/>{t(removeLabel)}</button>}
  {!!error&&<ErrorNotice error={error}/>}
 </div>;
}

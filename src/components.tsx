import { useEffect, useState, useId, Children, cloneElement, isValidElement, type ReactElement, type ReactNode } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Moon, Sun, Languages, X, LoaderCircle } from 'lucide-react';
import { usePreferences, translatedError } from './i18n';
import { lookup, type Row } from './lib/data';
export function useDebounce(value:string){const [debounced,set]=useState(value);useEffect(()=>{const timer=setTimeout(()=>set(value),300);return ()=>clearTimeout(timer);},[value]);return debounced;}
export function Preferences(){const {t,language,theme,toggleTheme,toggleLanguage}=usePreferences();return <div className="preferences"><button type="button" className="icon-button" aria-label={t(theme==='dark'?'light':'dark')} onClick={toggleTheme}>{theme==='dark'?<Sun size={18}/>:<Moon size={18}/>}</button><button type="button" className="language" aria-label="Change language" onClick={toggleLanguage}><Languages size={17}/> {language==='en'?'English · 简体中文':'简体中文 · English'}</button></div>;}
export function Loading(){const {t}=usePreferences();return <div className="state" role="status"><LoaderCircle className="spin"/>{t('loading')}</div>;}
export function ErrorNotice({error,retry}:{error:unknown;retry?:()=>void}){const {t}=usePreferences();return <div className="notice error" role="alert">{translatedError(error,t)}{retry&&<button onClick={retry}>{t('retry')}</button>}</div>;}
export function Dialog({title,children,onClose}:{title:string;children:ReactNode;onClose:()=>void}){
 const {t}=usePreferences();const titleId=useId();useEffect(()=>{const old=document.activeElement as HTMLElement;const overflow=document.body.style.overflow;document.body.style.overflow='hidden';const el=document.querySelector('dialog') as HTMLDialogElement;el?.showModal();return()=>{document.body.style.overflow=overflow;el?.close();old?.focus();};},[]);
 return <dialog aria-labelledby={titleId} onCancel={onClose} onKeyDown={e=>{if(e.key==='Escape')onClose();}}><div className="dialog-head"><h2 id={titleId}>{title}</h2><button type="button" className="icon-button" onClick={onClose} aria-label={t('close')}><X/></button></div><div className="dialog-body">{children}</div></dialog>;
}
export function Field({label,children}:{label:string;children:ReactNode}){
 const {t}=usePreferences();const id=useId();
 const controls=Children.toArray(children);const direct=controls.some(child=>isValidElement(child)&&typeof child.type==='string'&&['input','select','textarea'].includes(child.type));
 return <div className="field">{direct?<label htmlFor={id}>{t(label)}</label>:<span>{t(label)}</span>}{controls.map(child=>isValidElement(child)&&typeof child.type==='string'&&['input','select','textarea'].includes(child.type)?cloneElement(child as ReactElement<any>,{id}):child)}</div>;
}
export function Lookup({kind,value,onChange,scope,label,required=true}:{kind:string;value:string;onChange:(value:string)=>void;scope:string;label:string;required?:boolean}){
 const {t}=usePreferences();const inputId=useId();const [search,setSearch]=useState('');const debounced=useDebounce(search);
 const q=useQuery({queryKey:[scope,'lookup',kind,debounced],queryFn:()=>lookup(kind,debounced)});
 const [selected,setSelected]=useState<Row|null>(null);
 const rows=q.data??[];const options=selected&&!rows.some(x=>String(x.id)===value)?[selected,...rows]:rows;
 return <div className="lookup"><label className="sr-only" htmlFor={inputId}>{t(label)}</label><input id={inputId} placeholder={t(label)} value={search} onChange={e=>setSearch(e.target.value)}/><select required={required} value={value} aria-label={t(label)} onChange={e=>{setSelected(options.find(x=>String(x.id)===e.target.value)??null);onChange(e.target.value);}}><option value="">{t('choose')}</option>{options.map(row=><option key={row.id} value={row.id}>{kind==='products'?`${row.category} · ${row.capacity} · ${row.fragrance} · ${row.barcode} · ${row.carton}`:kind==='orders'?`#${row.id} · KES ${row.total}`:row.name}</option>)}</select>{q.isError&&<ErrorNotice error={q.error}/>}</div>;
}
export function Status({value}:{value:string}){const {t}=usePreferences();return <span className={`badge ${value}`}>{t(value)}</span>;}

import { rpc, supabase } from './supabase';
import type { Row } from './data';
import { csvCell } from './exportCells';
export async function financeRpc<T>(name:string,args:Record<string,unknown>={}){try{return await rpc<T>(name,args);}catch(e){if(e instanceof Error&&e.message==='migrationMissing')throw new Error('financeSetupRequired');throw e;}}
export type FinanceFilters={from:string;to:string;status:string;owner:string};
export function register(view:string,filters:FinanceFilters,page=1){return rpc<{rows:Row[];total:number}>('finance_register',{p_view:view,p_from:filters.from,p_to:filters.to,p_status:filters.status,p_owner:filters.owner?Number(filters.owner):null,p_page:page});}
export async function uploadFinance(request:number,kind:string,actor:number,file:File){
 const types:Record<string,string>={'application/pdf':'pdf','image/jpeg':'jpg','image/png':'png','image/webp':'webp'};
 if(!types[file.type]||file.size>10*1024*1024||file.size===0)throw new Error('financeFileInvalid');
 const path=`requests/${request}/${kind}/${actor}/${crypto.randomUUID()}.${types[file.type]}`;
 const {error}=await supabase!.storage.from('charm-finance').upload(path,file,{upsert:false,contentType:file.type});if(error)throw new Error('uploadFailed');
 return rpc<number>('finance_attach_document',{p_id:request,p_kind:kind,p_path:path});
}
export async function openFinanceDocument(path:string){const {data,error}=await supabase!.storage.from('charm-finance').createSignedUrl(path,60);if(error||!data)throw new Error('uploadFailed');window.open(data.signedUrl,'_blank','noopener,noreferrer');}
export function downloadCsv(rows:Row[],keys:string[],name:string){const csv='\ufeff'+[keys.map(csvCell).join(','),...rows.map(row=>keys.map(key=>csvCell(row[key])).join(','))].join('\r\n');const url=URL.createObjectURL(new Blob([csv],{type:'text/csv;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
export function exportRegister(view:string,filters:FinanceFilters){return rpc<Row[]>('finance_export',{p_view:view,p_from:filters.from,p_to:filters.to,p_status:filters.status,p_owner:filters.owner?Number(filters.owner):null});}
export async function downloadPdf(rows:Row[],keys:string[],title:string,period:string){
 if(rows.length>1000)throw new Error('financeExportLimit');
 const [{jsPDF},{default:html2canvas}]=await Promise.all([import('jspdf'),import('html2canvas')]);const doc=new jsPDF({orientation:'landscape'});let page=0;
 const host=document.createElement('div');host.setAttribute('aria-hidden','true');host.style.cssText='position:absolute;left:-10000px;top:0;width:1200px;background:#fff;color:#243047;font:14px Segoe UI,Microsoft YaHei,sans-serif;padding:12px;';document.body.append(host);
 try{
  for(let start=0;start<Math.max(rows.length,1); ){
   host.replaceChildren();const table=document.createElement('table');table.style.cssText='width:100%;min-width:0;table-layout:fixed;border-collapse:collapse;font-size:14px;';
   const header=document.createElement('tr');for(const key of keys){const th=document.createElement('th');th.textContent=key.replaceAll('_',' ');th.style.cssText='padding:10px 8px;background:#edf0f6;color:#243047;font-size:12px;text-align:left;white-space:normal;border:1px solid #ddd;';header.append(th);}table.append(header);
   host.append(table);let added=0;for(const row of rows.slice(start,start+10)){const tr=document.createElement('tr');for(const key of keys){const td=document.createElement('td');td.textContent=typeof row[key]==='object'&&row[key]!==null?JSON.stringify(row[key]):String(row[key]??'—');td.style.cssText='padding:10px 8px;border:1px solid #ddd;color:#243047;background:#fff;max-width:none;white-space:pre-wrap;overflow-wrap:anywhere;';tr.append(td);}table.append(tr);added++;if(host.scrollHeight>650)break;}
   await document.fonts.ready;const canvas=await html2canvas(host,{scale:1.5,logging:false,backgroundColor:'#ffffff',windowWidth:1400,scrollX:0,scrollY:0});const sliceHeight=Math.floor(canvas.width*155/268);
   for(let top=0;top<canvas.height;top+=sliceHeight){if(page)doc.addPage();page++;doc.setFontSize(14);doc.text('Charm Kenya | '+title+' | KES',14,14);doc.setFontSize(8);doc.text(period+' | Generated '+new Date().toISOString()+' | Page '+page,14,21);const slice=document.createElement('canvas');slice.width=canvas.width;slice.height=Math.min(sliceHeight,canvas.height-top);slice.getContext('2d')!.drawImage(canvas,0,top,canvas.width,slice.height,0,0,slice.width,slice.height);doc.addImage(slice.toDataURL('image/png'),'PNG',14,28,268,slice.height*268/slice.width);slice.width=0;slice.height=0;}
   canvas.width=0;canvas.height=0;start+=Math.max(1,added);
  }
  doc.save(`charm-${title.toLowerCase().replaceAll(' ','-')}.pdf`);
 }finally{host.remove();}
}

import { nairobiDate } from './dates';
import { cents } from './money';
import type { Row } from './data';
export function reportingMonths(month:string,count=6):string[] {
 const [year,m]=month.split('-').map(Number);
 return Array.from({length:count},(_,i)=>{const date=new Date(Date.UTC(year,m-count+i,1));return `${date.getUTCFullYear()}-${String(date.getUTCMonth()+1).padStart(2,'0')}`;});
}
export function formatMoney(value:unknown,language:string) {
 const text=String(value??'0');
 const valid=/^-?\d+(\.\d{1,2})?$/.test(text)?text:'0';
 const negative=valid.startsWith('-');
 const [whole,fraction='']=valid.replace(/^-/, '').split('.');
 const formatted=new Intl.NumberFormat(language==='zh'?'zh-CN':'en-KE').format(BigInt(whole));
 return `KES ${negative&&(BigInt(whole)!==0n||BigInt(fraction||'0')!==0n)?'-':''}${formatted}.${fraction.padEnd(2,'0')}`;
}
function parseMoneyCents(value:unknown):bigint|null {
 const text=String(value??'0');
 if(!/^-?\d+(\.\d{1,2})?$/.test(text))return null;
 const negative=text.startsWith('-');
 const [whole,fraction='']=text.replace(/^-/, '').split('.');
 const amount=BigInt(whole)*100n+BigInt(fraction.padEnd(2,'0'));
 return negative?-amount:amount;
}
export function sumMoney(values:unknown[]):string|null {
 let total=0n;
 for(const value of values){const amount=parseMoneyCents(value);if(amount===null)return null;total+=amount;}
 const negative=total<0n;const absolute=negative?-total:total;
 return `${negative?'-':''}${absolute/100n}.${(absolute%100n).toString().padStart(2,'0')}`;
}
export function settlement(balance:Row,today=nairobiDate()):string {
 const remaining=cents(String(balance.balance));const paid=cents(String(balance.paid));
 if(remaining===0n)return 'settled';
 if(balance.due_date&&balance.due_date<today)return 'overdue';
 return paid>0n?'partPaid':'unpaid';
}

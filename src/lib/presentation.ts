import { nairobiDate } from './dates';
import { cents } from './money';
import type { Row } from './data';
export function reportingMonths(month:string,count=6):string[] {
 const [year,m]=month.split('-').map(Number);
 return Array.from({length:count},(_,i)=>{const date=new Date(Date.UTC(year,m-count+i,1));return `${date.getUTCFullYear()}-${String(date.getUTCMonth()+1).padStart(2,'0')}`;});
}
export function formatMoney(value:unknown,language:string) {
 const text=String(value??'0');
 const valid=/^\d+(\.\d{1,2})?$/.test(text)?text:'0';
 const [whole,fraction='']=valid.split('.');
 return `KES ${new Intl.NumberFormat(language==='zh'?'zh-CN':'en-KE').format(BigInt(whole))}.${fraction.padEnd(2,'0')}`;
}
export function settlement(balance:Row,today=nairobiDate()):string {
 const remaining=cents(String(balance.balance));const paid=cents(String(balance.paid));
 if(remaining===0n)return 'settled';
 if(balance.due_date&&balance.due_date<today)return 'overdue';
 return paid>0n?'partPaid':'unpaid';
}

import { LayoutDashboard, ClipboardList, CreditCard, ShieldCheck, Wallet, Receipt, ShoppingBag, CalendarDays, Users, SlidersHorizontal } from 'lucide-react';
export const financePages=[
 ['dashboard','financeDashboard',LayoutDashboard],['requests','financerequests',ClipboardList],
 ['disbursements','financePaymentsPage',CreditCard],['accountability','accountability',ShieldCheck],
 ['cashbook','financecashbook',Wallet],['receipts','financereceipts',ShoppingBag],
 ['expenditure','financeexpenditure',Receipt],['budgets','financebudgets',CalendarDays],
 ['statements','financestatements',Wallet],['accounts','financeAccounts',SlidersHorizontal],
 ['audit','financeaudit',Users],
] as const;
export function financePage(path:string){const page=path.split('/')[2]||'dashboard';return financePages.some(([key])=>key===page)?page:'dashboard';}
export function financePath(page:string){return page==='dashboard'?'/finance':`/finance/${page}`;}

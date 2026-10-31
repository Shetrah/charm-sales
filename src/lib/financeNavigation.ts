import { LayoutDashboard, ClipboardList, CreditCard, ShieldCheck, Wallet, Receipt, ShoppingBag, CalendarDays, Users, SlidersHorizontal, Factory, Truck, FileCheck2, FileText } from 'lucide-react';
export const financePages=[
 ['dashboard','financeDashboard',LayoutDashboard],['expenses','financeExpenses',Receipt],['requests','financerequests',ClipboardList],
 ['suppliers','financeSuppliers',Truck],
 ['disbursements','financePaymentsPage',CreditCard],['accountability','accountability',ShieldCheck],
 ['cashbook','financecashbook',Wallet],['receipts','financereceipts',ShoppingBag],
 ['budgets','financebudgets',CalendarDays],
 ['batch_costs','financeBatchCosts',Factory],['purchases','financePurchases',Truck],['goods_receipts','financeGoodsReceipts',FileCheck2],['invoices','financeInvoices',FileText],['supplier_invoices','financeSupplierInvoices',FileText],
 ['statements','financestatements',Wallet],['accounts','financeAccounts',SlidersHorizontal],
 ['audit','financeaudit',Users],
] as const;
// Expenditure reports and operating postings now read from the consolidated register, so their bookmarks land there.
const legacyPages:Record<string,string>={expenditure:'expenses',operating:'expenses'};
export function financePage(path:string){const page=path.split('/')[2]||'dashboard';return legacyPages[page]??(financePages.some(([key])=>key===page)?page:'dashboard');}
export function financeLegacyPage(path:string){return legacyPages[path.split('/')[2]??''];}
export function financePath(page:string){return page==='dashboard'?'/finance':`/finance/${page}`;}

import { LayoutDashboard, ClipboardList, CreditCard, ShieldCheck, Wallet, Receipt, ShoppingBag, CalendarDays, Users, SlidersHorizontal, Factory, Truck, FileCheck2, FileText, ChartNoAxesCombined } from 'lucide-react';
export const financePages=[
 ['dashboard','financeDashboard',LayoutDashboard],['requests','financerequests',ClipboardList],
 ['suppliers','financeSuppliers',Truck],
 ['disbursements','financePaymentsPage',CreditCard],['accountability','accountability',ShieldCheck],
 ['cashbook','financecashbook',Wallet],['receipts','financereceipts',ShoppingBag],
 ['expenditure','financeexpenditure',Receipt],['budgets','financebudgets',CalendarDays],
 ['batch_costs','financeBatchCosts',Factory],['purchases','financePurchases',Truck],['goods_receipts','financeGoodsReceipts',FileCheck2],['invoices','financeInvoices',FileText],['supplier_invoices','financeSupplierInvoices',FileText],['operating','financeOperating',ChartNoAxesCombined],
 ['statements','financestatements',Wallet],['accounts','financeAccounts',SlidersHorizontal],
 ['audit','financeaudit',Users],
] as const;
export function financePage(path:string){const page=path.split('/')[2]||'dashboard';return financePages.some(([key])=>key===page)?page:'dashboard';}
export function financePath(page:string){return page==='dashboard'?'/finance':`/finance/${page}`;}

import { useEffect, useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { CalendarCheck, CalendarDays, Coins, Download, FileText, Pencil, Plus, Search, ShieldCheck, Trash2, UserRound, Users, X } from 'lucide-react';
import { useSearchParams } from 'react-router-dom';
import { Dialog, ErrorNotice, Field, Loading, Status } from './components';
import { usePreferences } from './i18n';
import { rpc, supabase } from './lib/supabase';
import { databaseError } from './lib/errors';
import { nairobiDate, type Profile, type Row } from './lib/data';
import { formatBusinessDate } from './lib/dates';
import { formatMoney } from './finance';
import { documentExtension, openPrivateFile, prepareDocument, uploadPrivate } from './lib/documents';
import { StaffDetail } from './Team';

const TABS = ['team','attendance','leave','commissions'] as const;
type Tab = typeof TABS[number];
const ATTENDANCE_STATUS = ['full','partial','incomplete','absent','leave'];
const LEAVE_MONTH = () => nairobiDate().slice(0,7);
const firstOfMonth = (date: string) => `${date.slice(0,7)}-01`;
const endOfMonth = (month: string) => new Date(Date.UTC(Number(month.slice(0,4)), Number(month.slice(5,7)), 0)).toISOString().slice(0,10);
const amount = (value: unknown) => Number(value ?? 0) || 0;
const sum = (rows: Row[], key: string) => rows.reduce((total, row) => total + amount(row[key]), 0);
const commissionWord: Record<string,string> = { earned:'commissionEarned', approved:'commissionApproved', paid:'commissionPaid', reversed:'commissionReversed', adjusted:'commissionAdjusted' };
const basisWord: Record<string,string> = { gross:'grossSales', net:'netSales', paid:'paidSales', delivered:'deliveredSales' };
const tiered = (method: string) => method === 'tiered';
const ruleRate = (rule: Row) => rule.method === 'percentage' ? `${Number(rule.rate ?? 0)}%` : rule.method === 'fixed' ? formatMoney(rule.fixed_amount, 'en') : '—';

function workingDaysBetween(start: string, end: string) {
 if (!start || !end || end < start) return 0;
 let count = 0; const cursor = new Date(`${start}T00:00:00Z`); const last = new Date(`${end}T00:00:00Z`);
 while (cursor <= last) { const day = cursor.getUTCDay(); if (day !== 0 && day !== 6) count += 1; cursor.setUTCDate(cursor.getUTCDate() + 1); }
 return count;
}

function downloadCsv(name: string, header: string[], rows: (string|number)[][]) {
 const escape = (cell: string|number) => `"${String(cell ?? '').replace(/"/g,'""')}"`;
 const blob = new Blob([[header, ...rows].map(line => line.map(escape).join(',')).join('\n')], { type: 'text/csv;charset=utf-8' });
 const url = URL.createObjectURL(blob); const link = document.createElement('a'); link.href = url; link.download = name; link.click(); URL.revokeObjectURL(url);
}

function AttendanceBadge({value}:{value:string}) {
 const {t} = usePreferences();
 return <span className={`badge ${value}`}>{t(value)}</span>;
}
function CommissionBadge({value}:{value:string}) {
 const {t} = usePreferences();
 return <span className={`badge ${value}`}>{t(commissionWord[value] ?? value)}</span>;
}
export default function PeoplePerformance({scope,profile}:{scope:string;profile:Profile}) {
 const {t,language} = usePreferences(); const qc = useQueryClient(); const admin = profile.role === 'admin';
 const available: Tab[] = admin ? [...TABS] : TABS.filter(value => value !== 'team');
 const [params] = useSearchParams();
 const requested = params.get('tab');
 const [tab,setTab] = useState<Tab>(requested && (TABS as readonly string[]).includes(requested) && available.includes(requested as Tab) ? requested as Tab : admin ? 'team' : 'attendance');
 const today = nairobiDate();
 const [from,setFrom] = useState(firstOfMonth(today)); const [to,setTo] = useState(today);
 const [range,setRange] = useState({ from: firstOfMonth(today), to: today });
 const [month,setMonth] = useState(LEAVE_MONTH());
 const [year,setYear] = useState(Number(today.slice(0,4)));
 const [balanceUser,setBalanceUser] = useState('');
 const [attendanceStaff,setAttendanceStaff] = useState<Row|null>(null);
 const [correction,setCorrection] = useState<Row|null>(null);
 const [leaveEditor,setLeaveEditor] = useState<Row|'new'|null>(null);
 const [leaveDecision,setLeaveDecision] = useState<Row|null>(null);
 const [ruleEditor,setRuleEditor] = useState<Row|'new'|null>(null);
 const [commissionAction,setCommissionAction] = useState<{entry:Row;status:string}|null>(null);
 const [staffProfile,setStaffProfile] = useState<Row|null>(null);
 const [busy,setBusy] = useState(false); const [error,setError] = useState<unknown>(); const [notice,setNotice] = useState('');
 const [search,setSearch] = useState(''); const [attendanceFilter,setAttendanceFilter] = useState('');

 const users = useQuery({queryKey:[scope,'people','users'],queryFn:async()=>{
  const {data,error} = await supabase!.from('users').select('id,name,email,role,active,phone,territory,staff_code').order('name').limit(300);
  if (error) throw databaseError(error); return (data ?? []) as Row[];
 }});
 const clients = useQuery({queryKey:[scope,'people','clients'],enabled:admin,queryFn:async()=>{
  const {data,error} = await supabase!.from('clients').select('id,name,location,salesperson_id,lifecycle_status').order('name').limit(800);
  if (error) throw databaseError(error); return (data ?? []) as Row[];
 }});
 const monthly = useQuery({queryKey:[scope,'people','monthly',month],enabled:admin && tab === 'team',queryFn:()=>rpc<Row>('monthly_summary',{p_month:`${month}-01`})});
 const attendance = useQuery({queryKey:[scope,'people','attendance',range.from,range.to],queryFn:()=>rpc<Row>('attendance_report',{p_from:range.from,p_to:range.to})});
 const leaveTypes = useQuery({queryKey:[scope,'people','leave-types'],queryFn:async()=>{
  const {data,error} = await supabase!.from('leave_types').select('*').eq('active',true).order('id');
  if (error) throw databaseError(error); return (data ?? []) as Row[];
 }});
 const leaveRequests = useQuery({queryKey:[scope,'people','leave'],queryFn:async()=>{
  const {data,error} = await supabase!.from('leave_requests').select('*').order('id',{ascending:false}).limit(500);
  if (error) throw databaseError(error); return (data ?? []) as Row[];
 }});
 const balances = useQuery({queryKey:[scope,'people','balances',year,balanceUser],queryFn:()=>rpc<Row[]>('leave_balances',admin && balanceUser ? {p_year:year,p_user:Number(balanceUser)} : {p_year:year})});
 const commission = useQuery({queryKey:[scope,'people','commission',month],queryFn:()=>rpc<Row>('commission_summary',{p_from:`${month}-01`,p_to:endOfMonth(month)})});
 const rules = useQuery({queryKey:[scope,'people','rules'],enabled:admin,queryFn:async()=>{
  const {data,error} = await supabase!.from('commission_rules').select('*').order('id',{ascending:false}).limit(300);
  if (error) throw databaseError(error); return (data ?? []) as Row[];
 }});
 const tiers = useQuery({queryKey:[scope,'people','tiers'],enabled:admin,queryFn:async()=>{
  const {data,error} = await supabase!.from('commission_tiers').select('*').order('min_amount').limit(800);
  if (error) throw databaseError(error); return (data ?? []) as Row[];
 }});

 const userById = useMemo(()=>new Map((users.data ?? []).map(row => [String(row.id),row])),[users.data]);
 const tiersByRule = useMemo(()=>{const map = new Map<string,Row[]>();for (const tier of tiers.data ?? []){const key = String(tier.rule_id);map.set(key,[...(map.get(key) ?? []),tier]);}return map;},[tiers.data]);
 const clientsByOwner = useMemo(()=>{const map = new Map<string,Row[]>();for (const client of clients.data ?? []){const key = String(client.salesperson_id);map.set(key,[...(map.get(key) ?? []),client]);}return map;},[clients.data]);
 const attendanceRows: Row[] = attendance.data?.rows ?? [];
 const attendanceTotals: Row[] = attendance.data?.totals ?? [];
 const commissionRows: Row[] = commission.data?.rows ?? [];
 const commissionTotals: Row = commission.data?.totals ?? {};
 const policy: Row|null = attendance.data?.policy ?? null;
 const pendingLeave = (leaveRequests.data ?? []).filter(row => row.status === 'pending');
 const balanceRows: Row[] = Array.isArray(balances.data) ? balances.data : [];
 const staffRows = (users.data ?? []).filter(row => row.role === 'salesperson' || row.role === 'admin');
 const filteredStaff = staffRows.filter(row => {
  const needle = search.trim().toLowerCase(); if (!needle) return true;
  return [row.name,row.staff_code,row.phone,row.territory].some(value => String(value ?? '').toLowerCase().includes(needle));
 });
 const visibleTotals = attendanceFilter ? attendanceTotals.filter(row => String(row.salesperson_id) === attendanceFilter) : attendanceTotals;
 const presentTotal = sum(visibleTotals,'present'); const dayTotal = sum(visibleTotals,'days'); const hoursTotal = sum(visibleTotals,'hours');

 const refresh = async (message: string) => { await qc.invalidateQueries({queryKey:[scope,'people']}); if (message) { setNotice(t(message)); setTimeout(()=>setNotice(''),4500); } };
 async function run(action: () => Promise<unknown>, message: string) {
  setBusy(true); setError(undefined);
  try { await action(); await refresh(message); }
  catch (next) { setError(next); }
  finally { setBusy(false); }
 }

 const heading: Record<Tab,string> = {team:'teamPerformance',attendance:'attendanceTitle',leave:'leaveTitle',commissions:'commissionsTitle'};
 const intro: Record<Tab,string> = {team:'teamIntroPp',attendance:'attendanceIntro',leave:'leaveIntro',commissions:'commissionsIntro'};

 return <main className="content people-page">
  <div className="page-heading"><div><span className="eyebrow">CHARM KENYA · {t('businessTimeZone')}</span><h1>{t('peopleTitle')}</h1><p>{t(intro[tab])}</p></div>
   {tab==='leave'&&<button className="primary" onClick={()=>setLeaveEditor('new')}><Plus size={18}/>{t('requestLeave')}</button>}
   {tab==='commissions'&&admin&&<button className="primary" onClick={()=>setRuleEditor('new')}><Plus size={18}/>{t('newCommissionRule')}</button>}
  </div>
  <nav className="field-tabs" role="tablist" aria-label={t('peopleTitle')}>
   {available.map(value=><button type="button" role="tab" aria-selected={tab===value} key={value} className={tab===value?'active':''} onClick={()=>setTab(value)}>
    {value==='team'?<Users size={16}/>:value==='attendance'?<CalendarCheck size={16}/>:value==='leave'?<CalendarDays size={16}/>:<Coins size={16}/>}
    <span>{t(value==='team'?'teamPerformance':value==='attendance'?'attendanceTab':value==='leave'?'leaveTab':'commissionsTab')}</span>
    {value==='leave'&&pendingLeave.length>0&&<em>{pendingLeave.length}</em>}
   </button>)}
  </nav>
  <div className="field-cards people-kpis">
   {admin&&<button type="button" className="card field-card" onClick={()=>setTab('team')}><span className="eyebrow">{t('teamDirectory')}</span><strong>{staffRows.filter(row=>row.active).length}</strong><small>{staffRows.length} {t('staff').toLowerCase()}</small><Users size={19}/></button>}
   <button type="button" className="card field-card" onClick={()=>setTab('attendance')}><span className="eyebrow">{t('presentDays')}</span><strong>{presentTotal}/{dayTotal}</strong><small>{t('hoursPp')}: {hoursTotal.toFixed(1)}</small><CalendarCheck size={19}/></button>
   <button type="button" className="card field-card" onClick={()=>setTab('leave')}><span className="eyebrow">{t('pendingLeave')}</span><strong>{pendingLeave.length}</strong><small>{t('leaveBalance')}</small><CalendarDays size={19}/></button>
   <button type="button" className="card field-card" onClick={()=>setTab('commissions')}><span className="eyebrow">{t('commissionEarned')}</span><strong>{formatMoney(commissionTotals.earned ?? 0,language)}</strong><small>{t('commissionPending')}: {formatMoney(commissionTotals.pending ?? 0,language)}</small><Coins size={19}/></button>
  </div>
  {!!notice&&<div className="notice" role="status">{notice}</div>}
  {!!error&&<ErrorNotice error={error} retry={()=>setError(undefined)}/>}

  {tab==='team'&&admin&&<section className="people-team">
   <div className="people-search"><Search size={18}/><input aria-label={t('searchStaff')} placeholder={t('searchStaff')} value={search} onChange={event=>setSearch(event.target.value)}/><span>{filteredStaff.length}</span></div>
   <p className="field-note">{t('staffSearchHint')}</p>
   {users.isPending?<Loading/>:users.isError?<ErrorNotice error={users.error} retry={()=>users.refetch()}/>:filteredStaff.length===0?<p className="field-empty">{t('noStaffMatch')}</p>:<div className="people-grid">{filteredStaff.map(person=>{
    const sales = (monthly.data?.team ?? []).find((row:Row)=>row.id===person.id)?.sales ?? 0;
    const commissionRow = (commission.data?.staff ?? []).find((row:Row)=>row.salesperson_id===person.id);
    const assigned = clientsByOwner.get(String(person.id)) ?? [];
    const lifecycle = (status: string) => assigned.filter(row => (row.lifecycle_status ?? 'active') === status).length;
    return <article className="card people-card" key={person.id}>
     <header><div className="person-avatar">{String(person.name).split(' ').slice(0,2).map((part:string)=>part[0]).join('')}</div><div><h2>{person.name}</h2><span className="people-code">{person.staff_code ?? `#${person.id}`}</span></div><Status value={person.role}/></header>
     <div className="people-badges"><span className={`badge ${person.active?'active':'declined'}`}>{t(person.active?'active':'inactive')}</span>{!person.active&&<span className="badge declined">{t('inactive')}</span>}</div>
     <dl className="people-facts"><div><dt>{t('phone')}</dt><dd>{person.phone??t('notProvided')}</dd></div><div><dt>{t('territory')}</dt><dd>{person.territory??t('notProvided')}</dd></div></dl>
     <div className="people-metrics"><div><span>{t('monthlySales')}</span><strong>{formatMoney(sales,language)}</strong></div><div><span>{t('clientsAssigned')}</span><strong>{assigned.length}</strong></div><div><span>{t('commissionEarned')}</span><strong>{formatMoney(commissionRow?.earned ?? 0,language)}</strong></div></div>
     <div className="people-lifecycle"><span>{t('clientLifecycle')}</span><div><span className="badge active">{t('active')} {lifecycle('active')}</span><span className="badge prospective">{t('prospective')} {lifecycle('prospective')}</span><span className="badge declined">{t('declined')} {lifecycle('declined')}</span></div></div>
     <button type="button" className="primary" onClick={()=>setStaffProfile(person)}>{t('viewPerformance')}<UserRound size={16}/></button>
    </article>;
   })}</div>}
  </section>}

  {tab==='attendance'&&<section className="people-section">
   <div className="card people-toolbar">
    <Field label="dateFrom"><input type="date" value={from} max={to} onChange={event=>setFrom(event.target.value)}/></Field>
    <Field label="dateTo"><input type="date" value={to} min={from} onChange={event=>setTo(event.target.value)}/></Field>
    {admin&&<Field label="staffFilter"><select value={attendanceFilter} onChange={event=>setAttendanceFilter(event.target.value)}><option value="">{t('allStaff')}</option>{staffRows.map(person=><option key={person.id} value={person.id}>{person.name} · {person.staff_code}</option>)}</select></Field>}
    <button type="button" className="primary" onClick={()=>setRange({from,to})}>{t('applyRange')}</button>
    <button type="button" disabled={!attendanceRows.length} onClick={()=>downloadCsv(`attendance-${range.from}-${range.to}.csv`,[t('staffCode'),t('name'),t('date'),t('attendanceStatus'),t('hoursPp'),t('visitCount')],(attendanceFilter?attendanceRows.filter(row=>String(row.salesperson_id)===attendanceFilter):attendanceRows).map(row=>[row.staff_code,row.name,row.day,row.status,row.hours,row.visit_count]))}><Download size={16}/>{t('exportAttendance')}</button>
   </div>
   <p className="field-note">{t('attendanceScopeNote')}</p>
   {attendance.isPending?<Loading/>:attendance.isError?<ErrorNotice error={attendance.error} retry={()=>attendance.refetch()}/>:<>
    <div className="people-summary-grid">{visibleTotals.map(row=><button type="button" className="card people-summary" key={row.salesperson_id} onClick={()=>setAttendanceStaff(row)}>
     <header><div><strong>{row.name}</strong><span>{row.staff_code}</span></div><span className="people-hours">{Number(row.hours ?? 0).toFixed(1)} h</span></header>
     <div className="people-summary-bars"><span><em>{t('presentDays')}</em><strong>{row.present}/{row.days}</strong></span><span><em>{t('fullDays')}</em><strong>{row.full}</strong></span><span><em>{t('partialDays')}</em><strong>{row.partial}</strong></span><span><em>{t('absentDays')}</em><strong>{row.absent}</strong></span><span><em>{t('leaveDays')}</em><strong>{row.leave}</strong></span></div>
     <div className="people-meter"><div style={{width:`${row.days?Math.min(100,Number(row.present)/Number(row.days)*100):0}%`}}/></div>
    </button>)}</div>
    {visibleTotals.length===0&&<p className="field-empty">{t('noAttendance')}</p>}
    {admin&&<section className="card people-policy"><header><h2>{t('attendancePolicy')}</h2><ShieldCheck size={18}/></header><PolicyEditor policy={policy} busy={busy} onSave={value=>run(()=>rpc('save_attendance_policy',value),'attendancePolicySaved')}/><p className="field-note">{t('attendancePolicyHint')} {t('correctionsHint')}</p></section>}
   </>}
  </section>}

  {tab==='leave'&&<section className="people-section">
   <div className="people-columns">
    <section className="card people-balance-card">
     <header><h2>{t('leaveBalance')}</h2><div className="people-inline">{admin&&<select aria-label={t('selectStaff')} value={balanceUser} onChange={event=>setBalanceUser(event.target.value)}><option value="">{t('myWorkspace')}</option>{staffRows.map(person=><option key={person.id} value={person.id}>{person.name} · {person.staff_code}</option>)}</select>}<input aria-label={t('year')} type="number" min="2000" max="2100" value={year} onChange={event=>setYear(Number(event.target.value))}/></div></header>
     {balances.isPending?<Loading/>:balances.isError?<ErrorNotice error={balances.error} retry={()=>balances.refetch()}/>:balanceRows.length===0?<p className="field-empty">{t('noLeaveRequests')}</p>:<div className="people-balances">{balanceRows.map(row=><div key={row.leave_type_id}><span>{row.name}</span><div><small>{t('entitled')} {row.entitled}</small><small>{t('usedLeave')} {row.approved}</small><small>{t('remainingLeave')} {row.remaining}</small></div><div className="people-meter"><div style={{width:`${Number(row.entitled)>0?Math.min(100,Number(row.approved)/Number(row.entitled)*100):0}%`}}/></div></div>)}</div>}
     <p className="field-note">{t('leaveBalanceHint')}</p>
    </section>
    <section className="card people-request-list">
     <header><h2>{t('leaveTitle')}</h2><span className="small-label">{pendingLeave.length} {t('pendingLeave')}</span></header>
     {leaveRequests.isPending?<Loading/>:leaveRequests.isError?<ErrorNotice error={leaveRequests.error} retry={()=>leaveRequests.refetch()}/>:(leaveRequests.data ?? []).length===0?<p className="field-empty">{t('noLeaveRequests')}</p>:<div className="people-requests">{(leaveRequests.data ?? []).map(row=>{
      const owner = userById.get(String(row.salesperson_id)); const type = (leaveTypes.data ?? []).find(item=>item.id===row.leave_type_id); const editable = ['draft','rejected'].includes(row.status) && (admin || row.salesperson_id === profile.id);
      return <article className="people-request" key={row.id}>
       <header><div><strong>{owner?.name ?? `#${row.salesperson_id}`}</strong><span>{owner?.staff_code ?? ''} · {type?.name ?? `#${row.leave_type_id}`}</span></div><Status value={row.status}/></header>
       <div className="people-request-dates"><span>{formatBusinessDate(row.start_date,language)}</span><span>→</span><span>{formatBusinessDate(row.end_date,language)}</span><strong>{Number(row.days)} {t('leaveDaysLabel').toLowerCase()}</strong></div>
       <p>{row.reason}</p>
       {row.decision_reason&&<small className="people-decision">{t('decisionReason')}: {row.decision_reason}</small>}
       <div className="people-actions">
        {row.document_path&&<button type="button" onClick={async()=>{try{const url=await openPrivateFile(row.document_path,120);window.open(url,'_blank','noopener');}catch(next){setError(next);}}}><FileText size={15}/>{t('supportingDocument')}</button>}
        {editable&&<button type="button" onClick={()=>setLeaveEditor(row)}><Pencil size={15}/>{t('editLeaveRequest')}</button>}
        {row.status==='draft'&&<button type="button" className="primary" disabled={busy} onClick={()=>run(()=>rpc('submit_leave_request',{p_id:row.id}),'leaveSubmittedMsg')}>{t('submitLeave')}</button>}
        {['draft','pending'].includes(row.status)&&<button type="button" disabled={busy} onClick={()=>run(()=>rpc('cancel_leave_request',{p_id:row.id}),'leaveCancelledMsg')}><X size={15}/>{t('cancelLeave')}</button>}
        {admin&&row.status==='pending'&&row.salesperson_id!==profile.id&&<button type="button" className="primary" onClick={()=>setLeaveDecision(row)}><ShieldCheck size={15}/>{t('decision')}</button>}
       </div>
      </article>;
     })}</div>}
    </section>
   </div>
  </section>}

  {tab==='commissions'&&<section className="people-section">
   <div className="card people-toolbar">
    <Field label="monthRange"><input type="month" value={month} onChange={event=>setMonth(event.target.value || LEAVE_MONTH())}/></Field>
    <span className="people-period">{formatBusinessDate(`${month}-01`,language)} → {formatBusinessDate(endOfMonth(month),language)}</span>
    <button type="button" disabled={!commissionRows.length} onClick={()=>downloadCsv(`commissions-${month}.csv`,[t('staffCode'),t('name'),t('order_id'),t('basisLabel'),t('commissionAmount'),t('status')],commissionRows.map(row=>[row.staff_code,row.name,row.order_id,row.basis,row.commission,row.status]))}><Download size={16}/>{t('exportCommission')}</button>
   </div>
   {commission.isPending?<Loading/>:commission.isError?<ErrorNotice error={commission.error} retry={()=>commission.refetch()}/>:<>
    <div className="people-money">{['earned','pending','approved','paid','reversed'].map(key=><div key={key} className={`card people-money-card ${key}`}><span>{t(key==='pending'?'commissionPending':key==='earned'?'commissionEarned':key==='approved'?'commissionApproved':key==='paid'?'commissionPaid':'commissionReversed')}</span><strong>{formatMoney(commissionTotals[key] ?? 0,language)}</strong><small>{key==='earned'?`${commissionTotals.entries ?? 0} ${t('commissionEntries').toLowerCase()}`:''}</small></div>)}</div>
    <p className="field-note">{t('commissionSummaryHint')}</p>
    {admin&&<section className="card people-rules"><header><h2>{t('commissionRules')}</h2><button type="button" className="text-button" onClick={()=>setRuleEditor('new')}><Plus size={15}/>{t('newCommissionRule')}</button></header>
     {(rules.data ?? []).length===0?<p className="field-empty">{t('noRules')}</p>:<div className="people-rule-list">{(rules.data ?? []).map(rule=>{const ruleTiers = tiersByRule.get(String(rule.id)) ?? [];return <article className="people-rule" key={rule.id}>
      <header><div><strong>{rule.name}</strong><span>{t(basisWord[rule.basis] ?? rule.basis)} · {t(rule.method==='percentage'?'percentage':rule.method==='fixed'?'fixedAmount':'tiered')}</span></div><span className={`badge ${rule.active?'active':'declined'}`}>{t(rule.active?'ruleActive':'ruleInactive')}</span></header>
      <div className="people-rule-meta"><span>{ruleRate(rule)}</span><span>{formatBusinessDate(rule.effective_from,language)} → {rule.effective_to?formatBusinessDate(rule.effective_to,language):'—'}</span>{ruleTiers.length>0&&<span>{ruleTiers.map(item=>`${Number(item.min_amount)}–${item.max_amount==null?'∞':Number(item.max_amount)}: ${Number(item.rate)}%`).join(' · ')}</span>}</div>
      <div className="people-actions"><button type="button" onClick={()=>setRuleEditor(rule)}><Pencil size={15}/>{t('editCommissionRule')}</button></div>
     </article>;})}</div>}
     <p className="field-note">{t('commissionRuleHint')} {t('commissionRulesHint')}</p>
    </section>}
    <section className="card people-commission-list"><header><h2>{t('commissionBreakdown')}</h2><span className="small-label">{t('monthRange')} {month}</span></header>
     {commissionRows.length===0?<p className="field-empty">{t('noCommission')}</p>:<div className="people-entries">{commissionRows.map(entry=><article className="people-entry" key={entry.id}>
      <header><div><strong>#{entry.order_id} · {entry.client ?? '—'}</strong><span>{entry.staff_code} · {entry.name}</span></div><CommissionBadge value={entry.status}/></header>
      <div className="people-entry-meta"><span>{t('orderTotal')}: {formatMoney(entry.order_total,language)}</span><span>{t('basisLabel')}: {t(basisWord[entry.basis] ?? entry.basis)}</span><span>{t('commissionRate')}: {entry.rate==null?'—':`${Number(entry.rate)}%`}</span></div>
      <div className="people-entry-amount"><span>{t('commissionAmount')}</span><strong>{formatMoney(entry.commission,language)}</strong></div>
      {admin&&<div className="people-actions">
       {entry.status==='earned'&&<button type="button" className="primary" disabled={busy} onClick={()=>run(()=>rpc('commission_decide',{p_entry:entry.id,p_status:'approved',p_amount:null,p_reason:''}),'commissionApproved')}>{t('approveCommission')}</button>}
       {entry.status==='approved'&&<button type="button" className="primary" disabled={busy} onClick={()=>run(()=>rpc('commission_decide',{p_entry:entry.id,p_status:'paid',p_amount:null,p_reason:''}),'commissionPaid')}>{t('payCommission')}</button>}
       {['earned','approved','adjusted'].includes(entry.status)&&<button type="button" onClick={()=>setCommissionAction({entry,status:'reversed'})}>{t('reverseCommission')}</button>}
       {['earned','approved'].includes(entry.status)&&<button type="button" onClick={()=>setCommissionAction({entry,status:'adjusted'})}>{t('adjustCommission')}</button>}
      </div>}
     </article>)}</div>}
     <p className="field-note">{t('commissionPendingHint')}</p>
    </section>
   </>}
  </section>}

  {staffProfile&&<StaffDetail row={staffProfile} scope={scope} currentUserId={profile.id} onClose={()=>setStaffProfile(null)} onSaved={()=>{void refresh('');}}/>}
  {attendanceStaff&&<AttendanceDetail staff={attendanceStaff} rows={attendanceRows.filter(row=>String(row.salesperson_id)===String(attendanceStaff.salesperson_id))} admin={admin} language={language} t={t} busy={busy} onClose={()=>setAttendanceStaff(null)} onCorrect={row=>{setAttendanceStaff(null);setCorrection(row);}}/>}
  {correction&&<AttendanceCorrection row={correction} onClose={()=>setCorrection(null)} onSaved={async message=>{setCorrection(null);await run(async()=>undefined,message);}}/>}
  {leaveEditor&&<LeaveEditor profile={profile} admin={admin} users={staffRows} types={leaveTypes.data ?? []} request={leaveEditor==='new'?null:leaveEditor} busy={busy} setBusy={setBusy} error={error} setError={setError} onClose={()=>setLeaveEditor(null)} onSaved={async message=>{setLeaveEditor(null);await refresh(message);}}/>}
  {leaveDecision&&<LeaveDecision request={leaveDecision} onClose={()=>setLeaveDecision(null)} onSaved={async message=>{setLeaveDecision(null);await run(async()=>undefined,message);}} busy={busy} error={error}/>}
  {ruleEditor&&<CommissionRuleEditor rule={ruleEditor==='new'?null:ruleEditor} ruleTiers={ruleEditor==='new'?[]:tiersByRule.get(String(ruleEditor.id)) ?? []} onClose={()=>setRuleEditor(null)} onSaved={async()=>{setRuleEditor(null);await run(async()=>undefined,'commissionRuleSaved');}} busy={busy} error={error}/>}
  {commissionAction&&<CommissionDecision entry={commissionAction.entry} status={commissionAction.status} onClose={()=>setCommissionAction(null)} onSaved={async message=>{setCommissionAction(null);await run(async()=>undefined,message);}} busy={busy} error={error}/>}
 </main>;
}

function AttendanceDetail({staff,rows,admin,language,t,busy,onClose,onCorrect}:{staff:Row;rows:Row[];admin:boolean;language:'en'|'zh';t:(key:string)=>string;busy:boolean;onClose:()=>void;onCorrect:(row:Row)=>void}) {
 const usage = rows.reduce((total,row)=>total+Number(row.visit_count ?? 0),0);
 return <Dialog title={`${t('attendanceSummary')} · ${staff.name}`} onClose={onClose}>
  <dl className="field-meta-list"><div><dt>{t('staffCode')}</dt><dd>{staff.staff_code}</dd></div><div><dt>{t('presentDays')}</dt><dd>{staff.present}/{staff.days}</dd></div><div><dt>{t('hoursPp')}</dt><dd>{Number(staff.hours ?? 0).toFixed(1)}</dd></div><div><dt>{t('visitCount')}</dt><dd>{usage}</dd></div></dl>
  {rows.length===0?<p className="field-empty">{t('noAttendance')}</p>:<div className="people-day-list">{rows.map(row=><div className={`people-day ${row.status}`} key={row.day}><div><strong>{formatBusinessDate(row.day,language)}</strong><span>{row.visit_count} {t('visitCount').toLowerCase()} · {Number(row.hours ?? 0).toFixed(1)} h{row.corrected?` · ${t('correction')}`:''}</span>{row.note&&<small>{row.note}</small>}</div><AttendanceBadge value={row.status}/>{admin&&<button type="button" disabled={busy} onClick={()=>onCorrect(row)}>{t('correction')}</button>}</div>)}</div>}
  <div className="dialog-actions"><button type="button" onClick={onClose}>{t('close')}</button></div>
 </Dialog>;
}

function AttendanceCorrection({row,onClose,onSaved}:{row:Row;onClose:()=>void;onSaved:(message:string)=>Promise<void>}) {
 const {t} = usePreferences(); const [status,setStatus] = useState(row.status === 'absent' ? 'full' : row.status); const [reason,setReason] = useState(''); const [note,setNote] = useState(''); const [working,setWorking] = useState(false); const [localError,setLocalError] = useState<unknown>();
 async function submit(){setLocalError(undefined);if(reason.trim().length<3){setLocalError(new Error('reasonRequired'));return;}setWorking(true);try{await rpc('correct_attendance',{p_user:Number(row.salesperson_id),p_day:row.day,p_status:status,p_reason:reason.trim(),p_note:note.trim()});await onSaved('attendanceCorrected');}catch(next){setLocalError(next);}finally{setWorking(false);}}
 return <Dialog title={`${t('correctAttendance')} · ${row.name}`} onClose={onClose}>
  <p className="field-note">{formatBusinessDate(row.day,'en')} · {t('correctionsHint')}</p>
  <form className="field-form" noValidate onSubmit={event=>{event.preventDefault();void submit();}}>
   <Field label="attendanceStatus"><select value={status} onChange={event=>setStatus(event.target.value)}>{ATTENDANCE_STATUS.map(value=><option key={value} value={value}>{t(value)}</option>)}<option value="auto">{t('restoreAutomatic')}</option></select></Field>
   <Field label="correctionReason"><input required minLength={3} maxLength={500} value={reason} onChange={event=>setReason(event.target.value)}/></Field>
   <Field label="correctionNote"><input maxLength={500} value={note} onChange={event=>setNote(event.target.value)}/></Field>
   {!!localError&&<ErrorNotice error={localError}/>}
   <div className="dialog-actions"><button type="button" onClick={onClose}>{t('cancel')}</button><button className="primary" disabled={working||reason.trim().length<3}>{t(working?'saving':'recordAttendanceDecision')}</button></div>
  </form>
 </Dialog>;
}

function PolicyEditor({policy,busy,onSave}:{policy:Row|null;busy:boolean;onSave:(value:Record<string,unknown>)=>void}) {
 const {t} = usePreferences(); const [value,setValue] = useState({full:'8',min:'4',start:'08:00',end:'17:00',grace:'15',days:[1,2,3,4,5] as number[]});
 useEffect(()=>{if(policy)setValue({full:String(policy.full_day_hours ?? 8),min:String(policy.min_hours ?? 4),start:String(policy.start_time ?? '08:00').slice(0,5),end:String(policy.end_time ?? '17:00').slice(0,5),grace:String(policy.late_grace_minutes ?? 15),days:(policy.working_days ?? [1,2,3,4,5]).map(Number)});},[policy]);
 const toggle=(day:number)=>setValue(previous=>({...previous,days:previous.days.includes(day)?previous.days.filter(item=>item!==day):[...previous.days,day].sort()}));
 return <form className="field-form people-policy-form" noValidate onSubmit={event=>{event.preventDefault();onSave({p_full:Number(value.full),p_min:Number(value.min),p_start:value.start,p_end:value.end,p_grace:Number(value.grace),p_days:value.days});}}>
  <div className="field-form-grid"><Field label="fullDayHours"><input type="number" min="0.5" max="24" step="0.5" value={value.full} onChange={event=>setValue({...value,full:event.target.value})}/></Field><Field label="minHours"><input type="number" min="0.5" max="24" step="0.5" value={value.min} onChange={event=>setValue({...value,min:event.target.value})}/></Field><Field label="workdayStart"><input type="time" value={value.start} onChange={event=>setValue({...value,start:event.target.value})}/></Field><Field label="workdayEnd"><input type="time" value={value.end} onChange={event=>setValue({...value,end:event.target.value})}/></Field><Field label="lateGrace"><input type="number" min="0" max="240" value={value.grace} onChange={event=>setValue({...value,grace:event.target.value})}/></Field></div>
  <div className="field"><span>{t('workingDays')}</span><div className="people-weekdays">{[1,2,3,4,5,6,7].map(day=><label key={day}><input type="checkbox" checked={value.days.includes(day)} onChange={()=>toggle(day)}/>{t(`wd${day}`)}</label>)}</div></div>
  <button className="primary" disabled={busy||value.days.length===0}>{t(busy?'saving':'savePolicy')}</button>
 </form>;
}

function LeaveEditor({profile,admin,users,types,request,busy,setBusy,error,setError,onClose,onSaved}:{profile:Profile;admin:boolean;users:Row[];types:Row[];request:Row|null;busy:boolean;setBusy:(value:boolean)=>void;error:unknown;setError:(value:unknown)=>void;onClose:()=>void;onSaved:(message:string)=>Promise<void>}) {
 const {t} = usePreferences(); const [owner,setOwner] = useState(request?String(request.salesperson_id):String(profile.id)); const [type,setType] = useState(request?String(request.leave_type_id):String(types[0]?.id ?? '')); const [start,setStart] = useState(request?.start_date ?? nairobiDate()); const [end,setEnd] = useState(request?.end_date ?? nairobiDate()); const [reason,setReason] = useState(request?.reason ?? ''); const [document,setDocument] = useState<string>(request?.document_path ?? ''); const [file,setFile] = useState<File|null>(null); const [key] = useState(()=>crypto.randomUUID()); const [fileBusy,setFileBusy] = useState(false); const [localError,setLocalError] = useState<unknown>();
 const selectedType = types.find(item=>String(item.id)===type); const days = workingDaysBetween(start,end);
 async function save(submit: boolean) {
  setBusy(true); setLocalError(undefined); setError(undefined);
  try {
   let path = document || null;
   if (file) { setFileBusy(true); const prepared = await prepareDocument(file); path = `leave/${owner}/${crypto.randomUUID()}.${documentExtension(prepared.type)}`; await uploadPrivate(path, prepared); setFileBusy(false); }
   if (selectedType?.requires_document && !path) throw new Error('documentRequired');
   const id = await rpc<number>('save_leave_request',{p_key:key,p_id:request?.id ?? null,p_type:Number(type),p_start:start,p_end:end,p_reason:reason.trim(),p_document:path,p_user:admin?Number(owner):null});
   if (submit) await rpc('submit_leave_request',{p_id:id});
   await onSaved(submit?'leaveSubmittedMsg':'saved');
  } catch (next) { setLocalError(next); }
  finally { setFileBusy(false); setBusy(false); }
 }
 return <Dialog title={request?t('editLeaveRequest'):t('newLeaveRequest')} onClose={onClose}>
  <form className="field-form" noValidate onSubmit={event=>{event.preventDefault();void save(false);}}>
   {admin&&!request&&<Field label="selectStaff"><select required value={owner} onChange={event=>setOwner(event.target.value)}>{users.map(person=><option key={person.id} value={person.id}>{person.name} · {person.staff_code}</option>)}</select></Field>}
   <div className="field-form-grid"><Field label="leaveType"><select required value={type} onChange={event=>setType(event.target.value)}><option value="">{t('choose')}</option>{types.map(item=><option key={item.id} value={item.id}>{item.name}</option>)}</select></Field><Field label="leaveDaysLabel"><input readOnly value={`${days}`} /></Field><Field label="leaveStart"><input required type="date" value={start} onChange={event=>setStart(event.target.value)}/></Field><Field label="leaveEnd"><input required type="date" min={start} value={end} onChange={event=>setEnd(event.target.value)}/></Field></div>
   <Field label="leaveReason"><textarea required minLength={3} maxLength={2000} value={reason} onChange={event=>setReason(event.target.value)}/></Field>
   <Field label="supportingDocument"><input type="file" accept="image/jpeg,image/png,image/webp,application/pdf" onChange={event=>{setFile(event.target.files?.[0] ?? null);event.target.value='';}}/><small>{t('leaveDocumentHint')}</small></Field>
   {document&&<p className="field-note">{t('documentAttached')}: {document.split('/').pop()}</p>}
   {fileBusy&&<p className="field-note" role="status">{t('loading')}</p>}
   {selectedType?.requires_document&&!document&&!file&&<p className="field-note">{t('documentRequired')}</p>}
   {!!localError&&<ErrorNotice error={localError}/>}{!!error&&<ErrorNotice error={error}/>}
   <div className="dialog-actions"><button type="button" onClick={onClose}>{t('cancel')}</button><button type="button" disabled={busy||fileBusy||days<=0} onClick={()=>void save(false)}>{t('saveDraft')}</button><button type="button" className="primary" disabled={busy||fileBusy||days<=0} onClick={()=>void save(true)}>{t('submitLeave')}</button></div>
  </form>
 </Dialog>;
}

function LeaveDecision({request,onClose,onSaved,busy,error}:{request:Row;onClose:()=>void;onSaved:(message:string)=>Promise<void>;busy:boolean;error:unknown}) {
 const {t} = usePreferences(); const [decision,setDecision] = useState('approve'); const [reason,setReason] = useState(''); const [localError,setLocalError] = useState<unknown>(); const [working,setWorking] = useState(false);
 async function submit(){setLocalError(undefined);if(decision==='reject'&&reason.trim().length<3){setLocalError(new Error('reasonRequired'));return;}setWorking(true);try{await rpc('decide_leave_request',{p_id:request.id,p_decision:decision,p_reason:reason.trim()});await onSaved(decision==='approve'?'leaveApprovedMsg':'leaveRejectedMsg');}catch(next){setLocalError(next);}finally{setWorking(false);}}
 return <Dialog title={`${t('leaveDecisionTitle')} · #${request.id}`} onClose={onClose}>
  <form className="field-form" noValidate onSubmit={event=>{event.preventDefault();void submit();}}>
   <p className="field-note">{request.reason}</p>
   <Field label="decision"><select value={decision} onChange={event=>setDecision(event.target.value)}><option value="approve">{t('approveLeave')}</option><option value="reject">{t('rejectLeave')}</option></select></Field>
   <Field label="decisionReason"><textarea required={decision==='reject'} minLength={3} maxLength={2000} value={reason} onChange={event=>setReason(event.target.value)}/></Field>
   {!!localError&&<ErrorNotice error={localError}/>}{!!error&&<ErrorNotice error={error}/>}
   <div className="dialog-actions"><button type="button" onClick={onClose}>{t('cancel')}</button><button className="primary" disabled={working||busy}>{t(working||busy?'saving':decision==='approve'?'approveLeave':'rejectLeave')}</button></div>
  </form>
 </Dialog>;
}

type TierDraft = {min:string;max:string;rate:string};
function CommissionRuleEditor({rule,ruleTiers,onClose,onSaved,busy,error}:{rule:Row|null;ruleTiers:Row[];onClose:()=>void;onSaved:(message:string)=>Promise<void>;busy:boolean;error:unknown}) {
 const {t} = usePreferences(); const [value,setValue] = useState({name:String(rule?.name ?? ''),basis:String(rule?.basis ?? 'gross'),method:String(rule?.method ?? 'percentage'),rate:rule?.rate!=null?String(rule.rate):'10',fixed:rule?.fixed_amount!=null?String(rule.fixed_amount):'',from:String(rule?.effective_from ?? nairobiDate()),to:rule?.effective_to?String(rule.effective_to):'',active:rule?!!rule.active:true,notes:String(rule?.notes ?? '')});
 const [tierRows,setTierRows] = useState<TierDraft[]>(ruleTiers.length?ruleTiers.map(item=>({min:String(item.min_amount),max:item.max_amount==null?'':String(item.max_amount),rate:String(item.rate)})):[{min:'0',max:'',rate:'5'}]);
 const [key] = useState(()=>crypto.randomUUID()); const [localError,setLocalError] = useState<unknown>(); const [working,setWorking] = useState(false);
 async function save(){setLocalError(undefined);setWorking(true);
  try{
   if(!value.name.trim())throw new Error('invalid');
   if(value.method==='percentage'&&(Number(value.rate)<0||Number(value.rate)>100))throw new Error('invalid');
   if(value.method==='fixed'&&Number(value.fixed)<=0)throw new Error('invalid');
   if(value.method==='tiered'){if(!tierRows.length)throw new Error('tiersRequired');if(Number(tierRows[0].min)!==0)throw new Error('firstTierRequired');if(tierRows.some(item=>Number(item.rate)<0||Number(item.rate)>100||Number(item.min)<0||(item.max!==''&&Number(item.max)<=Number(item.min))))throw new Error('invalidTier');}
   await rpc('save_commission_rule',{p_key:key,p_id:rule?.id ?? null,p_name:value.name.trim(),p_basis:value.basis,p_method:value.method,p_rate:value.method==='percentage'?Number(value.rate):null,p_fixed:value.method==='fixed'?Number(value.fixed):null,p_from:value.from,p_to:value.to||null,p_active:value.active,p_tiers:value.method==='tiered'?tierRows.map(item=>({min:Number(item.min),max:item.max===''?null:Number(item.max),rate:Number(item.rate)})):[],p_notes:value.notes.trim()});
   await onSaved('commissionRuleSaved');
  }catch(next){setLocalError(next);}finally{setWorking(false);}
 }
 return <Dialog title={rule?t('editCommissionRule'):t('newCommissionRule')} onClose={onClose}>
  <form className="field-form" noValidate onSubmit={event=>{event.preventDefault();void save();}}>
   <Field label="ruleName"><input required maxLength={120} value={value.name} onChange={event=>setValue({...value,name:event.target.value})}/></Field>
   <div className="field-form-grid"><Field label="basisLabel"><select value={value.basis} onChange={event=>setValue({...value,basis:event.target.value})}><option value="gross">{t('grossSales')}</option><option value="net">{t('netSales')}</option><option value="paid">{t('paidSales')}</option><option value="delivered">{t('deliveredSales')}</option></select></Field><Field label="methodLabel"><select value={value.method} onChange={event=>setValue({...value,method:event.target.value})}><option value="percentage">{t('percentage')}</option><option value="fixed">{t('fixedAmount')}</option><option value="tiered">{t('tiered')}</option></select></Field>
    {value.method==='percentage'&&<Field label="ratePercent"><input type="number" min="0" max="100" step="0.001" value={value.rate} onChange={event=>setValue({...value,rate:event.target.value})}/></Field>}
    {value.method==='fixed'&&<Field label="fixedAmount"><input type="number" min="0.01" step="0.01" value={value.fixed} onChange={event=>setValue({...value,fixed:event.target.value})}/></Field>}
    <Field label="effectiveFrom"><input required type="date" value={value.from} onChange={event=>setValue({...value,from:event.target.value})}/></Field><Field label="effectiveTo"><input type="date" min={value.from} value={value.to} onChange={event=>setValue({...value,to:event.target.value})}/></Field></div>
   {tiered(value.method)&&<section className="people-tiers"><header><h3>{t('tiers')}</h3><button type="button" className="text-button" onClick={()=>setTierRows(previous=>[...previous,{min:'',max:'',rate:''}])}><Plus size={15}/>{t('addTier')}</button></header>{tierRows.map((tier,index)=><div className="people-tier" key={index}><Field label="minAmount"><input type="number" min="0" step="0.01" value={tier.min} onChange={event=>setTierRows(previous=>previous.map((item,position)=>position===index?{...item,min:event.target.value}:item))}/></Field><Field label="maxAmount"><input type="number" min="0" step="0.01" value={tier.max} onChange={event=>setTierRows(previous=>previous.map((item,position)=>position===index?{...item,max:event.target.value}:item))}/></Field><Field label="ratePercent"><input type="number" min="0" max="100" step="0.001" value={tier.rate} onChange={event=>setTierRows(previous=>previous.map((item,position)=>position===index?{...item,rate:event.target.value}:item))}/></Field>{tierRows.length>1&&<button type="button" className="icon-button" aria-label={t('remove')} onClick={()=>setTierRows(previous=>previous.filter((_,position)=>position!==index))}><Trash2 size={16}/></button>}</div>)}</section>}
   <label className="check-field"><input type="checkbox" checked={value.active} onChange={event=>setValue({...value,active:event.target.checked})}/>{t('ruleActive')}</label>
   <Field label="notes"><textarea maxLength={2000} value={value.notes} onChange={event=>setValue({...value,notes:event.target.value})}/></Field>
   <p className="field-note">{t('commissionRuleHint')}</p>
   {!!localError&&<ErrorNotice error={localError}/>}{!!error&&<ErrorNotice error={error}/>}
   <div className="dialog-actions"><button type="button" onClick={onClose}>{t('cancel')}</button><button className="primary" disabled={working||busy}>{t(working||busy?'saving':'save')}</button></div>
  </form>
 </Dialog>;
}

function CommissionDecision({entry,status,onClose,onSaved,busy,error}:{entry:Row;status:string;onClose:()=>void;onSaved:(message:string)=>Promise<void>;busy:boolean;error:unknown}) {
 const {t} = usePreferences(); const [value,setValue] = useState(status==='adjusted'?String(entry.commission ?? ''):''); const [reason,setReason] = useState(''); const [localError,setLocalError] = useState<unknown>(); const [working,setWorking] = useState(false);
 const amountStatus = status === 'adjusted';
 async function submit(){setLocalError(undefined);if(reason.trim().length<3){setLocalError(new Error('reasonRequired'));return;}if(amountStatus&&Number(value)<0){setLocalError(new Error('invalid'));return;}setWorking(true);try{await rpc('commission_decide',{p_entry:entry.id,p_status:status,p_amount:amountStatus?Number(value):null,p_reason:reason.trim()});await onSaved(status==='adjusted'?'commissionAdjusted':'commissionReversed');}catch(next){setLocalError(next);}finally{setWorking(false);}}
 return <Dialog title={`${t(amountStatus?'adjustCommission':'reverseCommission')} · #${entry.order_id}`} onClose={onClose}>
  <form className="field-form" noValidate onSubmit={event=>{event.preventDefault();void submit();}}>
   <p className="field-note">{entry.name} · {formatMoney(entry.commission,'en')}</p>
   {amountStatus&&<Field label="adjustmentAmount"><input required type="number" min="0" step="0.01" value={value} onChange={event=>setValue(event.target.value)}/></Field>}
   <Field label="reversalReason"><textarea required minLength={3} maxLength={1000} value={reason} onChange={event=>setReason(event.target.value)}/></Field>
   {!!localError&&<ErrorNotice error={localError}/>}{!!error&&<ErrorNotice error={error}/>}
   <div className="dialog-actions"><button type="button" onClick={onClose}>{t('cancel')}</button><button className="primary" disabled={working||busy}>{t(working||busy?'saving':amountStatus?'adjustCommission':'reverseCommission')}</button></div>
  </form>
 </Dialog>;
}

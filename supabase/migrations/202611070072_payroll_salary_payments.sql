begin;

create table charm.payroll_slips(
 id bigserial primary key,
 employee_id bigint not null references charm.users(id),
 period date not null check(extract(day from period)=1),
 basic_salary numeric(14,2) not null check(basic_salary>=0),
 allowances numeric(14,2) not null default 0 check(allowances>=0),
 deductions numeric(14,2) not null default 0 check(deductions>=0),
 net_pay numeric(14,2) generated always as (basic_salary+allowances-deductions) stored check(net_pay>0),
 status text not null default 'pending' check(status in ('pending','paid')),
 created_by bigint not null references charm.users(id),
 created_at timestamptz not null default now(),
 paid_by bigint references charm.users(id),
 paid_on date,
 account_id bigint references charm.finance_accounts(id),
 payment_reference text,
 payment_ledger_id bigint unique references charm.finance_ledger(id),
 unique(employee_id,period),
 check((status='pending' and paid_by is null and paid_on is null and account_id is null and payment_reference is null and payment_ledger_id is null)
    or (status='paid' and paid_by is not null and paid_on is not null and account_id is not null and payment_reference is not null and payment_ledger_id is not null))
);

create or replace function charm.payroll_protect_slip() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' or old.status='paid' then raise exception 'financeImmutable';end if;
 return new;
end$$;
create trigger payroll_slip_immutable before update or delete on charm.payroll_slips for each row execute function charm.payroll_protect_slip();

alter table charm.payroll_slips enable row level security;
revoke all on charm.payroll_slips from public,anon,authenticated;
grant select on charm.payroll_slips to authenticated;
create policy payroll_slips_reader on charm.payroll_slips for select to authenticated using(charm.finance_reader());
grant usage,select on sequence charm.payroll_slips_id_seq to authenticated;

create or replace function charm.payroll_employees() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform charm.require_finance();
 return coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',u.name,'staff_code',u.staff_code,'department',coalesce(u.territory,''),'active',u.active,'salary_amount',coalesce(p.basic_salary,0)::text,'salary_allowances',coalesce(p.allowances,0)::text,'salary_deductions',coalesce(p.deductions,0)::text) order by u.name)
  from charm.users u left join lateral(select basic_salary,allowances,deductions from charm.payroll_slips where employee_id=u.id order by period desc limit 1)p on true where u.active),'[]'::jsonb);
end$$;

create or replace function charm.payroll_slips(p_period date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform charm.require_finance();if p_period is null or extract(day from p_period)<>1 then raise exception 'invalid';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'employee_id',s.employee_id,'employee_name',u.name,'staff_code',u.staff_code,'department',coalesce(u.territory,''),'period',s.period,'basic_salary',s.basic_salary::text,'allowances',s.allowances::text,'deductions',s.deductions::text,'net_pay',s.net_pay::text,'status',s.status,'created_by',s.created_by,'created_at',s.created_at,'paid_by',s.paid_by,'paid_on',s.paid_on,'account_id',s.account_id,'account_name',acc.name,'payment_reference',s.payment_reference) order by u.name)
 from charm.payroll_slips s join charm.users u on u.id=s.employee_id left join charm.finance_accounts acc on acc.id=s.account_id where s.period=p_period),'[]'::jsonb);
end$$;

create or replace function charm.payroll_save(p_key uuid,p_id bigint,p_employee bigint,p_period date,p_basic text,p_allowances text,p_deductions text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;basic numeric;allowance numeric;deduct numeric;id bigint;
begin
 perform charm.require_finance();old:=charm.claim(p_key,'payroll_save',jsonb_build_array(p_id,p_employee,p_period,p_basic,p_allowances,p_deductions));if old is not null then return old;end if;
 if p_employee is null or p_period is null or extract(day from p_period)<>1 or p_basic !~ '^[0-9]{1,10}([.][0-9]{1,2})?$' or coalesce(p_allowances,'0') !~ '^[0-9]{1,10}([.][0-9]{1,2})?$' or coalesce(p_deductions,'0') !~ '^[0-9]{1,10}([.][0-9]{1,2})?$' then raise exception 'invalidMoney';end if;
 basic:=p_basic::numeric;allowance:=coalesce(p_allowances,'0')::numeric;deduct:=coalesce(p_deductions,'0')::numeric;
 if basic<=0 or allowance<0 or deduct<0 or basic+allowance<=deduct or not exists(select 1 from charm.users where id=p_employee and active) then raise exception 'invalid';end if;
 if p_id is null then
  begin
   insert into charm.payroll_slips(employee_id,period,basic_salary,allowances,deductions,created_by) values(p_employee,p_period,basic,allowance,deduct,a) returning payroll_slips.id into id;
  exception when unique_violation then raise exception 'payrollExists';
  end;
 else
  update charm.payroll_slips set basic_salary=basic,allowances=allowance,deductions=deduct where payroll_slips.id=p_id and status='pending' returning payroll_slips.id into id;
  if id is null then raise exception 'financeLocked';end if;
 end if;
 perform charm.audit('payrollPrepared','payroll_slips',id,jsonb_build_object('employee_id',p_employee,'period',p_period,'net_pay',basic+allowance-deduct));return charm.finish(p_key,id);
end$$;

create or replace function charm.payroll_mark_paid(p_key uuid,p_id bigint,p_account bigint,p_reference text,p_paid_on date) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;s charm.payroll_slips;balance numeric;ledger_id bigint;employee_name text;
begin
 perform charm.require_finance();old:=charm.claim(p_key,'payroll_mark_paid',jsonb_build_array(p_id,p_account,p_reference,p_paid_on));if old is not null then return old;end if;
 select * into s from charm.payroll_slips where id=p_id for update;
 if s.id is null or s.status<>'pending' or p_paid_on is null or p_paid_on>(now() at time zone 'Africa/Nairobi')::date or coalesce(length(trim(p_reference)),0) not between 1 and 200 then raise exception 'invalid';end if;
 select name into employee_name from charm.users where id=s.employee_id;
 perform 1 from charm.finance_accounts where id=p_account and active for update;if not found then raise exception 'invalid';end if;
 select coalesce(sum(case when direction='in' then amount else -amount end),0) into balance from charm.finance_cashbook where account_id=p_account;
 if balance<s.net_pay then raise exception 'insufficientFunds';end if;
 insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by) values(p_account,'out',s.net_pay,'expense','Payroll '||s.period::text||' · '||employee_name||' · '||trim(p_reference),p_paid_on::timestamp at time zone 'Africa/Nairobi',a) returning id into ledger_id;
 update charm.payroll_slips set status='paid',paid_by=a,paid_on=p_paid_on,account_id=p_account,payment_reference=trim(p_reference),payment_ledger_id=ledger_id where id=p_id;
 perform charm.audit('payrollPaid','payroll_slips',p_id,jsonb_build_object('employee_id',s.employee_id,'period',s.period,'net_pay',s.net_pay,'account_id',p_account,'reference',p_reference,'ledger_id',ledger_id));
 return charm.finish(p_key,ledger_id);
end$$;

revoke execute on function charm.payroll_employees(),charm.payroll_slips(date),charm.payroll_save(uuid,bigint,bigint,date,text,text,text),charm.payroll_mark_paid(uuid,bigint,bigint,text,date),charm.payroll_protect_slip() from public,anon;
grant execute on function charm.payroll_employees(),charm.payroll_slips(date),charm.payroll_save(uuid,bigint,bigint,date,text,text,text),charm.payroll_mark_paid(uuid,bigint,bigint,text,date) to authenticated;
notify pgrst,'reload schema';
commit;

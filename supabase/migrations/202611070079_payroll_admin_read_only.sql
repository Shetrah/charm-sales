begin;

-- Admins may inspect payroll records but only Finance Officers may create or
-- modify employee, salary, or payment entries.
create or replace function charm.payroll_employees() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not charm.finance_reader() then raise exception 'forbidden';end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'id',e.id,'name',e.full_name,'staff_code',e.employee_number,'department',e.department,'position',e.position,
  'email',e.email,'phone',e.phone,'national_id',e.national_id,'employment_type',e.employment_type,
  'active',e.status='active','status',e.status,'hire_date',e.hire_date,
  'salary_amount',e.basic_salary::text,'salary_allowances',e.allowances::text,'salary_deductions',e.deductions::text,
  'kra_pin',e.kra_pin,'nssf_number',e.nssf_number,'sha_number',e.sha_number,'bank_name',e.bank_name,
  'bank_account',e.bank_account,'notes',e.notes) order by lower(e.full_name))
  from charm.payroll_employees e),'[]'::jsonb);
end$$;

create or replace function charm.payroll_slips(p_period date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not charm.finance_reader() then raise exception 'forbidden';end if;
 if p_period is null or extract(day from p_period)<>1 then raise exception 'invalid';end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'id',s.id,'employee_id',s.employee_id,'employee_name',e.full_name,'staff_code',e.employee_number,
  'department',e.department,'period',s.period,'basic_salary',s.basic_salary::text,
  'allowances',s.allowances::text,'deductions',s.deductions::text,'net_pay',s.net_pay::text,
  'status',s.status,'created_by',s.created_by,'created_at',s.created_at,'paid_by',s.paid_by,
  'paid_on',s.paid_on,'account_id',s.account_id,'account_name',acc.name,
  'payment_reference',s.payment_reference) order by lower(e.full_name))
  from charm.payroll_slips s
  join charm.payroll_employees e on e.id=s.employee_id
  left join charm.finance_accounts acc on acc.id=s.account_id
  where s.period=p_period),'[]'::jsonb);
end$$;

create or replace function charm.payroll_payment_history(p_month date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not charm.finance_reader() then raise exception 'forbidden';end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'invalid';end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'id',s.id,'employee_id',s.employee_id,'employee_name',e.full_name,'staff_code',e.employee_number,
  'department',e.department,'period',s.period,'basic_salary',s.basic_salary::text,
  'allowances',s.allowances::text,'deductions',s.deductions::text,'net_pay',s.net_pay::text,
  'status',s.status,'created_by',s.created_by,'created_at',s.created_at,'paid_by',s.paid_by,
  'paid_on',s.paid_on,'account_id',s.account_id,'account_name',acc.name,
  'payment_reference',s.payment_reference) order by s.paid_on desc,lower(e.full_name))
  from charm.payroll_slips s
  join charm.payroll_employees e on e.id=s.employee_id
  left join charm.finance_accounts acc on acc.id=s.account_id
  where s.status='paid' and s.paid_on>=p_month and s.paid_on<(p_month+interval '1 month')::date),'[]'::jsonb);
end$$;

create or replace function charm.payroll_employee_save(p_key uuid,p_id bigint,p_data jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;id bigint;basic numeric;allowance numeric;deduct numeric;name_value text:=trim(coalesce(p_data->>'name',''));department_value text:=trim(coalesce(p_data->>'department',''));
begin
 if charm.finance_role() is distinct from 'finance_officer' then raise exception 'forbidden';end if;
 perform charm.require_finance();
 old:=charm.claim(p_key,'payroll_employee_save',jsonb_build_array(p_id,p_data));if old is not null then return old;end if;
 if length(name_value) not between 1 and 200 or length(department_value) not between 1 and 200
  or length(coalesce(p_data->>'employee_number',''))>80 or length(coalesce(p_data->>'position',''))>120
  or length(coalesce(p_data->>'email',''))>200 or length(coalesce(p_data->>'phone',''))>40
  or length(coalesce(p_data->>'national_id',''))>80 or length(coalesce(p_data->>'employment_type','permanent'))>40
  or coalesce(p_data->>'status','active') not in ('active','inactive','suspended')
  or coalesce(p_data->>'employment_type','permanent') not in ('permanent','contract','casual','intern','part_time')
  or coalesce(p_data->>'basic_salary','') !~ '^[0-9]{1,10}([.][0-9]{1,2})?$'
  or coalesce(p_data->>'allowances','0') !~ '^[0-9]{1,10}([.][0-9]{1,2})?$'
  or coalesce(p_data->>'deductions','0') !~ '^[0-9]{1,10}([.][0-9]{1,2})?$'
  or length(coalesce(p_data->>'kra_pin',''))>40 or length(coalesce(p_data->>'nssf_number',''))>60
  or length(coalesce(p_data->>'sha_number',''))>60 or length(coalesce(p_data->>'bank_name',''))>120
  or length(coalesce(p_data->>'bank_account',''))>120 or length(coalesce(p_data->>'notes',''))>2000 then raise exception 'invalid';end if;
 basic:=(p_data->>'basic_salary')::numeric;allowance:=coalesce(p_data->>'allowances','0')::numeric;deduct:=coalesce(p_data->>'deductions','0')::numeric;
 if basic<=0 or allowance<0 or deduct<0 or basic+allowance<=deduct then raise exception 'invalidMoney';end if;
 if p_id is null then
  insert into charm.payroll_employees(employee_number,full_name,department,position,email,phone,national_id,employment_type,status,hire_date,basic_salary,allowances,deductions,kra_pin,nssf_number,sha_number,bank_name,bank_account,notes,created_by,updated_by)
  values(nullif(trim(p_data->>'employee_number'),''),name_value,department_value,coalesce(p_data->>'position',''),coalesce(p_data->>'email',''),coalesce(p_data->>'phone',''),coalesce(p_data->>'national_id',''),coalesce(p_data->>'employment_type','permanent'),coalesce(p_data->>'status','active'),nullif(p_data->>'hire_date','')::date,basic,allowance,deduct,coalesce(p_data->>'kra_pin',''),coalesce(p_data->>'nssf_number',''),coalesce(p_data->>'sha_number',''),coalesce(p_data->>'bank_name',''),coalesce(p_data->>'bank_account',''),coalesce(p_data->>'notes',''),a,a) returning payroll_employees.id into id;
 else
  update charm.payroll_employees set employee_number=nullif(trim(p_data->>'employee_number'),''),full_name=name_value,department=department_value,position=coalesce(p_data->>'position',''),email=coalesce(p_data->>'email',''),phone=coalesce(p_data->>'phone',''),national_id=coalesce(p_data->>'national_id',''),employment_type=coalesce(p_data->>'employment_type','permanent'),status=coalesce(p_data->>'status','active'),hire_date=nullif(p_data->>'hire_date','')::date,basic_salary=basic,allowances=allowance,deductions=deduct,kra_pin=coalesce(p_data->>'kra_pin',''),nssf_number=coalesce(p_data->>'nssf_number',''),sha_number=coalesce(p_data->>'sha_number',''),bank_name=coalesce(p_data->>'bank_name',''),bank_account=coalesce(p_data->>'bank_account',''),notes=coalesce(p_data->>'notes',''),updated_by=a,updated_at=now()
  where payroll_employees.id=p_id returning payroll_employees.id into id;
  if id is null then raise exception 'financeLocked';end if;
 end if;
 perform charm.audit(case when p_id is null then 'payrollEmployeeAdded' else 'payrollEmployeeUpdated' end,'payroll_employees',id,jsonb_build_object('name',name_value,'department',department_value,'status',coalesce(p_data->>'status','active')));
 return charm.finish(p_key,id);
exception when unique_violation then raise exception 'payrollEmployeeNumberExists';
end$$;

create or replace function charm.payroll_save(p_key uuid,p_id bigint,p_employee bigint,p_period date,p_basic text,p_allowances text,p_deductions text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;basic numeric;allowance numeric;deduct numeric;id bigint;
begin
 if charm.finance_role() is distinct from 'finance_officer' then raise exception 'forbidden';end if;
 perform charm.require_finance();
 old:=charm.claim(p_key,'payroll_save',jsonb_build_array(p_id,p_employee,p_period,p_basic,p_allowances,p_deductions));if old is not null then return old;end if;
 if p_employee is null or p_period is null or extract(day from p_period)<>1 or p_basic !~ '^[0-9]{1,10}([.][0-9]{1,2})?$' or coalesce(p_allowances,'0') !~ '^[0-9]{1,10}([.][0-9]{1,2})?$' or coalesce(p_deductions,'0') !~ '^[0-9]{1,10}([.][0-9]{1,2})?$' then raise exception 'invalidMoney';end if;
 basic:=p_basic::numeric;allowance:=coalesce(p_allowances,'0')::numeric;deduct:=coalesce(p_deductions,'0')::numeric;
 if basic<=0 or allowance<0 or deduct<0 or basic+allowance<=deduct or not exists(select 1 from charm.payroll_employees where id=p_employee and status='active') then raise exception 'invalid';end if;
 if p_id is null then
  begin insert into charm.payroll_slips(employee_id,period,basic_salary,allowances,deductions,created_by) values(p_employee,p_period,basic,allowance,deduct,a) returning payroll_slips.id into id;
  exception when unique_violation then raise exception 'payrollExists';end;
 else
  update charm.payroll_slips set basic_salary=basic,allowances=allowance,deductions=deduct where payroll_slips.id=p_id and status='pending' returning payroll_slips.id into id;
  if id is null then raise exception 'financeLocked';end if;
 end if;
 perform charm.audit('payrollPrepared','payroll_slips',id,jsonb_build_object('employee_id',p_employee,'period',p_period,'net_pay',basic+allowance-deduct));return charm.finish(p_key,id);
end$$;

create or replace function charm.payroll_mark_paid(p_key uuid,p_id bigint,p_account bigint,p_reference text,p_paid_on date) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;s charm.payroll_slips;balance numeric;ledger_id bigint;employee_name text;
begin
 if charm.finance_role() is distinct from 'finance_officer' then raise exception 'forbidden';end if;
 perform charm.require_finance();
 old:=charm.claim(p_key,'payroll_mark_paid',jsonb_build_array(p_id,p_account,p_reference,p_paid_on));if old is not null then return old;end if;
 select * into s from charm.payroll_slips where id=p_id for update;
 if s.id is null or s.status<>'pending' or p_paid_on is null or p_paid_on>(now() at time zone 'Africa/Nairobi')::date or coalesce(length(trim(p_reference)),0) not between 1 and 200 then raise exception 'invalid';end if;
 select full_name into employee_name from charm.payroll_employees where id=s.employee_id;
 perform 1 from charm.finance_accounts where id=p_account and active for update;if not found then raise exception 'invalid';end if;
 select coalesce(sum(case when direction='in' then amount else -amount end),0) into balance from charm.finance_cashbook where account_id=p_account;
 if balance<s.net_pay then raise exception 'insufficientFunds';end if;
 insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by) values(p_account,'out',s.net_pay,'expense','Payroll '||s.period::text||' · '||employee_name||' · '||trim(p_reference),p_paid_on::timestamp at time zone 'Africa/Nairobi',a) returning id into ledger_id;
 update charm.payroll_slips set status='paid',paid_by=a,paid_on=p_paid_on,account_id=p_account,payment_reference=trim(p_reference),payment_ledger_id=ledger_id where id=p_id;
 perform charm.audit('payrollPaid','payroll_slips',p_id,jsonb_build_object('employee_id',s.employee_id,'period',s.period,'net_pay',s.net_pay,'account_id',p_account,'reference',p_reference,'ledger_id',ledger_id));
 return charm.finish(p_key,ledger_id);
end$$;

revoke execute on function charm.payroll_employees(),charm.payroll_slips(date),charm.payroll_payment_history(date),charm.payroll_employee_save(uuid,bigint,jsonb),charm.payroll_save(uuid,bigint,bigint,date,text,text,text),charm.payroll_mark_paid(uuid,bigint,bigint,text,date) from public,anon;
grant execute on function charm.payroll_employees(),charm.payroll_slips(date),charm.payroll_payment_history(date),charm.payroll_employee_save(uuid,bigint,jsonb),charm.payroll_save(uuid,bigint,bigint,date,text,text,text),charm.payroll_mark_paid(uuid,bigint,bigint,text,date) to authenticated;
notify pgrst,'reload schema';
commit;
begin;

-- Payroll is a company employee register, separate from login accounts in
-- charm.users. Preserve only employees already referenced by existing slips.
create table charm.payroll_employees(
 id bigserial primary key,
 source_user_id bigint unique references charm.users(id),
 employee_number text,
 full_name text not null check(length(trim(full_name)) between 1 and 200),
 department text not null check(length(trim(department)) between 1 and 200),
 position text not null default '',
 email text not null default '',
 phone text not null default '',
 national_id text not null default '',
 employment_type text not null default 'permanent' check(employment_type in ('permanent','contract','casual','intern','part_time')),
 status text not null default 'active' check(status in ('active','inactive','suspended')),
 hire_date date,
 basic_salary numeric(14,2) not null default 0 check(basic_salary>=0),
 allowances numeric(14,2) not null default 0 check(allowances>=0),
 deductions numeric(14,2) not null default 0 check(deductions>=0),
 kra_pin text not null default '',
 nssf_number text not null default '',
 sha_number text not null default '',
 bank_name text not null default '',
 bank_account text not null default '',
 notes text not null default '',
 created_by bigint not null references charm.users(id),
 created_at timestamptz not null default now(),
 updated_by bigint not null references charm.users(id),
 updated_at timestamptz not null default now()
);
create unique index payroll_employees_number_unique on charm.payroll_employees(lower(trim(employee_number))) where employee_number is not null and trim(employee_number)<>'';
create index payroll_employees_status_name on charm.payroll_employees(status,lower(full_name));

-- Keep existing payroll history, but do not import unrelated system users.
insert into charm.payroll_employees(source_user_id,employee_number,full_name,department,status,basic_salary,allowances,deductions,created_by,updated_by)
select distinct on (u.id) u.id,
 case when u.staff_code is not null and (select count(*) from charm.users u2 where lower(trim(u2.staff_code))=lower(trim(u.staff_code)))=1 then u.staff_code else null end,
 u.name,coalesce(nullif(trim(u.territory),''),'Unassigned'),
 case when u.active then 'active' else 'inactive' end,
 coalesce(s.basic_salary,0),coalesce(s.allowances,0),coalesce(s.deductions,0),s.created_by,s.created_by
from charm.payroll_slips s join charm.users u on u.id=s.employee_id
order by u.id,s.period desc;

alter table charm.payroll_slips drop constraint if exists payroll_slips_employee_id_fkey;
update charm.payroll_slips s set employee_id=e.id
from charm.payroll_employees e where e.source_user_id=s.employee_id;
alter table charm.payroll_slips add constraint payroll_slips_employee_id_fkey foreign key(employee_id) references charm.payroll_employees(id);

alter table charm.payroll_employees enable row level security;
revoke all on charm.payroll_employees from public,anon,authenticated;
grant select on charm.payroll_employees to authenticated;
create policy payroll_employees_reader on charm.payroll_employees for select to authenticated using(charm.finance_reader());
grant usage,select on sequence charm.payroll_employees_id_seq to authenticated;

create or replace function charm.payroll_employees() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform charm.require_finance();
 return coalesce((select jsonb_agg(jsonb_build_object(
  'id',e.id,'name',e.full_name,'staff_code',e.employee_number,'department',e.department,'position',e.position,
  'email',e.email,'phone',e.phone,'national_id',e.national_id,'employment_type',e.employment_type,
  'active',e.status='active','status',e.status,'hire_date',e.hire_date,
  'salary_amount',e.basic_salary::text,'salary_allowances',e.allowances::text,'salary_deductions',e.deductions::text,
  'kra_pin',e.kra_pin,'nssf_number',e.nssf_number,'sha_number',e.sha_number,'bank_name',e.bank_name,
  'bank_account',e.bank_account,'notes',e.notes) order by lower(e.full_name))
  from charm.payroll_employees e),'[]'::jsonb);
end$$;

create or replace function charm.payroll_employee_save(p_key uuid,p_id bigint,p_data jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;id bigint;basic numeric;allowance numeric;deduct numeric;name_value text:=trim(coalesce(p_data->>'name',''));department_value text:=trim(coalesce(p_data->>'department',''));
begin
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

create or replace function charm.payroll_slips(p_period date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform charm.require_finance();if p_period is null or extract(day from p_period)<>1 then raise exception 'invalid';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'employee_id',s.employee_id,'employee_name',e.full_name,'staff_code',e.employee_number,'department',e.department,'period',s.period,'basic_salary',s.basic_salary::text,'allowances',s.allowances::text,'deductions',s.deductions::text,'net_pay',s.net_pay::text,'status',s.status,'created_by',s.created_by,'created_at',s.created_at,'paid_by',s.paid_by,'paid_on',s.paid_on,'account_id',s.account_id,'account_name',acc.name,'payment_reference',s.payment_reference) order by lower(e.full_name))
 from charm.payroll_slips s join charm.payroll_employees e on e.id=s.employee_id left join charm.finance_accounts acc on acc.id=s.account_id where s.period=p_period),'[]'::jsonb);
end$$;

create or replace function charm.payroll_save(p_key uuid,p_id bigint,p_employee bigint,p_period date,p_basic text,p_allowances text,p_deductions text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;basic numeric;allowance numeric;deduct numeric;id bigint;
begin
 perform charm.require_finance();old:=charm.claim(p_key,'payroll_save',jsonb_build_array(p_id,p_employee,p_period,p_basic,p_allowances,p_deductions));if old is not null then return old;end if;
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

revoke execute on function charm.payroll_employees(),charm.payroll_employee_save(uuid,bigint,jsonb),charm.payroll_slips(date),charm.payroll_save(uuid,bigint,bigint,date,text,text,text) from public,anon;
grant execute on function charm.payroll_employees(),charm.payroll_employee_save(uuid,bigint,jsonb),charm.payroll_slips(date),charm.payroll_save(uuid,bigint,bigint,date,text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;

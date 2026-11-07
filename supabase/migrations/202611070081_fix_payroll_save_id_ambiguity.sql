begin;

-- Qualify the employee id in the active employee lookup. The unqualified id
-- collided with the PL/pgSQL saved slip variable and made every save fail.
create or replace function charm.payroll_save(
 p_key uuid,p_id bigint,p_employee bigint,p_period date,p_basic text,p_allowances text,p_deductions text
) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;basic numeric;allowance numeric;deduct numeric;saved_id bigint;
begin
 if charm.finance_role() is distinct from 'finance_officer' then raise exception 'forbidden';end if;
 perform charm.require_finance();
 old:=charm.claim(p_key,'payroll_save',jsonb_build_array(p_id,p_employee,p_period,p_basic,p_allowances,p_deductions));
 if old is not null then return old;end if;
 if p_employee is null or p_period is null or extract(day from p_period)<>1
  or p_basic !~ '^[0-9]{1,10}([.][0-9]{1,2})?$'
  or coalesce(p_allowances,'0') !~ '^[0-9]{1,10}([.][0-9]{1,2})?$'
  or coalesce(p_deductions,'0') !~ '^[0-9]{1,10}([.][0-9]{1,2})?$' then raise exception 'invalidMoney';end if;
 basic:=p_basic::numeric;allowance:=coalesce(p_allowances,'0')::numeric;deduct:=coalesce(p_deductions,'0')::numeric;
 if basic<=0 or allowance<0 or deduct<0 or basic+allowance<=deduct
  or not exists(select 1 from charm.payroll_employees pe where pe.id=p_employee and pe.status='active') then raise exception 'invalid';end if;
 if p_id is null then
  begin
   insert into charm.payroll_slips(employee_id,period,basic_salary,allowances,deductions,created_by)
   values(p_employee,p_period,basic,allowance,deduct,a) returning payroll_slips.id into saved_id;
  exception when unique_violation then raise exception 'payrollExists';
  end;
 else
  update charm.payroll_slips as ps set basic_salary=basic,allowances=allowance,deductions=deduct
  where ps.id=p_id and ps.status='pending' returning ps.id into saved_id;
  if saved_id is null then raise exception 'financeLocked';end if;
 end if;
 perform charm.audit('payrollPrepared','payroll_slips',saved_id,
  jsonb_build_object('employee_id',p_employee,'period',p_period,'net_pay',basic+allowance-deduct));
 return charm.finish(p_key,saved_id);
end$$;

revoke execute on function charm.payroll_save(uuid,bigint,bigint,date,text,text,text) from public,anon;
grant execute on function charm.payroll_save(uuid,bigint,bigint,date,text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;

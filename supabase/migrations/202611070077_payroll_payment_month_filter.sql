begin;

-- Filter salary payments by the month they were actually paid, independently
-- from the salary period recorded on the payslip.
create or replace function charm.payroll_payment_history(p_month date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform charm.require_finance();
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
revoke execute on function charm.payroll_payment_history(date) from public,anon;
grant execute on function charm.payroll_payment_history(date) to authenticated;
notify pgrst,'reload schema';
commit;
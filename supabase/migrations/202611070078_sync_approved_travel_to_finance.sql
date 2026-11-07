begin;

-- Every approved travel reimbursement is a Finance expense request. The
-- advance_required flag controls direct staff advances, not travel payouts.
create or replace function charm.travel_finance_request(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare e charm.expenses;cid bigint;day date;
begin
 select * into e from charm.expenses where expenses.id=p_id;
 if not found or e.status not in ('approved','in_progress','completed') or coalesce(e.total_estimated,0)<=0 then return;end if;
 select id into cid from charm.finance_categories where name='Travel' and active order by id limit 1;
 if cid is null then select id into cid from charm.finance_categories where active order by id limit 1;end if;
 if cid is null then raise exception 'financeCategoryMissing';end if;
 day:=coalesce((e.depart_at at time zone 'Africa/Nairobi')::date,(now() at time zone 'Africa/Nairobi')::date);
 insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,expense_on,recorded_by,source_type,source_id,status,source_expense_id,created_at,updated_at)
 values(e.salesperson_id,'expense',cid,e.total_estimated,coalesce(e.purpose,'Travel expense'),day,day+7,day,e.salesperson_id,'travel',e.id,'pending',e.id,now(),now())
 on conflict do nothing;
end$$;

-- Backfill prior admin-approved trips that were skipped when advance_required
-- was false. Do not rewrite existing finance requests or their audit history.
do $$
declare cid bigint;
begin
 select id into cid from charm.finance_categories where name='Travel' and active order by id limit 1;
 if cid is null then select id into cid from charm.finance_categories where active order by id limit 1;end if;
 if cid is null then raise exception 'financeCategoryMissing';end if;
 insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,expense_on,recorded_by,source_type,source_id,status,source_expense_id,created_at,updated_at)
 select e.salesperson_id,'expense',cid,e.total_estimated,coalesce(e.purpose,'Travel expense'),
  coalesce((e.depart_at at time zone 'Africa/Nairobi')::date,(now() at time zone 'Africa/Nairobi')::date),
  coalesce((e.depart_at at time zone 'Africa/Nairobi')::date,(now() at time zone 'Africa/Nairobi')::date)+7,
  coalesce((e.depart_at at time zone 'Africa/Nairobi')::date,(now() at time zone 'Africa/Nairobi')::date),
  e.salesperson_id,'travel',e.id,'pending',e.id,now(),now()
 from charm.expenses e
 where e.status in ('approved','in_progress','completed') and coalesce(e.total_estimated,0)>0
  and not exists(select 1 from charm.finance_requests r where r.source_expense_id=e.id or (r.source_type='travel' and r.source_id=e.id))
 on conflict do nothing;
end$$;

notify pgrst,'reload schema';
commit;
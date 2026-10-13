begin;
create or replace function charm.finance_bridge_expense() returns trigger language plpgsql security definer set search_path='' as $$declare id bigint;begin
 if new.budget>0 then
 insert into charm.finance_requests(owner_id,kind,category_id,amount,purpose,required_date,accountability_due,status,source_expense_id,created_at)
 values(new.salesperson_id,'staff',(select c.id from charm.finance_categories c where c.name='Other'),new.budget,new.notes,new.date,new.date+7,case when new.status='rejected' then 'rejected' else 'pending' end,new.id,coalesce(new.created_at,now())) on conflict(source_expense_id) do nothing returning finance_requests.id into id;
 if id is not null and new.status<>'rejected' then perform charm.finance_notify(id,'financeSubmitted','legacy-expense:'||new.id,array['admin']);end if;
 end if;return new;
end$$;
create function charm.finance_sync_expense_rejection() returns trigger language plpgsql security definer set search_path='' as $$declare id bigint;begin
 if new.status='rejected' and old.status='pending' then
 update charm.finance_requests set status='rejected',reason='Original travel request rejected',updated_at=now() where source_expense_id=new.id and status in ('draft','pending','returned') returning finance_requests.id into id;
 if id is not null then perform charm.finance_notify(id,'rejected','legacy-rejected:'||new.id);end if;
 end if;return new;
end$$;
create trigger finance_expense_rejection after update of status on charm.expenses for each row execute function charm.finance_sync_expense_rejection();
revoke execute on function charm.finance_bridge_expense(),charm.finance_sync_expense_rejection() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;

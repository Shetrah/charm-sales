-- Retiring a category or department must stay reversible, so the officer needs the whole list,
-- not only the active rows that finance_metadata hands to the pickers.
begin;

create or replace function charm.finance_expense_lists() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not charm.finance_operator() then raise exception 'forbidden';end if;
 return jsonb_build_object(
  'categories',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'active',active) order by name),'[]') from charm.finance_categories),
  'departments',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'active',active) order by name),'[]') from charm.finance_departments));
end$$;

revoke execute on function charm.finance_expense_lists() from public,anon;
grant execute on function charm.finance_expense_lists() to authenticated;
notify pgrst,'reload schema';
commit;

begin;
create function charm.finance_protect_request() returns trigger language plpgsql set search_path='' as $$begin
 if tg_op='DELETE' or old.status='closed' then raise exception 'financeImmutable';end if;
 if old.status in ('approved','part_paid','paid') and row(old.owner_id,old.kind,old.payee_id,old.category_id,old.amount,old.approved_amount,old.purpose,old.required_date,old.accountability_due,old.approved_by,old.approved_at,old.budget_id,old.source_expense_id) is distinct from row(new.owner_id,new.kind,new.payee_id,new.category_id,new.amount,new.approved_amount,new.purpose,new.required_date,new.accountability_due,new.approved_by,new.approved_at,new.budget_id,new.source_expense_id) then raise exception 'financeImmutable';end if;
 return new;
end$$;
create trigger finance_request_guard before update or delete on charm.finance_requests for each row execute function charm.finance_protect_request();
create function charm.finance_protect_accountability() returns trigger language plpgsql set search_path='' as $$begin
 if tg_op='DELETE' or old.status='accepted' then raise exception 'financeImmutable';end if;return new;
end$$;
create trigger finance_accountability_guard before update or delete on charm.finance_accountability for each row execute function charm.finance_protect_accountability();
revoke execute on function charm.finance_protect_request(),charm.finance_protect_accountability() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;

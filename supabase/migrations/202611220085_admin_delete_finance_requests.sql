begin;

create or replace function charm.finance_immutable() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='DELETE' and tg_table_name in ('finance_ledger','finance_receipt_allocations') and charm.finance_role()='admin'
   and current_setting('charm.admin_order_delete',true)='on' then return old; end if;
 if tg_op='DELETE' and tg_table_name='finance_ledger' and charm.finance_role()='admin'
   and current_setting('charm.admin_request_delete',true)='on' then return old; end if;
 raise exception 'financeImmutable';
end$$;

create function charm.admin_delete_finance_request(p_id bigint,p_prepare boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r charm.finance_requests; paths jsonb;
begin
 if charm.finance_role() is distinct from 'admin' then raise exception 'forbidden'; end if;
 select * into r from charm.finance_requests where id=p_id for update;
 if r.id is null then raise exception 'notFound'; end if;
 select coalesce(jsonb_agg(path),'[]'::jsonb) into paths from charm.finance_documents where request_id=p_id;
 if p_prepare then return paths; end if;

 perform set_config('charm.admin_request_delete','on',true);
 update charm.finance_statement_lines set ledger_id=null,matched_by=null,matched_at=null
  where ledger_id in(select id from charm.finance_ledger where request_id=p_id);
 delete from charm.finance_ledger where request_id=p_id;
 delete from charm.finance_accountability where request_id=p_id;
 delete from charm.finance_disbursements where request_id=p_id;
 delete from charm.finance_notifications where request_id=p_id;
 delete from charm.finance_expense_items where request_id=p_id;
 delete from charm.finance_operating_entries where request_id=p_id;
 delete from charm.audit_logs where (entity='finance_requests' and entity_id=p_id)
  or (r.source_expense_id is not null and entity='expenses' and entity_id=r.source_expense_id);
 delete from charm.finance_documents where request_id=p_id;
 delete from charm.finance_requests where id=p_id;
 if r.source_expense_id is not null then delete from charm.expenses where id=r.source_expense_id; end if;
 perform set_config('charm.admin_request_delete','off',true);
 perform charm.audit('financeRequestPermanentlyDeleted','finance_request_deletions',p_id,jsonb_build_object('kind',r.kind,'status',r.status,'documents_removed',jsonb_array_length(paths),'source_expense_id',r.source_expense_id));
 return paths;
end$$;

revoke execute on function charm.admin_delete_finance_request(bigint,boolean) from public,anon;
grant execute on function charm.admin_delete_finance_request(bigint,boolean) to authenticated;
notify pgrst,'reload schema';
commit;

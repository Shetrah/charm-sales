begin;
create table if not exists charm.finance_receipt_allocations(payment_id bigint primary key references charm.payments(id),ledger_id bigint unique not null references charm.finance_ledger(id),account_id bigint not null references charm.finance_accounts(id),reference text not null,confirmed_by bigint not null references charm.users(id),confirmed_at timestamptz not null default now(),unique(account_id,reference));
alter table charm.finance_receipt_allocations enable row level security;
revoke all on charm.finance_receipt_allocations from public,anon,authenticated;
grant select on charm.finance_receipt_allocations to authenticated;
drop policy if exists finance_allocation_read on charm.finance_receipt_allocations;
create policy finance_allocation_read on charm.finance_receipt_allocations for select to authenticated using(charm.finance_reader());
create unique index finance_one_opening on charm.finance_ledger(account_id) where kind='opening';
create function charm.finance_configure(p_key uuid,p_kind text,p_data jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();old bigint;id bigint;v numeric;used numeric;r record;previous jsonb;begin
 perform charm.require_finance(true);old:=charm.claim(p_key,'finance_configure',jsonb_build_array(p_kind,p_data));if old is not null then return old;end if;
 if p_kind='category' then
  if coalesce(length(trim(p_data->>'name')),0) not between 1 and 120 then raise exception 'invalid';end if;
  insert into charm.finance_categories(name) values(trim(p_data->>'name')) returning finance_categories.id into id;
 elsif p_kind='account' then
  if coalesce(length(trim(p_data->>'name')),0) not between 1 and 120 or coalesce(p_data->>'method','') not in ('Cash','Bank','M-Pesa','Other') then raise exception 'invalid';end if;
  insert into charm.finance_accounts(name,method) values(trim(p_data->>'name'),p_data->>'method') returning finance_accounts.id into id;
 elsif p_kind='opening' then
  v:=charm.finance_money(p_data->>'amount');
  if coalesce(p_data->>'confirmed','')<>'true' or coalesce(length(trim(p_data->>'reference')),0) not between 1 and 200 then raise exception 'paymentConfirmationRequired';end if;
  perform 1 from charm.finance_accounts where finance_accounts.id=(p_data->>'account_id')::bigint and active for update;if not found then raise exception 'invalid';end if;
  insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by) values((p_data->>'account_id')::bigint,'in',v,'opening',trim(p_data->>'reference'),now(),a) returning finance_ledger.id into id;
 elsif p_kind='payee' then
  if coalesce(length(trim(p_data->>'name')),0) not between 1 and 200 or coalesce(length(trim(p_data->>'details')),0) not between 1 and 2000 then raise exception 'invalid';end if;
  if p_data->>'staff_id' is not null and not exists(select 1 from charm.users where users.id=(p_data->>'staff_id')::bigint and active) then raise exception 'staffInactive';end if;
  select to_jsonb(p) into previous from charm.finance_payees p where staff_id=(p_data->>'staff_id')::bigint;
  insert into charm.finance_payees(staff_id,name,details,verified_by) values((p_data->>'staff_id')::bigint,trim(p_data->>'name'),trim(p_data->>'details'),a)
  on conflict(staff_id) do update set name=excluded.name,details=excluded.details,verified_by=a,verified_at=now() returning finance_payees.id into id;
 elsif p_kind='budget' then
  if coalesce(p_data->>'amount','') !~ '^\d{1,10}(\.\d{1,2})?$' then raise exception 'invalidMoney';end if;v:=(p_data->>'amount')::numeric;
  if (p_data->>'month')::date is null or extract(day from (p_data->>'month')::date)<>1 then raise exception 'invalid';end if;
  select * into r from charm.finance_budgets where category_id=(p_data->>'category_id')::bigint and month=(p_data->>'month')::date for update;
  previous:=to_jsonb(r);
  used:=charm.finance_budget_committed(r.id);
  if v<used then raise exception 'budgetExceeded';end if;
  insert into charm.finance_budgets(category_id,month,amount,updated_by) values((p_data->>'category_id')::bigint,(p_data->>'month')::date,v,a)
  on conflict(category_id,month) do update set amount=v,updated_by=a,updated_at=now() returning finance_budgets.id into id;
 else raise exception 'invalid';end if;
 perform charm.audit('financeConfigured','finance_'||p_kind,id,jsonb_build_object('before',previous,'after',p_data));return charm.finish(p_key,id);
end$$;
create function charm.finance_statement(p_key uuid,p_account bigint,p_reference text,p_direction text,p_amount text,p_date date) returns bigint language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();old bigint;id bigint;v numeric:=charm.finance_money(p_amount);begin
 perform charm.require_finance();old:=charm.claim(p_key,'finance_statement',jsonb_build_array(p_account,p_reference,p_direction,p_amount,p_date));if old is not null then return old;end if;
 if coalesce(length(trim(p_reference)),0) not between 1 and 200 or p_direction is null or p_direction not in ('in','out') or p_date is null or p_date>(now() at time zone 'Africa/Nairobi')::date then raise exception 'invalid';end if;
 if not exists(select 1 from charm.finance_accounts where finance_accounts.id=p_account and active) then raise exception 'invalid';end if;
 insert into charm.finance_statement_lines(account_id,reference,direction,amount,occurred_at,imported_by) values(p_account,trim(p_reference),p_direction,v,p_date,a) returning finance_statement_lines.id into id;
 perform charm.audit('statementImported','finance_statement_lines',id,jsonb_build_object('amount',v,'reference',p_reference));return charm.finish(p_key,id);
end$$;
create function charm.finance_match_statement(p_id bigint,p_ledger bigint) returns void language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();s charm.finance_statement_lines;l charm.finance_ledger;effective_account bigint;begin
 perform charm.require_finance();select * into s from charm.finance_statement_lines where id=p_id for update;select * into l from charm.finance_ledger where id=p_ledger for update;
 if s.id is null or l.id is null or s.ledger_id is not null then raise exception 'financeLocked';end if;
 select account_id into effective_account from charm.finance_cashbook where id=p_ledger;
 if (effective_account is not null and s.account_id<>effective_account) or s.amount<>l.amount or s.direction<>l.direction or lower(trim(s.reference))<>lower(trim(l.reference)) or s.occurred_at<>(l.occurred_at at time zone 'Africa/Nairobi')::date then raise exception 'reconciliationMismatch';end if;
 update charm.finance_statement_lines set ledger_id=p_ledger,matched_by=a,matched_at=now() where id=p_id;
 perform charm.audit('statementMatched','finance_statement_lines',p_id,jsonb_build_object('ledger_id',p_ledger));
end$$;
-- Reuse existing customer payments: receipt verification and the cashbook insertion
-- share one transaction. Historical verified payments are linked once, not recreated.
create function charm.finance_capture_customer_payment() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='verified' then
 insert into charm.finance_ledger(direction,amount,kind,reference,occurred_at,recorded_by,customer_payment_id) values('in',new.amount,'customer_receipt',new.reference,coalesce(new.received_at,now()),new.verified_by,new.id) on conflict(customer_payment_id) do nothing;
 end if;return new;end$$;
create trigger finance_customer_payment after insert or update of status on charm.payments for each row execute function charm.finance_capture_customer_payment();
insert into charm.finance_ledger(direction,amount,kind,reference,occurred_at,recorded_by,customer_payment_id)
 select 'in',amount,'customer_receipt',reference,received_at,verified_by,id from charm.payments where status='verified' and amount>0 and verified_by is not null on conflict(customer_payment_id) do nothing;
create function charm.finance_verify_customer_receipt(p_id bigint,p_confirmed boolean,p_account bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.finance_lock_actor();p charm.payments;o charm.orders;paid numeric;begin
 perform charm.require_finance();if p_confirmed is distinct from true then raise exception 'paymentConfirmationRequired';end if;
 if not exists(select 1 from charm.finance_accounts where id=p_account and active) then raise exception 'invalid';end if;
 select * into p from charm.payments where id=p_id;if p.id is null then raise exception 'notFound';end if;
 select * into o from charm.orders where id=p.order_id for update;select * into p from charm.payments where id=p_id for update;
 if p.submitted_by=a then raise exception 'selfApproval';end if;
 if p.status<>'pending' or o.status<>'confirmed' then raise exception 'financeLocked';end if;
 if p.proof_path is null or not exists(select 1 from storage.objects where bucket_id='charm-private' and name=p.proof_path) then raise exception 'proofRequired';end if;
 select coalesce(sum(amount),0) into paid from charm.payments where order_id=o.id and status='verified';if paid+p.amount>o.total then raise exception 'overpayment';end if;
 update charm.payments set status='verified',verified_by=a,verified_at=now(),updated_at=now() where id=p_id;
 -- The trigger first captures the receipt; an immutable allocation establishes its account.
 insert into charm.finance_receipt_allocations(payment_id,ledger_id,account_id,reference,confirmed_by)
 select p_id,id,p_account,p.reference,a from charm.finance_ledger where customer_payment_id=p_id;
 perform charm.audit('receiptConfirmed','payments',p_id,jsonb_build_object('account_id',p_account,'reference',p.reference,'amount',p.amount));
end$$;
-- Include statement allocations for receipts whose account was unknown in the legacy system.
create view charm.finance_cashbook with(security_invoker=true) as
 select l.id,l.request_id,coalesce(l.account_id,a.account_id,s.account_id) account_id,l.direction,l.amount,l.kind,l.reference,l.occurred_at,l.recorded_by,l.customer_payment_id,s.id statement_id,s.matched_at
 from charm.finance_ledger l left join charm.finance_receipt_allocations a on a.ledger_id=l.id left join charm.finance_statement_lines s on s.ledger_id=l.id;
grant select on charm.finance_cashbook to authenticated;
-- Lock completed postings against accidental privileged modifications as well as browser writes.
create function charm.finance_immutable() returns trigger language plpgsql set search_path='' as $$begin raise exception 'financeImmutable';end$$;
create trigger immutable_finance_allocations before update or delete on charm.finance_receipt_allocations for each row execute function charm.finance_immutable();
create trigger immutable_finance_documents before update or delete on charm.finance_documents for each row execute function charm.finance_immutable();
create trigger immutable_finance_ledger before update or delete on charm.finance_ledger for each row execute function charm.finance_immutable();
create trigger immutable_finance_disbursements before update or delete on charm.finance_disbursements for each row execute function charm.finance_immutable();
do $$ declare f record;begin
 for f in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='charm' and p.proname in ('finance_configure','finance_statement','finance_match_statement','finance_capture_customer_payment','finance_verify_customer_receipt','finance_immutable') loop
  execute format('revoke execute on function %s from public,anon,authenticated',f.signature);
  if f.proname not in ('finance_capture_customer_payment','finance_immutable') then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;end$$;
commit;

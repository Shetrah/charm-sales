begin;
-- Passwords and Laravel tokens remain private and are never imported into auth.users.
create table charm.auth_accounts (
 auth_user_id uuid primary key references auth.users(id),
 salesperson_id bigint unique not null references charm.users(id),
 linked_at timestamptz not null default now()
);
alter table charm.auth_accounts enable row level security;
alter table charm.orders add column if not exists submitted_by bigint references charm.users(id);
alter table charm.visits add column if not exists unsuccessful_reason text;
alter table charm.payments add column if not exists follow_up_notes text;
alter table charm.reports add column if not exists follow_up_date date;
create table charm.request_receipts (
 submission_key uuid primary key, actor_id bigint not null references charm.users(id),
 operation text not null, payload jsonb not null, result_id bigint
);
alter table charm.request_receipts enable row level security;

create function charm.actor() returns bigint language sql stable security definer set search_path='' as $$
 select u.id from charm.auth_accounts a join charm.users u on u.id=a.salesperson_id
 where a.auth_user_id=auth.uid() and u.active
$$;
create function charm.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select role='admin' from charm.users where id=charm.actor()),false)
$$;
create function charm.can_access(owner_id bigint) returns boolean language sql stable security definer set search_path='' as $$
 select charm.actor() is not null and (owner_id=charm.actor() or charm.is_admin())
$$;
create function charm.require_actor() returns bigint language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.actor(); begin if a is null then raise exception 'unauthorized'; end if; return a; end $$;
create function charm.require_admin() returns bigint language plpgsql stable security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); begin if not charm.is_admin() then raise exception 'forbidden'; end if; return a; end $$;
create function charm.audit(action text,entity text,entity_id bigint,details jsonb default '{}') returns void language sql security definer set search_path='' as $$
 insert into charm.audit_logs(actor_id,action,entity,entity_id,details,created_at) values(charm.require_actor(),action,entity,entity_id,details,now())
$$;
create function charm.claim(key uuid,op text,body jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); r charm.request_receipts; begin
 if key is null then raise exception 'invalid'; end if;
 perform pg_advisory_xact_lock(hashtextextended(key::text,0));
 select * into r from charm.request_receipts where submission_key=key;
 if found then
  if r.actor_id<>a or r.operation<>op or r.payload<>body then raise exception 'duplicateConflict'; end if;
  return r.result_id;
 end if;
 insert into charm.request_receipts values(key,a,op,body,null);
 return null;
end $$;
create function charm.finish(key uuid,id bigint) returns bigint language sql security definer set search_path='' as $$
 update charm.request_receipts set result_id=id where submission_key=key returning result_id
$$;

-- Explicit grants: no direct browser inserts, edits, deletes or sequence access.
revoke all on all tables in schema charm from anon,authenticated;
revoke all on all sequences in schema charm from anon,authenticated;
grant usage on schema charm to authenticated;
grant select(id,name,email,role,active) on charm.users to authenticated;
grant select on charm.auth_accounts,charm.products,charm.clients,charm.orders,charm.order_items,charm.payments,charm.visits,charm.plans,charm.expenses,charm.reports,charm.workdays,charm.location_points,charm.audit_logs to authenticated;
create policy account_self on charm.auth_accounts for select to authenticated using(auth_user_id=auth.uid() and salesperson_id=charm.actor());
create policy user_scope on charm.users for select to authenticated using(charm.can_access(id));
create policy catalogue on charm.products for select to authenticated using(charm.actor() is not null);
create policy client_scope on charm.clients for select to authenticated using(charm.can_access(salesperson_id));
create policy order_scope on charm.orders for select to authenticated using(charm.can_access(salesperson_id));
create policy item_scope on charm.order_items for select to authenticated using(exists(select 1 from charm.orders o where o.id=order_id and charm.can_access(o.salesperson_id)));
create policy payment_scope on charm.payments for select to authenticated using(exists(select 1 from charm.orders o where o.id=order_id and charm.can_access(o.salesperson_id)));
create policy visit_scope on charm.visits for select to authenticated using(charm.can_access(salesperson_id));
create policy plan_scope on charm.plans for select to authenticated using(charm.can_access(salesperson_id));
create policy expense_scope on charm.expenses for select to authenticated using(charm.can_access(salesperson_id));
create policy report_scope on charm.reports for select to authenticated using(charm.can_access(salesperson_id));
create policy workday_scope on charm.workdays for select to authenticated using(charm.can_access(salesperson_id));
create policy point_scope on charm.location_points for select to authenticated using(exists(select 1 from charm.workdays w where w.id=workday_id and charm.can_access(w.salesperson_id)));
create policy audit_admin on charm.audit_logs for select to authenticated using(charm.is_admin());

create index if not exists react_clients_owner on charm.clients(salesperson_id,id desc);
create index if not exists react_orders_owner_confirmed on charm.orders(salesperson_id,status,confirmed_at);
create index if not exists react_orders_client on charm.orders(client_id,status);
create index if not exists react_payments_balance on charm.payments(order_id,status);
create index if not exists react_items_order on charm.order_items(order_id);
create index if not exists react_points_route on charm.location_points(workday_id,recorded_at,id);
create index if not exists react_workdays_owner on charm.workdays(salesperson_id,date desc);
create index if not exists react_visits_owner on charm.visits(salesperson_id,id desc);
create index if not exists react_plans_owner on charm.plans(salesperson_id,id desc);
create index if not exists react_expenses_owner on charm.expenses(salesperson_id,id desc);
create index if not exists react_reports_owner on charm.reports(salesperson_id,id desc);
-- New functions are private unless explicitly granted in the API migration.
revoke execute on all functions in schema charm from public,anon,authenticated;
grant execute on function charm.actor(),charm.is_admin(),charm.can_access(bigint) to authenticated;
commit;

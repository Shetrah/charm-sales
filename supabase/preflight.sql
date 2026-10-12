-- Read-only reconciliation manifest. Save results before/after staging migrations and cutover.
begin transaction read only;
select table_name,column_name,data_type,is_nullable from information_schema.columns
 where table_schema='charm' order by table_name,ordinal_position;
select schemaname,tablename,policyname,roles,cmd,qual,with_check from pg_policies where schemaname in ('charm','storage');
select 'users' as entity,count(*) as records from charm.users union all
select 'products',count(*) from charm.products union all select 'clients',count(*) from charm.clients union all
select 'orders',count(*) from charm.orders union all select 'order_items',count(*) from charm.order_items union all
select 'payments',count(*) from charm.payments union all select 'visits',count(*) from charm.visits union all
select 'plans',count(*) from charm.plans union all select 'expenses',count(*) from charm.expenses union all
select 'reports',count(*) from charm.reports union all select 'workdays',count(*) from charm.workdays union all
select 'location_points',count(*) from charm.location_points union all select 'audit_logs',count(*) from charm.audit_logs;
select salesperson_id,date_trunc('month',confirmed_at at time zone 'Africa/Nairobi') as month,sum(total) as sales
 from charm.orders where status='confirmed' group by 1,2 order by 1,2;
select o.id,o.salesperson_id,o.total,coalesce(sum(p.amount) filter(where p.status='verified'),0) as paid,
 o.total-coalesce(sum(p.amount) filter(where p.status='verified'),0) as balance
 from charm.orders o left join charm.payments p on p.order_id=o.id where o.status='confirmed' group by o.id order by o.id;
select lower(email),count(*) from charm.users group by lower(email) having count(*)>1;
select id,category,capacity,fragrance,barcode,carton,unit_price,needs_review from charm.products order by id;
commit;

-- Channel workspace notifications to the people who own or must act on the record, not to every signed-in member.
begin;

create or replace function charm.notify_workspace_activity() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  payload jsonb := to_jsonb(new);
  previous jsonb := case when tg_op='UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  actor bigint := charm.actor();
  owner_id bigint;
  client_owner bigint;
  record_id bigint;
  state text;
  managers boolean;
  finance boolean;
  recipient record;
  event_name text;
  event_token text;
begin
  record_id := nullif(payload->>'id','')::bigint;
  owner_id := coalesce(nullif(payload->>'salesperson_id','')::bigint,
                       nullif(payload->>'submitted_by','')::bigint,
                       nullif(payload->>'user_id','')::bigint,
                       nullif(payload->>'owner_id','')::bigint,
                       nullif(payload->>'created_by','')::bigint,
                       nullif(payload->>'started_by','')::bigint);
  client_owner := (select c.salesperson_id from charm.clients c where c.id=nullif(payload->>'client_id','')::bigint);
  state := coalesce(payload->>'status','');
  if tg_op='UPDATE' and (tg_table_name in ('clients','visits','reports','workdays') or coalesce(previous->>'status','')=state) then
    return new;
  end if;

  event_name := case
    when tg_op='INSERT' then tg_table_name||'_submitted'
    else coalesce(nullif(state,''),tg_table_name||'_updated') end;
  event_token := tg_table_name||':'||record_id||':'||tg_op||':'||coalesce(nullif(state,''),to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS'));

  -- Admins approve client, order, payment and production records; field activity stays with the responsible person.
  managers := tg_table_name in ('clients','orders','payments','production_materials','production_formulas','production_batches');
  finance := tg_table_name in ('payments','production_materials','production_formulas','production_batches')
    or (tg_table_name='orders' and state='confirmed');

  for recipient in
    select u.id, u.role::text as role from charm.users u
    where u.active and u.id<>coalesce(actor,-1)
      and (u.id=owner_id or u.id=client_owner
           or (managers and u.role='admin')
           or (finance and u.role='finance_officer'))
  loop
    insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
      values(recipient.id,null,event_name,event_token||':'||recipient.id,tg_table_name,record_id)
      on conflict do nothing;
  end loop;

  -- A released batch only matters to the salespeople whose confirmed orders still wait for a production lot.
  if tg_table_name='production_batches' and state='released' then
    insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
      select distinct o.salesperson_id,null::bigint,event_name,'batch-released:'||record_id||':'||o.salesperson_id,'production_batches',record_id
      from charm.orders o
      join charm.finance_sales_invoices v on v.order_id=o.id
      where o.status='confirmed' and coalesce(v.batch_lot,'')='' and o.salesperson_id<>coalesce(actor,-1)
      on conflict do nothing;
  end if;
  return new;
end $$;

revoke execute on function charm.notify_workspace_activity() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;

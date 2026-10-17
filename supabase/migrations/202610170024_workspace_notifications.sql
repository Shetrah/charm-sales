-- Deliver relevant sales, field, and finance work to the people who need to act.
begin;
alter table charm.finance_notifications
  add column if not exists entity text,
  add column if not exists entity_id bigint;

create or replace function charm.notify_workspace_activity() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  payload jsonb := to_jsonb(new);
  previous jsonb := case when tg_op='UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  actor bigint := charm.actor();
  owner_id bigint;
  record_id bigint;
  state text;
  recipient record;
  event_name text;
  event_token text;
begin
  record_id := nullif(payload->>'id','')::bigint;
  owner_id := coalesce(nullif(payload->>'salesperson_id','')::bigint,
                       nullif(payload->>'submitted_by','')::bigint,
                       nullif(payload->>'user_id','')::bigint,
                       nullif(payload->>'owner_id','')::bigint);
  state := coalesce(payload->>'status','');
  if tg_op='UPDATE' and (tg_table_name in ('clients','visits','reports','workdays') or coalesce(previous->>'status','')=state) then
    return new;
  end if;

  event_name := case
    when tg_op='INSERT' then tg_table_name||'_submitted'
    else coalesce(nullif(state,''),tg_table_name||'_updated') end;
  event_token := tg_table_name||':'||record_id||':'||tg_op||':'||coalesce(nullif(state,''),to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS'));

  for recipient in
    select id,role::text as role from charm.users
    where active and id<>coalesce(actor,-1)
      and (role in ('admin','finance_officer','finance_manager','management')
           or (owner_id is not null and id=owner_id))
  loop
    -- Keep operational updates with the responsible people; financial updates also reach Finance.
    if tg_table_name in ('payments','expenses') and recipient.role not in ('admin','finance_officer','finance_manager','management') and recipient.id<>owner_id then
      continue;
    end if;
    insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
      values(recipient.id,null,event_name,event_token||':'||recipient.id,tg_table_name,record_id)
      on conflict do nothing;
  end loop;
  return new;
end $$;

do $$ declare t text; begin
 foreach t in array array['clients','orders','payments','visits','plans','expenses','reports','workdays'] loop
   execute format('drop trigger if exists workspace_activity_notify on charm.%I',t);
   execute format('create trigger workspace_activity_notify after insert or update on charm.%I for each row execute function charm.notify_workspace_activity()',t);
 end loop;
end $$;
revoke execute on function charm.notify_workspace_activity() from public,anon,authenticated;
commit;

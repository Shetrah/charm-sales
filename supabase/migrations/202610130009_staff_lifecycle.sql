-- Apply after 008. Deletion preserves staff IDs and all business history.
begin;
create table charm.staff_archives (
 staff_id bigint primary key references charm.users(id),
 deleted_by bigint not null references charm.users(id),
 deleted_at timestamptz not null default now()
);
alter table charm.staff_archives enable row level security;
grant select on charm.staff_archives to authenticated;
create policy staff_archives_admin on charm.staff_archives for select to authenticated using(charm.is_admin());
create view charm.team_directory with(security_invoker=true) as
 select u.id,u.name,u.email,u.role,u.active from charm.users u
 where not exists(select 1 from charm.staff_archives a where a.staff_id=u.id);
grant select on charm.team_directory to authenticated;

create function charm.guard_archived_staff() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.active and exists(select 1 from charm.staff_archives where staff_id=new.id) then raise exception 'staffDeleted'; end if;
 return new;
end $$;
revoke execute on function charm.guard_archived_staff() from public,anon,authenticated;
create trigger archived_staff_cannot_enable before update on charm.users for each row execute function charm.guard_archived_staff();

create function charm.manage_staff(p_id bigint,p_action text) returns void language plpgsql security definer set search_path='' as $$
declare a bigint; caller charm.users; u charm.users;
begin
 a:=charm.require_admin();
 if p_action is null or p_action not in ('deactivate','reactivate','delete') then raise exception 'invalid'; end if;
 perform pg_advisory_xact_lock(817201008);
 select * into caller from charm.users where id=a for update;
 if caller.role<>'admin' or not caller.active then raise exception 'forbidden'; end if;
 select * into u from charm.users where id=p_id for update;
 if not found then raise exception 'notFound'; end if;
 if p_id=a then raise exception 'cannotManageSelf'; end if;
 if exists(select 1 from charm.staff_archives where staff_id=p_id) then
  if p_action='delete' then return; end if;
  raise exception 'staffDeleted';
 end if;
 if u.role='admin' and u.active and p_action in ('deactivate','delete') and (select count(*) from charm.users where role='admin' and active)<=1 then raise exception 'lastAdmin'; end if;
 if p_action='delete' then
  update charm.users set active=false,updated_at=now() where id=p_id;
  insert into charm.staff_archives(staff_id,deleted_by) values(p_id,a);
  perform charm.audit('staffDeleted','users',p_id,jsonb_build_object('history_preserved',true));
 elsif p_action='deactivate' and u.active then
  update charm.users set active=false,updated_at=now() where id=p_id;
  perform charm.audit('staffDeactivated','users',p_id);
 elsif p_action='reactivate' and not u.active then
  update charm.users set active=true,updated_at=now() where id=p_id;
  perform charm.audit('staffReactivated','users',p_id);
 end if;
end $$;
revoke execute on function charm.manage_staff(bigint,text) from public,anon;
grant execute on function charm.manage_staff(bigint,text) to authenticated;
commit;
notify pgrst,'reload schema';

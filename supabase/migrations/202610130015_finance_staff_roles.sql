begin;
create or replace function charm.update_staff(p_id bigint,p_name text,p_phone text,p_territory text,p_role text,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint; u charm.users; caller charm.users;
begin
 a:=charm.require_admin();
 perform pg_advisory_xact_lock(817201008);
 select * into caller from charm.users where id=a for update;
 if caller.role<>'admin' or not caller.active then raise exception 'forbidden'; end if;
 select * into u from charm.users where id=p_id for update;
 if not found then raise exception 'notFound'; end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(p_phone),0)>40 or coalesce(length(p_territory),0)>200 or p_role is null or p_role not in ('admin','salesperson','finance_officer','finance_manager','management','auditor') or p_active is null then raise exception 'invalid'; end if;
 if p_id=a and (p_role<>u.role or p_active<>u.active) then raise exception 'selfRoleChange'; end if;
 if u.role='admin' and u.active and (p_role<>'admin' or not p_active) and (select count(*) from charm.users where role='admin' and active)<=1 then raise exception 'lastAdmin'; end if;
 update charm.users set name=trim(p_name),phone=nullif(trim(p_phone),''),territory=nullif(trim(p_territory),''),role=p_role,active=p_active,updated_at=now() where id=p_id;
 perform charm.audit('staffUpdated','users',p_id,jsonb_build_object('before',jsonb_build_object('name',u.name,'phone',u.phone,'territory',u.territory,'role',u.role,'active',u.active),'after',jsonb_build_object('name',trim(p_name),'phone',p_phone,'territory',p_territory,'role',p_role,'active',p_active)));
end $$;
create or replace function charm.link_staff(p_actor uuid,p_auth uuid,p_email text,p_name text,p_role text) returns bigint language plpgsql security definer set search_path='' as $$
declare admin_id bigint; staff_id bigint; existing_auth uuid; canonical_email text;
begin
 select u.id into admin_id from charm.auth_accounts a join charm.users u on u.id=a.salesperson_id where a.auth_user_id=p_actor and u.active and u.role='admin';
 if admin_id is null or p_actor=p_auth then raise exception 'forbidden'; end if;
 select email into canonical_email from auth.users where id=p_auth;
 if canonical_email is null or lower(canonical_email)<>lower(trim(p_email)) or p_role not in ('admin','salesperson','finance_officer','finance_manager','management','auditor') or coalesce(length(trim(p_name)),0) not between 1 and 200 then raise exception 'invalid'; end if;
 perform pg_advisory_xact_lock(hashtextextended(lower(trim(p_email)),1));
 if (select count(*) from charm.users where lower(email)=lower(trim(p_email)))>1 then raise exception 'duplicateConflict'; end if;
 select id into staff_id from charm.users where lower(email)=lower(trim(p_email)) for update;
 if staff_id=admin_id then raise exception 'forbidden'; end if;
 if staff_id is null then
  -- Unusable legacy password; Supabase reset/invite establishes the real credential.
  insert into charm.users(name,email,password,role,active,created_at,updated_at) values(p_name,lower(trim(p_email)),'!supabase-auth-only!',p_role,true,now(),now()) returning id into staff_id;
 end if;
 select auth_user_id into existing_auth from charm.auth_accounts where salesperson_id=staff_id;
 if existing_auth is not null and existing_auth<>p_auth then raise exception 'duplicateConflict'; end if;
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values(p_auth,staff_id) on conflict(auth_user_id) do nothing;
 if not exists(select 1 from charm.auth_accounts where auth_user_id=p_auth and salesperson_id=staff_id) then raise exception 'duplicateConflict'; end if;
 insert into charm.audit_logs(actor_id,action,entity,entity_id,details,created_at) values(admin_id,'invited','users',staff_id,jsonb_build_object('auth_user_id',p_auth),now());
 return staff_id;
end $$;
commit;

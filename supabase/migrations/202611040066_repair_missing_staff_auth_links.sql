begin;

-- Repair Supabase accounts that already exist but were not linked to their
-- unique active staff row. Never overwrite an existing auth or staff link and
-- never guess when staff email addresses are duplicated.
with eligible as (
 select au.id as auth_user_id,min(u.id) as staff_id
 from auth.users au
 join charm.users u on lower(trim(u.email))=lower(trim(au.email))
 where nullif(trim(au.email),'') is not null
   and (select count(*) from auth.users au2 where lower(trim(au2.email))=lower(trim(au.email)))=1
   and u.active
   and not exists(select 1 from charm.staff_archives a where a.staff_id=u.id)
   and not exists(select 1 from charm.auth_accounts aa where aa.auth_user_id=au.id)
   and not exists(select 1 from charm.auth_accounts aa where aa.salesperson_id=u.id)
 group by au.id,lower(trim(au.email))
 having count(distinct u.id)=1
)
insert into charm.auth_accounts(auth_user_id,salesperson_id)
select auth_user_id,staff_id from eligible
on conflict do nothing;

-- Refresh PostgREST's metadata for sessions that retry the actor lookup.
notify pgrst,'reload schema';
commit;

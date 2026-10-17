-- Shared supplier contact directory fields and secure supplier creation RPC.
begin;
alter table charm.finance_payees
 add column if not exists contact_person text not null default '',
 add column if not exists phone text not null default '',
 add column if not exists email text not null default '',
 add column if not exists address text not null default '';
create function charm.finance_create_supplier(p_key uuid,p_name text,p_contact_person text,p_phone text,p_email text,p_address text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();old bigint;id bigint;pay_details text;payload jsonb;begin
 if charm.finance_role() not in ('admin','finance_officer','finance_manager') then raise exception 'forbidden';end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(trim(p_contact_person)),0) not between 1 and 200 or coalesce(length(trim(p_phone)),0)>80 or coalesce(length(trim(p_email)),0)>254 or coalesce(length(trim(p_address)),0)>500 then raise exception 'invalid';end if;
 if coalesce(trim(p_email),'')<>'' and trim(p_email)!~*'^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then raise exception 'invalid';end if;
 payload:=jsonb_build_array(trim(p_name),trim(p_contact_person),coalesce(trim(p_phone),''),coalesce(trim(p_email),''),coalesce(trim(p_address),''));old:=charm.claim(p_key,'finance_create_supplier',payload);if old is not null then return old;end if;
 pay_details:=concat_ws(' · ',nullif(trim(p_contact_person),''),nullif(trim(p_phone),''),nullif(trim(p_email),''),nullif(trim(p_address),''));
 insert into charm.finance_payees(name,details,verified_by,contact_person,phone,email,address) values(trim(p_name),coalesce(nullif(pay_details,''),'Contact supplier for verified payment instructions'),a,trim(p_contact_person),coalesce(trim(p_phone),''),coalesce(trim(p_email),''),coalesce(trim(p_address),'')) returning finance_payees.id into id;
 perform charm.audit('supplierCreated','finance_payees',id,jsonb_build_object('name',trim(p_name),'contact_person',trim(p_contact_person)));
 insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) select u.id,null,'supplierCreated','supplier-created:'||id||':'||u.id,'finance_payees',id from charm.users u where u.active and u.id<>a and u.role in ('admin','finance_officer','finance_manager') on conflict do nothing;
 return charm.finish(p_key,id);
end$$;
revoke execute on function charm.finance_create_supplier(uuid,text,text,text,text,text) from public,anon,authenticated;
grant execute on function charm.finance_create_supplier(uuid,text,text,text,text,text) to authenticated;
notify pgrst, 'reload schema';
commit;

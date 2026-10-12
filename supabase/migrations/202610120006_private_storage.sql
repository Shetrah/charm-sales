begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('charm-private','charm-private',false,5242880,array['image/jpeg','image/png','image/webp'])
 on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
-- Preserve legacy paths: visits/{record_id}/{uuid}.png or payments/{record_id}/{uuid}.png.
create function charm.file_access(path text,writing boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare kind text:=split_part(path,'/',1); record_id bigint; owner bigint; status text;
begin
 if charm.actor() is null or split_part(path,'/',2) !~ '^\d+$' then return false; end if;
 record_id:=split_part(path,'/',2)::bigint;
 if kind='visits' then select salesperson_id into owner from charm.visits where visits.id=record_id;
 elsif kind='payments' then select o.salesperson_id,p.status into owner,status from charm.payments p join charm.orders o on o.id=p.order_id where p.id=record_id;
 else return false; end if;
 if writing and kind='payments' and status<>'pending' then return false; end if;
 return owner is not null and coalesce(charm.can_access(owner),false);
end $$;
create policy charm_files_read on storage.objects for select to authenticated using(bucket_id='charm-private' and charm.file_access(name));
create policy charm_files_insert on storage.objects for insert to authenticated with check(bucket_id='charm-private' and charm.file_access(name,true));
-- No overwrite or delete policy. Attachments become immutable evidence after verification.
create function charm.attach_file(p_kind text,p_id bigint,p_path text) returns void language plpgsql security definer set search_path='' as $$
declare p charm.payments;
begin
 perform charm.require_actor();
 if p_kind='payments' then
  select * into p from charm.payments where id=p_id for update;
  if p.status<>'pending' then raise exception 'alreadyReviewed'; end if;
 end if;
 if p_kind not in ('visits','payments') or p_kind is null or p_path not like p_kind||'/'||p_id||'/%' or not charm.file_access(p_path,true) or not exists(select 1 from storage.objects where bucket_id='charm-private' and name=p_path) then raise exception 'forbidden'; end if;
 if p_kind='visits' then update charm.visits set photo_path=p_path where id=p_id;
 else update charm.payments set proof_path=p_path where id=p_id; end if;
 perform charm.audit('attached',p_kind,p_id,jsonb_build_object('path',p_path));
end $$;
revoke execute on function charm.file_access(text,boolean),charm.attach_file(text,bigint,text) from public,anon;
grant execute on function charm.file_access(text,boolean),charm.attach_file(text,bigint,text) to authenticated;
commit;

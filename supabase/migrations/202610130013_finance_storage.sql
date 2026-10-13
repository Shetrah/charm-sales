begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('charm-finance','charm-finance',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create function charm.finance_file_access(p_path text,p_write boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare parts text[]:=string_to_array(p_path,'/');r charm.finance_requests;a bigint:=charm.actor();begin
 if a is null or p_path !~ '^requests/[0-9]+/(support|payment|receipt|refund)/[0-9]+/[a-f0-9-]{36}\.(pdf|jpg|png|webp)$' then return false;end if;
 select * into r from charm.finance_requests where id=parts[2]::bigint;
 if r.id is null then return false;end if;
 if not p_write then return charm.finance_access(r.id);end if;
 if charm.finance_role() in ('management','auditor') then return false;end if;
 if parts[4]::bigint<>a then return false;end if;
 return (parts[3]='support' and r.owner_id=a and r.status in ('draft','returned'))
  or (parts[3]='payment' and charm.finance_operator() and r.owner_id<>a and r.status in ('approved','part_paid'))
  or (parts[3] in ('receipt','refund') and r.owner_id=a and r.kind='staff' and r.status in ('part_paid','paid'));
end$$;
create policy finance_file_read on storage.objects for select to authenticated using(bucket_id='charm-finance' and charm.finance_file_access(name,false));
create policy finance_file_upload on storage.objects for insert to authenticated with check(bucket_id='charm-finance' and charm.finance_file_access(name,true));
-- No overwrite/delete permission: attached evidence and payment proof are immutable.
create function charm.finance_attach_document(p_id bigint,p_kind text,p_path text) returns bigint language plpgsql security definer set search_path='' as $$declare a bigint:=charm.finance_lock_actor();id bigint;begin
 perform 1 from charm.finance_requests where finance_requests.id=p_id for update;
 if split_part(p_path,'/',2) is distinct from p_id::text or split_part(p_path,'/',3) is distinct from p_kind or not charm.finance_file_access(p_path,true) then raise exception 'forbidden';end if;
 if not exists(select 1 from storage.objects where bucket_id='charm-finance' and name=p_path) then raise exception 'proofRequired';end if;
 select finance_documents.id into id from charm.finance_documents where path=p_path;if id is not null then return id;end if;
 insert into charm.finance_documents(request_id,kind,path,uploaded_by) values(p_id,p_kind,p_path,a) returning finance_documents.id into id;
 perform charm.audit('financeDocument','finance_requests',p_id,jsonb_build_object('document_id',id,'kind',p_kind));return id;
end$$;
revoke execute on function charm.finance_file_access(text,boolean),charm.finance_attach_document(bigint,text,text) from public,anon,authenticated;
grant execute on function charm.finance_file_access(text,boolean),charm.finance_attach_document(bigint,text,text) to authenticated;
do $$ declare t text;begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
 foreach t in array array['finance_requests','finance_disbursements','finance_accountability','finance_ledger','finance_budgets','finance_notifications','finance_statement_lines'] loop
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='charm' and tablename=t) then execute format('alter publication supabase_realtime add table charm.%I',t);end if;
 end loop;end if;
end$$;
commit;

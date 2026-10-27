-- Contract-first order workflow. Additive and safe for existing orders:
-- contracts are versioned, documents are metadata-backed, submission is a separate
-- explicit action, approval requires a reviewed submitted contract, and receipt is audited.
begin;

alter table charm.orders
  add column if not exists contract_reference text,
  add column if not exists contract_signed_by text,
  add column if not exists contract_terms text,
  add column if not exists contract_status text not null default 'draft',
  add column if not exists contract_submitted_at timestamptz,
  add column if not exists contract_submitted_by bigint references charm.users(id),
  add column if not exists contract_approved_at timestamptz,
  add column if not exists contract_approved_by bigint references charm.users(id),
  add column if not exists contract_version integer not null default 0,
  add column if not exists contract_file_count integer not null default 0,
  add column if not exists contract_page_count integer,
  add column if not exists contract_file_name text,
  add column if not exists receipt_status text not null default 'pending',
  add column if not exists received_at timestamptz,
  add column if not exists received_by bigint references charm.users(id),
  add column if not exists receipt_notes text;

alter table charm.orders drop constraint if exists orders_contract_status_check;
alter table charm.orders add constraint orders_contract_status_check check(contract_status in ('draft','submitted','approved','rejected','amendment_required'));
alter table charm.orders drop constraint if exists orders_receipt_status_check;
alter table charm.orders add constraint orders_receipt_status_check check(receipt_status in ('pending','received'));

create table if not exists charm.order_documents(
  id bigserial primary key,
  order_id bigint not null references charm.orders(id),
  kind text not null check(kind in ('contract','supporting','amendment')),
  storage_path text not null unique,
  file_name text not null,
  mime_type text not null check(mime_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  size_bytes bigint check(size_bytes is null or size_bytes between 1 and 20971520),
  page_count integer check(page_count is null or page_count between 1 and 100),
  document_key uuid not null,
  contract_version integer not null default 1,
  uploaded_by bigint not null references charm.users(id),
  uploaded_at timestamptz not null default now(),
  unique(order_id,document_key)
);
alter table charm.order_documents enable row level security;
grant select on charm.order_documents to authenticated;
drop policy if exists order_document_scope on charm.order_documents;
create policy order_document_scope on charm.order_documents for select to authenticated
 using(exists(select 1 from charm.orders o where o.id=order_id and charm.can_access(o.salesperson_id)));
create index if not exists order_documents_order on charm.order_documents(order_id,kind,id);

create table if not exists charm.order_contract_versions(
  id bigserial primary key,
  order_id bigint not null references charm.orders(id),
  version integer not null check(version>0),
  reference text not null,
  signed_by text not null,
  terms text not null,
  customer_type text not null,
  status text not null default 'submitted' check(status in ('submitted','approved','rejected','superseded')),
  submitted_by bigint not null references charm.users(id),
  submitted_at timestamptz not null default now(),
  documents jsonb not null default '[]'::jsonb,
  amendment_reason text,
  unique(order_id,version)
);
alter table charm.order_contract_versions enable row level security;
grant select on charm.order_contract_versions to authenticated;
drop policy if exists order_contract_version_scope on charm.order_contract_versions;
create policy order_contract_version_scope on charm.order_contract_versions for select to authenticated
 using(exists(select 1 from charm.orders o where o.id=order_id and charm.can_access(o.salesperson_id)));
create index if not exists order_contract_versions_order on charm.order_contract_versions(order_id,version desc);

create or replace function charm.save_order_contract(p_key uuid,p_id bigint,p_reference text,p_signed_by text,p_terms text,p_customer_type text)
returns integer language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); o charm.orders; old bigint; v integer;
begin
 if p_id is null then raise exception 'invalid'; end if;
 if coalesce(length(trim(p_reference)),0) not between 3 and 120
   or coalesce(length(trim(p_signed_by)),0) not between 2 and 200
   or coalesce(length(trim(p_terms)),0) not between 20 and 20000
   or p_customer_type not in ('wholesaler','retailer') then raise exception 'contractIncomplete'; end if;
 old:=charm.claim(p_key,'order_contract',jsonb_build_object('id',p_id,'reference',trim(p_reference),'signed_by',trim(p_signed_by),'terms',trim(p_terms),'customer_type',p_customer_type));
 if old is not null then return old; end if;
 select * into o from charm.orders where orders.id=p_id for update;
 if not found or o.status<>'draft' or o.contract_status not in ('draft','amendment_required') or not charm.can_access(o.salesperson_id) then raise exception 'contractLocked'; end if;
 update charm.orders set contract_reference=trim(p_reference),contract_signed_by=trim(p_signed_by),contract_terms=trim(p_terms),
   customer_type=p_customer_type,contract_status='draft',updated_at=now() where orders.id=p_id;
 v:=greatest(1,o.contract_version);
 perform charm.audit('contract_saved','orders',p_id,jsonb_build_object('reference',trim(p_reference),'version',v));
 return charm.finish(p_key,v);
end $$;

create or replace function charm.add_order_document(p_key uuid,p_id bigint,p_kind text,p_path text,p_name text,p_mime text,p_size bigint,p_pages integer default null)
returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); o charm.orders; doc charm.order_documents; id bigint; primary_path text;
begin
 if p_kind not in ('contract','supporting','amendment') or p_path is null or p_path not like 'orders/'||p_id||'/%'
   or coalesce(length(trim(p_name)),0) not between 1 and 255
   or p_mime not in ('image/jpeg','image/png','image/webp','application/pdf')
   or p_size is null or p_size not between 1 and 20971520
   or (p_pages is not null and p_pages not between 1 and 100) then raise exception 'invalidDocument'; end if;
 if p_key is null then raise exception 'invalid'; end if;
 select * into o from charm.orders where orders.id=p_id for update;
 if not found or o.status<>'draft' or o.contract_status not in ('draft','amendment_required') or not charm.can_access(o.salesperson_id) then raise exception 'contractLocked'; end if;
 select * into doc from charm.order_documents where order_id=p_id and document_key=p_key;
 if found then
  if doc.storage_path<>p_path or doc.kind<>p_kind then raise exception 'duplicateConflict'; end if;
  return doc.id;
 end if;
 if not exists(select 1 from storage.objects where bucket_id='charm-private' and name=p_path) then raise exception 'documentUploadRequired'; end if;
 insert into charm.order_documents(order_id,kind,storage_path,file_name,mime_type,size_bytes,page_count,document_key,contract_version,uploaded_by)
 values(p_id,p_kind,p_path,trim(p_name),p_mime,p_size,p_pages,p_key,greatest(1,o.contract_version),a) returning order_documents.id into id;
 select storage_path into primary_path from charm.order_documents where order_id=p_id and kind='contract' order by charm.order_documents.id limit 1;
 update charm.orders set contract_path=coalesce(contract_path,primary_path),
   contract_file_count=(select count(*) from charm.order_documents where order_id=p_id and kind='contract'),
   contract_page_count=(select coalesce(sum(coalesce(page_count,1)),0) from charm.order_documents where order_id=p_id and kind='contract'),
   contract_file_name=(select file_name from charm.order_documents where order_id=p_id and kind='contract' order by charm.order_documents.id limit 1),
   updated_at=now() where orders.id=p_id;
 perform charm.audit('document_attached','orders',p_id,jsonb_build_object('kind',p_kind,'name',trim(p_name),'path',p_path));
 return id;
end $$;

create or replace function charm.remove_order_document(p_id bigint,p_document_id bigint) returns void
language plpgsql security definer set search_path='' as $$
declare o charm.orders; doc charm.order_documents; primary_path text;
begin
 perform charm.require_sales_writer();
 select * into o from charm.orders where orders.id=p_id for update;
 if not found or o.status<>'draft' or o.contract_status not in ('draft','amendment_required') or not charm.can_access(o.salesperson_id) then raise exception 'contractLocked'; end if;
 delete from charm.order_documents where id=p_document_id and order_id=p_id returning * into doc;
 if not found then raise exception 'notFound'; end if;
 select storage_path into primary_path from charm.order_documents where order_id=p_id and kind='contract' order by charm.order_documents.id limit 1;
 update charm.orders set contract_path=primary_path,
   contract_file_count=(select count(*) from charm.order_documents where order_id=p_id and kind='contract'),
   contract_page_count=(select coalesce(sum(coalesce(page_count,1)),0) from charm.order_documents where order_id=p_id and kind='contract'),
   contract_file_name=(select file_name from charm.order_documents where order_id=p_id and kind='contract' order by charm.order_documents.id limit 1),
   updated_at=now() where orders.id=p_id;
 perform charm.audit('document_removed','orders',p_id,jsonb_build_object('kind',doc.kind,'name',doc.file_name));
end $$;

create or replace function charm.submit_order_contract(p_key uuid,p_id bigint,p_confirm boolean) returns void
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); o charm.orders; old bigint; v integer; docs jsonb;
begin
 if p_confirm is distinct from true then raise exception 'contractConfirmationRequired'; end if;
 old:=charm.claim(p_key,'order_contract_submit',jsonb_build_object('id',p_id)); if old is not null then return; end if;
 select * into o from charm.orders where orders.id=p_id for update;
 if not found or not charm.can_access(o.salesperson_id) then raise exception 'forbidden'; end if;
 if o.status<>'draft' then raise exception 'alreadySubmitted'; end if;
 if o.contract_status not in ('draft','amendment_required') then raise exception 'contractLocked'; end if;
 if coalesce(length(trim(o.contract_reference)),0) not between 3 and 120
   or coalesce(length(trim(o.contract_signed_by)),0) not between 2 and 200
   or coalesce(length(trim(o.contract_terms)),0) not between 20 and 20000
   or o.customer_type not in ('wholesaler','retailer') then raise exception 'contractIncomplete'; end if;
 if not exists(select 1 from charm.order_documents d where d.order_id=p_id and d.kind='contract') then raise exception 'contractDocumentRequired'; end if;
 if exists(select 1 from charm.order_documents d where d.order_id=p_id and d.kind='contract'
   and not exists(select 1 from storage.objects s where s.bucket_id='charm-private' and s.name=d.storage_path)) then raise exception 'documentUploadRequired'; end if;
 v:=o.contract_version+1;
 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'name',d.file_name,'kind',d.kind,'mime',d.mime_type,'pages',d.page_count) order by d.id),'[]'::jsonb)
   into docs from charm.order_documents d where d.order_id=p_id;
 update charm.order_contract_versions set status='superseded' where order_id=p_id and status in ('submitted','approved');
 insert into charm.order_contract_versions(order_id,version,reference,signed_by,terms,customer_type,submitted_by,submitted_at,documents)
 values(p_id,v,o.contract_reference,o.contract_signed_by,o.contract_terms,o.customer_type,a,clock_timestamp(),docs);
 update charm.orders set contract_status='submitted',contract_submitted_at=clock_timestamp(),contract_submitted_by=a,
   contract_version=v,contract_path=(select storage_path from charm.order_documents where order_id=p_id and kind='contract' order by charm.order_documents.id limit 1),
   contract_file_name=(select file_name from charm.order_documents where order_id=p_id and kind='contract' order by charm.order_documents.id limit 1),
   contract_approved_at=null,contract_approved_by=null,
   receipt_status='pending',received_at=null,received_by=null,receipt_notes=null,updated_at=now() where orders.id=p_id;
 perform charm.audit('contract_submitted','orders',p_id,jsonb_build_object('version',v,'documents',jsonb_array_length(docs)));
 perform charm.finish(p_key,p_id);
end $$;

-- Order submission is a second explicit action after the contract is submitted.
create or replace function charm.submit_order_draft(p_id bigint) returns void
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); o charm.orders;
begin
 select * into o from charm.orders where id=p_id for update;
 if not found or not charm.can_access(o.salesperson_id) then raise exception 'forbidden';end if;
 if o.status='pending' and o.contract_status='submitted' then return;end if;
 if o.status<>'draft' then raise exception 'alreadySubmitted';end if;
 if o.contract_status<>'submitted' or o.contract_version<1 then raise exception 'contractFormRequired';end if;
 if not exists(select 1 from charm.order_contract_versions v where v.order_id=p_id and v.version=o.contract_version and v.status='submitted') then raise exception 'contractFormRequired';end if;
 if not exists(select 1 from charm.order_documents d where d.order_id=p_id and d.kind='contract') then raise exception 'contractDocumentRequired';end if;
 if exists(select 1 from charm.order_documents d where d.order_id=p_id and d.kind='contract'
   and not exists(select 1 from storage.objects s where s.bucket_id='charm-private' and s.name=d.storage_path)) then raise exception 'documentUploadRequired';end if;
 update charm.orders set status='pending',submitted_by=a,updated_at=now() where id=p_id;
 perform charm.audit('submitted','orders',p_id,jsonb_build_object('customer_type',o.customer_type,'contract',true,'version',o.contract_version));
end $$;

-- Drafts stay editable until the contract is submitted; then only a controlled
-- amendment can unlock them. This keeps the uploaded contract and order lines aligned.
create or replace function charm.save_order_draft(p_key uuid,p_id bigint,p_client bigint,p_due date,p_items jsonb,p_customer_type text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_sales_writer(); c charm.clients; p charm.products; item jsonb; id bigint; old bigint; qty integer; price numeric; v_total numeric:=0; locked boolean:=false;
begin
 if p_id is null then old:=charm.claim(p_key,'order_draft',jsonb_build_object('client',p_client,'due',p_due,'items',p_items,'customer_type',p_customer_type));if old is not null then return old;end if;end if;
 if p_customer_type not in ('wholesaler','retailer') or p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 100 then raise exception 'invalid';end if;
 select * into c from charm.clients where clients.id=p_client for share;
 if not found or not charm.can_access(c.salesperson_id) then raise exception 'forbidden';end if;
 if p_id is not null then
  select contract_status='submitted' into locked from charm.orders where orders.id=p_id and charm.can_access(orders.salesperson_id);
  if locked then raise exception 'contractLocked';end if;
 end if;
 for item in select value from jsonb_array_elements(p_items) loop
  select * into p from charm.products where products.id=(item->>'product_id')::bigint and active;
  if not found or item->>'unit' not in ('bottle','carton') then raise exception 'invalid';end if;
  if coalesce(item->>'quantity','') !~ '^\d+$' then raise exception 'invalidQuantity';end if;
  qty:=(item->>'quantity')::integer;if qty not between 1 and 100000 then raise exception 'invalidQuantity';end if;
  price:=charm.money(item->>'unit_price');v_total:=v_total+qty*price;
 end loop;
 if p_id is null then
  insert into charm.orders(submission_key,client_id,salesperson_id,submitted_by,total,due_date,status,customer_type,created_at,updated_at)
  values(p_key,p_client,c.salesperson_id,a,v_total,p_due,'draft',p_customer_type,now(),now()) returning orders.id into id;
 else
  select orders.id into id from charm.orders where orders.id=p_id and orders.status='draft' and charm.can_access(orders.salesperson_id) for update;
  if id is null then raise exception 'forbidden';end if;
  update charm.orders set client_id=p_client,total=v_total,due_date=p_due,customer_type=p_customer_type,updated_at=now() where orders.id=id;
  delete from charm.order_items where order_id=id;
 end if;
 for item in select value from jsonb_array_elements(p_items) loop
  select * into p from charm.products where products.id=(item->>'product_id')::bigint;
  insert into charm.order_items(order_id,product_id,product_description,unit,quantity,unit_price,line_total)
  values(id,p.id,concat(p.category,' ',p.capacity,' ',p.fragrance),item->>'unit',(item->>'quantity')::integer,(item->>'unit_price')::numeric,(item->>'quantity')::integer*(item->>'unit_price')::numeric);
 end loop;
 perform charm.audit(case when p_id is null then 'draft_created' else 'draft_updated' end,'orders',id);
 if p_id is null then return charm.finish(p_key,id);end if;return id;
end $$;

create or replace function charm.amend_order_contract(p_id bigint,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare o charm.orders;
begin
 perform charm.require_sales_writer();
 if coalesce(length(trim(p_reason)),0) not between 5 and 1000 then raise exception 'reasonRequired'; end if;
 select * into o from charm.orders where orders.id=p_id for update;
 if not found or not charm.can_access(o.salesperson_id) then raise exception 'forbidden'; end if;
 if o.status not in ('pending','rejected') and not (o.status='draft' and o.contract_status='submitted') then raise exception 'amendmentNotAllowed'; end if;
 update charm.orders set status='draft',contract_status='amendment_required',receipt_status='pending',updated_at=now() where orders.id=p_id;
 perform charm.audit('contract_amendment_requested','orders',p_id,jsonb_build_object('reason',trim(p_reason),'version',o.contract_version));
end $$;

drop function if exists charm.approve_order(bigint,boolean,text);
create function charm.approve_order(p_id bigint,p_confirm boolean,p_reason text default null,p_contract_reviewed boolean default false)
returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); o charm.orders;
begin
 if p_confirm is null then raise exception 'invalid'; end if;
 select * into o from charm.orders where id=p_id for update;
 if not found then raise exception 'notFound'; end if;
 if o.submitted_by=a or (o.submitted_by is null and o.salesperson_id=a) then raise exception 'selfApproval'; end if;
 if o.status<>'pending' then raise exception 'alreadyReviewed'; end if;
 if not p_confirm and coalesce(length(trim(p_reason)),0) not between 1 and 1000 then raise exception 'reasonRequired'; end if;
 if p_confirm then
  if o.contract_status<>'submitted' or o.contract_version<1 then raise exception 'contractNotSubmitted'; end if;
  if not exists(select 1 from charm.order_contract_versions v where v.order_id=p_id and v.version=o.contract_version and v.status='submitted') then raise exception 'contractNotSubmitted'; end if;
  if not exists(select 1 from charm.order_documents d where d.order_id=p_id and d.kind='contract') then raise exception 'contractDocumentRequired'; end if;
  if p_contract_reviewed is distinct from true then raise exception 'contractReviewRequired'; end if;
 end if;
 update charm.orders set status=case when p_confirm then 'confirmed' else 'rejected' end,
  contract_status=case when p_confirm then 'approved' else 'rejected' end,
  contract_approved_at=case when p_confirm then now() end,contract_approved_by=case when p_confirm then a end,
  confirmed_at=case when p_confirm then now() end,confirmed_by=case when p_confirm then a end,reason=p_reason,updated_at=now() where id=p_id;
 if p_confirm then update charm.order_contract_versions set status='approved' where order_id=p_id and version=o.contract_version; end if;
 if not p_confirm then update charm.order_contract_versions set status='rejected' where order_id=p_id and version=o.contract_version; end if;
 perform charm.audit(case when p_confirm then 'confirmed' else 'rejected' end,'orders',p_id,jsonb_build_object('contract_version',o.contract_version,'contract_reviewed',p_contract_reviewed));
end $$;

create or replace function charm.confirm_order_receipt(p_id bigint,p_notes text default null) returns void
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); o charm.orders;
begin
 if coalesce(length(p_notes),0)>2000 then raise exception 'invalid'; end if;
 select * into o from charm.orders where orders.id=p_id for update;
 if not found then raise exception 'notFound'; end if;
 if o.status<>'confirmed' or o.contract_status<>'approved' then raise exception 'receiptContractRequired'; end if;
 if o.receipt_status='received' then raise exception 'alreadyReceived'; end if;
 update charm.orders set receipt_status='received',received_at=now(),received_by=a,receipt_notes=nullif(trim(p_notes),''),updated_at=now() where orders.id=p_id;
 perform charm.audit('received','orders',p_id,jsonb_build_object('contract_version',o.contract_version));
end $$;

-- Preserve the metadata of contracts uploaded before this migration. Existing
-- orders are never deleted or rewritten beyond additive contract fields.
update charm.orders o set
 contract_reference=coalesce(o.contract_reference,'LEGACY-'||o.id),
 contract_signed_by=coalesce(o.contract_signed_by,'See uploaded signed contract'),
 contract_terms=coalesce(o.contract_terms,'Signed contract uploaded before the contract form was introduced.'),
 contract_submitted_at=coalesce(o.contract_submitted_at,o.created_at,now()),
 contract_submitted_by=coalesce(o.contract_submitted_by,o.submitted_by,o.salesperson_id),
 contract_version=greatest(o.contract_version,1),
 contract_status=case when o.status='confirmed' then 'approved' when o.status in ('rejected','cancelled') then 'rejected' else 'submitted' end,
 contract_approved_at=case when o.status='confirmed' then coalesce(o.confirmed_at,o.created_at,now()) end,
 contract_approved_by=case when o.status='confirmed' then o.confirmed_by end
where o.contract_path is not null and o.contract_status='draft';
insert into charm.order_documents(order_id,kind,storage_path,file_name,mime_type,size_bytes,page_count,document_key,contract_version,uploaded_by,uploaded_at)
select o.id,'contract',o.contract_path,substring(o.contract_path from '[^/]+$'),
 case when o.contract_path ilike '%.pdf' then 'application/pdf' when o.contract_path ilike '%.png' then 'image/png' when o.contract_path ilike '%.webp' then 'image/webp' else 'image/jpeg' end,
 null,null,gen_random_uuid(),greatest(o.contract_version,1),coalesce(o.submitted_by,o.salesperson_id),coalesce(o.contract_submitted_at,now())
from charm.orders o where o.contract_path is not null
 and not exists(select 1 from charm.order_documents d where d.order_id=o.id and d.storage_path=o.contract_path);
insert into charm.order_contract_versions(order_id,version,reference,signed_by,terms,customer_type,status,submitted_by,submitted_at,documents)
select o.id,o.contract_version,o.contract_reference,o.contract_signed_by,o.contract_terms,o.customer_type,
 case when o.contract_status='approved' then 'approved' when o.contract_status='rejected' then 'rejected' else 'submitted' end,
 o.contract_submitted_by,o.contract_submitted_at,
 (select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'name',d.file_name,'kind',d.kind,'mime',d.mime_type,'pages',d.page_count)),'[]'::jsonb) from charm.order_documents d where d.order_id=o.id)
from charm.orders o where o.contract_version>0 and not exists(select 1 from charm.order_contract_versions v where v.order_id=o.id and v.version=o.contract_version);
update charm.orders o set contract_file_count=(select count(*) from charm.order_documents d where d.order_id=o.id and d.kind='contract'),
 contract_page_count=(select coalesce(sum(coalesce(d.page_count,1)),0) from charm.order_documents d where d.order_id=o.id and d.kind='contract'),
 contract_file_name=(select d.file_name from charm.order_documents d where d.order_id=o.id and d.kind='contract' order by d.id limit 1);

-- Files remain private: reads require document metadata, writes only while drafting.
create or replace function charm.file_access(path text,writing boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare kind text:=split_part(path,'/',1); record_id bigint; owner bigint; status text; contract text;
begin
 if charm.actor() is null or split_part(path,'/',2) !~ '^\d+$' then return false; end if;
 record_id:=split_part(path,'/',2)::bigint;
 if kind='visits' then select salesperson_id into owner from charm.visits where visits.id=record_id;
 elsif kind='payments' then select o.salesperson_id,p.status into owner,status from charm.payments p join charm.orders o on o.id=p.order_id where p.id=record_id;
 elsif kind='orders' then select salesperson_id,orders.status,orders.contract_path into owner,status,contract from charm.orders where orders.id=record_id;
 else return false;end if;
 if kind='orders' then
  if writing then return status='draft' and owner is not null and coalesce(charm.can_access(owner),false); end if;
  return owner is not null and coalesce(charm.can_access(owner),false)
   and (contract=path or exists(select 1 from charm.order_documents d where d.order_id=record_id and d.storage_path=path));
 end if;
 if writing and kind='payments' and status<>'pending' then return false; end if;
 return owner is not null and coalesce(charm.can_access(owner),false);
end $$;

revoke execute on function charm.attach_order_contract(bigint,text),charm.save_order_contract(uuid,bigint,text,text,text,text),charm.add_order_document(uuid,bigint,text,text,text,text,bigint,integer),charm.remove_order_document(bigint,bigint),charm.submit_order_contract(uuid,bigint,boolean),charm.submit_order_draft(bigint),charm.amend_order_contract(bigint,text),charm.approve_order(bigint,boolean,text,boolean),charm.confirm_order_receipt(bigint,text) from public,anon,authenticated;
grant execute on function charm.save_order_contract(uuid,bigint,text,text,text,text),charm.add_order_document(uuid,bigint,text,text,text,text,bigint,integer),charm.remove_order_document(bigint,bigint),charm.submit_order_contract(uuid,bigint,boolean),charm.submit_order_draft(bigint),charm.amend_order_contract(bigint,text),charm.approve_order(bigint,boolean,text,boolean),charm.confirm_order_receipt(bigint,text) to authenticated;

commit;

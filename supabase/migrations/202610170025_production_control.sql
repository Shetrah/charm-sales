-- Production, formulation, inventory and laboratory controls.
begin;

create table charm.production_materials(
 id bigserial primary key,code text not null unique check(length(code) between 1 and 60),
 name text not null check(length(name) between 1 and 180),category text not null check(category in ('surfactant','builder','enzyme','perfume','dye','preservative','packaging','other')),
 base_unit text not null check(base_unit in ('kg','g','L','mL','unit')),
 purchase_unit text not null check(purchase_unit in ('drum','ton','kg','g','L','mL','unit','carton')),
 purchase_to_base numeric(18,6) not null check(purchase_to_base>0),reorder_point numeric(18,6) not null default 0 check(reorder_point>=0),
 hazard text not null default '',storage_instructions text not null default '',sds_url text,
 expiry_date date,retest_date date,active boolean not null default true,created_by bigint not null references charm.users(id),created_at timestamptz not null default now()
);
create table charm.production_formulas(
 id bigserial primary key,product_name text not null check(length(product_name) between 1 and 180),version text not null check(version ~ '^v[0-9]+\.[0-9]+$'),
 yield_liters numeric(18,6) not null check(yield_liters>0),status text not null default 'draft' check(status in ('draft','approved','retired')),
 revision_of bigint references charm.production_formulas(id),notes text not null default '',created_by bigint not null references charm.users(id),created_at timestamptz not null default now(),approved_by bigint references charm.users(id),approved_at timestamptz,
 unique(product_name,version)
);
create table charm.production_formula_items(
 id bigserial primary key,formula_id bigint not null references charm.production_formulas(id),material_id bigint references charm.production_materials(id),child_formula_id bigint references charm.production_formulas(id),
 quantity numeric(18,6) not null check(quantity>0),unit text not null check(unit in ('kg','g','L','mL','unit')),notes text not null default '',
 check((material_id is not null)::int+(child_formula_id is not null)::int=1)
);
create table charm.production_batches(
 id bigserial primary key,lot_number text not null unique default '',formula_id bigint not null references charm.production_formulas(id),
 target_liters numeric(18,6) not null check(target_liters>0),actual_liters numeric(18,6) check(actual_liters>=0),
 status text not null default 'mixing' check(status in ('mixing','qc_hold','released','rejected')),
 started_by bigint not null references charm.users(id),started_at timestamptz not null default now(),completed_at timestamptz,loss_notes text not null default '',
 expected_liters numeric(18,6) generated always as (target_liters) stored,
 loss_liters numeric(18,6) generated always as (case when actual_liters is null then null else greatest(target_liters-actual_liters,0) end) stored,
 yield_percent numeric(9,4) generated always as (case when actual_liters is null or target_liters=0 then null else round(actual_liters/target_liters*100,4) end) stored
);
create table charm.production_stock_movements(
 id bigserial primary key,material_id bigint not null references charm.production_materials(id),batch_id bigint references charm.production_batches(id),
 kind text not null check(kind in ('receipt','consumption','adjustment')),quantity_base numeric(18,6) not null check(quantity_base<>0),
 reference text not null default '',supplier_lot text not null default '',expiry_date date,retest_date date,notes text not null default '',actor_id bigint not null references charm.users(id),created_at timestamptz not null default now()
);
create table charm.production_quality_checks(
 id bigserial primary key,batch_id bigint not null references charm.production_batches(id),ph numeric(8,3) check(ph between 0 and 14),viscosity numeric(12,3) check(viscosity>=0),active_matter numeric(8,3) check(active_matter between 0 and 100),
 specific_gravity numeric(8,4) check(specific_gravity>0),color text not null default '',foam_result text not null default '',result text not null check(result in ('passed','failed')),
 notes text not null default '',tested_by bigint not null references charm.users(id),tested_at timestamptz not null default now()
);
create sequence charm.production_lot_seq;
create index production_material_active on charm.production_materials(active,name);
create index production_formula_product on charm.production_formulas(product_name,status,created_at desc);
create index production_formula_items_parent on charm.production_formula_items(formula_id);
create index production_batches_status on charm.production_batches(status,id desc);
create index production_batches_formula on charm.production_batches(formula_id,id desc);
create index production_stock_material on charm.production_stock_movements(material_id,id);
create index production_stock_batch on charm.production_stock_movements(batch_id) where batch_id is not null;
create index production_qc_batch on charm.production_quality_checks(batch_id,id desc);

create function charm.production_role() returns text language sql stable security definer set search_path='' as $$select role::text from charm.users where id=charm.actor()$$;
create function charm.production_admin() returns boolean language sql stable security definer set search_path='' as $$select coalesce(charm.production_role()='admin',false)$$;
create function charm.production_reader() returns boolean language sql stable security definer set search_path='' as $$select coalesce(charm.production_role() in ('admin','finance_officer'),false)$$;
create function charm.production_sds_access(p_path text,p_write boolean default false) returns boolean language plpgsql stable security definer set search_path='' as $$
declare material_id bigint;
begin
 if p_path !~ '^production/material/[0-9]+/[a-f0-9-]{36}\.pdf$' then return false;end if;
 material_id:=split_part(p_path,'/',3)::bigint;
 if not exists(select 1 from charm.production_materials where id=material_id) then return false;end if;
 if p_write then return charm.production_admin();end if;
 return charm.production_reader();
end $$;

create function charm.production_set_lot() returns trigger language plpgsql set search_path='' as $$
begin
 if new.lot_number='' then new.lot_number:='CHM-'||to_char(clock_timestamp() at time zone 'Africa/Nairobi','YYYYMMDD')||'-'||lpad(nextval('charm.production_lot_seq')::text,6,'0');end if;
 return new;
end $$;
create trigger production_batch_lot before insert on charm.production_batches for each row execute function charm.production_set_lot();
create function charm.production_formula_revision_guard() returns trigger language plpgsql set search_path='' as $$
begin
 if new.revision_of is not null and not exists(select 1 from charm.production_formulas parent where parent.id=new.revision_of and parent.product_name=new.product_name) then raise exception 'invalidRevision';end if;
 if tg_op='UPDATE' and old.status<>'draft' and (new.product_name<>old.product_name or new.version<>old.version or new.yield_liters<>old.yield_liters or new.revision_of is distinct from old.revision_of or new.notes<>old.notes or new.created_by<>old.created_by or new.created_at<>old.created_at) then raise exception 'formulaLocked';end if;
 return new;
end $$;
create trigger production_formula_revision before insert or update on charm.production_formulas for each row execute function charm.production_formula_revision_guard();

-- The material balance is the signed sum of the append-only movement ledger.
create function charm.production_stock_balance(p_material bigint) returns numeric language sql stable security definer set search_path='' as $$
 select coalesce(sum(quantity_base),0) from charm.production_stock_movements where material_id=p_material
$$;
create function charm.production_inventory_balances() returns table(material_id bigint,quantity numeric,below_reorder boolean) language sql stable security definer set search_path='' as $$
 select m.id,coalesce(sum(s.quantity_base),0),coalesce(sum(s.quantity_base),0)<m.reorder_point
 from charm.production_materials m left join charm.production_stock_movements s on s.material_id=m.id
 where charm.production_admin() or charm.production_reader()
 group by m.id,m.reorder_point
$$;
create function charm.production_convert(p_material bigint,p_quantity numeric,p_unit text) returns numeric language plpgsql stable security definer set search_path='' as $$
declare base text;
begin
 select base_unit into base from charm.production_materials where id=p_material;
 if base is null then raise exception 'notFound';end if;
 if base=p_unit then return p_quantity;end if;
 if base='kg' and p_unit='g' then return p_quantity/1000;end if;
 if base='g' and p_unit='kg' then return p_quantity*1000;end if;
 if base='L' and p_unit='mL' then return p_quantity/1000;end if;
 if base='mL' and p_unit='L' then return p_quantity*1000;end if;
 raise exception 'unitMismatch';
end $$;

create function charm.production_scaled_bom(p_formula bigint,p_target numeric) returns table(material_id bigint,code text,name text,unit text,quantity numeric) language plpgsql stable security definer set search_path='' as $$
begin
 if not charm.production_admin() then raise exception 'forbidden';end if;
 return query with recursive bom(formula_id,scale,path) as (
   select f.id,p_target/f.yield_liters,array[f.id]::bigint[] from charm.production_formulas f where f.id=p_formula and f.status='approved'
   union all
   select i.child_formula_id,b.scale*i.quantity/f.yield_liters,b.path||i.child_formula_id
   from bom b join charm.production_formula_items i on i.formula_id=b.formula_id join charm.production_formulas f on f.id=i.child_formula_id
   where i.child_formula_id is not null and f.status='approved' and not i.child_formula_id=any(b.path)
 )
 select m.id,m.code,m.name,m.base_unit,sum(charm.production_convert(m.id,i.quantity,i.unit)*b.scale)
 from bom b join charm.production_formula_items i on i.formula_id=b.formula_id join charm.production_materials m on m.id=i.material_id
 group by m.id,m.code,m.name,m.base_unit;
end $$;
create function charm.production_validate_formula_item() returns trigger language plpgsql security definer set search_path='' as $$
declare base text;
begin
 if tg_op='DELETE' then
   if not exists(select 1 from charm.production_formulas where id=old.formula_id and status='draft') then raise exception 'formulaLocked';end if;
   return old;
 end if;
 if tg_op='UPDATE' and (new.formula_id<>old.formula_id or not exists(select 1 from charm.production_formulas where id=old.formula_id and status='draft')) then raise exception 'formulaLocked';end if;
 if new.material_id is not null then
   select base_unit into base from charm.production_materials where id=new.material_id and active;
   if not found then raise exception 'materialInactive';end if;
   if not ((base in ('kg','g') and new.unit in ('kg','g')) or (base in ('L','mL') and new.unit in ('L','mL')) or (base='unit' and new.unit='unit')) then raise exception 'unitMismatch';end if;
 elsif new.unit<>'L' or not exists(select 1 from charm.production_formulas where id=new.child_formula_id and status='approved') then raise exception 'subFormulaNotApproved';
   if new.child_formula_id=new.formula_id then raise exception 'formulaCycle';end if;
 end if;
 if not exists(select 1 from charm.production_formulas where id=new.formula_id and status='draft') then raise exception 'formulaLocked';end if;
 return new;
end $$;
create trigger production_item_validate before insert or update or delete on charm.production_formula_items for each row execute function charm.production_validate_formula_item();
create function charm.production_formula_components_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare fid bigint; f_status text;
begin
 if tg_op='DELETE' then fid:=old.formula_id;else fid:=new.formula_id;end if;
 select status into f_status from charm.production_formulas where id=fid;
 if f_status<>'draft' or (tg_op='UPDATE' and old.formula_id<>new.formula_id) then raise exception 'formulaLocked';end if;
 if tg_op='DELETE' then return old;else return new;end if;
end $$;
create trigger production_formula_components_guard before insert or update or delete on charm.production_formula_items for each row execute function charm.production_formula_components_guard();
create function charm.production_formula_guard() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' and old.status<>'draft' then raise exception 'formulaLocked';end if;
 if tg_op='UPDATE' and old.status<>'draft' and (old.status<>'approved' or new.status not in ('approved','retired') or new.id<>old.id or new.product_name<>old.product_name or new.version<>old.version or new.yield_liters<>old.yield_liters or new.revision_of is distinct from old.revision_of or new.notes<>old.notes or new.created_by<>old.created_by or new.created_at<>old.created_at or (old.status='retired' and new.status<>'retired')) then raise exception 'formulaLocked';end if;
 if tg_op='UPDATE' and old.status='draft' and new.status not in ('draft','approved') then raise exception 'formulaLocked';end if;
 if tg_op='UPDATE' and old.status='draft' and new.status='approved' and (new.product_name<>old.product_name or new.version<>old.version or new.yield_liters<>old.yield_liters or new.revision_of is distinct from old.revision_of or new.notes<>old.notes or new.created_by<>old.created_by or new.created_at<>old.created_at) then raise exception 'formulaLocked';end if;
 if tg_op='DELETE' then return old;end if;
 if old.status='draft' and new.status='approved' then
   if not exists(select 1 from charm.production_formula_items where formula_id=old.id) then raise exception 'formulaEmpty';end if;
   if exists(select 1 from charm.production_formula_items i where i.formula_id=old.id and ((i.material_id is not null and not exists(select 1 from charm.production_materials m where m.id=i.material_id and m.active)) or (i.child_formula_id is not null and not exists(select 1 from charm.production_formulas f where f.id=i.child_formula_id and f.status='approved')))) then raise exception 'invalidFormulaItem';end if;
   new.approved_by:=charm.require_actor();new.approved_at:=now();
 end if;
 if old.status='approved' and new.status='retired' and exists(select 1 from charm.production_formula_items i join charm.production_formulas f on f.id=i.formula_id where i.child_formula_id=old.id and f.status='approved') then raise exception 'formulaInUse';end if;
 return new;
end $$;
create trigger production_formula_guard before update or delete on charm.production_formulas for each row execute function charm.production_formula_guard();
create function charm.production_batch_release_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='released' and (not exists(select 1 from charm.production_quality_checks q where q.batch_id=new.id and q.result='passed') or new.actual_liters is null) then raise exception 'qualityGateRequired';end if;
 return new;
end $$;
create trigger production_batch_quality_gate before insert or update on charm.production_batches for each row execute function charm.production_batch_release_guard();
create function charm.production_batch_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'batchLocked';end if;
 if tg_op='UPDATE' and new.status is distinct from old.status and not ((old.status='mixing' and new.status='qc_hold') or (old.status='qc_hold' and new.status in ('released','rejected'))) then raise exception 'batchLocked';end if;
 if new.id<>old.id or new.lot_number<>old.lot_number or new.formula_id<>old.formula_id or new.target_liters<>old.target_liters or new.started_by<>old.started_by or new.started_at<>old.started_at or old.status in ('released','rejected') then raise exception 'batchLocked';end if;
 if old.status='qc_hold' and (new.actual_liters is distinct from old.actual_liters or new.loss_notes is distinct from old.loss_notes or new.completed_at is distinct from old.completed_at) then raise exception 'batchLocked';end if;
 return new;
end $$;
create trigger production_batch_immutable_fields before update or delete on charm.production_batches for each row execute function charm.production_batch_guard();
create function charm.production_stock_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op<>'INSERT' then raise exception 'stockLedgerImmutable';end if;
 perform pg_advisory_xact_lock(new.material_id);
 if new.kind='receipt' and new.quantity_base<=0 then raise exception 'invalidReceipt';end if;
 if new.kind='adjustment' or (new.kind='consumption' and (new.quantity_base>=0 or new.batch_id is null)) then raise exception 'invalidMovement';end if;
 if new.kind='consumption' and new.reference not like 'receipt:%' then raise exception 'invalidLot';end if;
 if new.kind='consumption' and not exists(select 1 from charm.production_stock_movements receipt where receipt.id=substring(new.reference from 9)::bigint and receipt.material_id=new.material_id and receipt.kind='receipt' and receipt.supplier_lot=new.supplier_lot and receipt.expiry_date is not distinct from new.expiry_date and receipt.retest_date is not distinct from new.retest_date and (receipt.expiry_date is null or receipt.expiry_date>=(now() at time zone 'Africa/Nairobi')::date) and (receipt.retest_date is null or receipt.retest_date>=(now() at time zone 'Africa/Nairobi')::date)) then raise exception 'invalidLot';end if;
 if new.kind='receipt' and (new.batch_id is not null or new.supplier_lot='') then raise exception 'invalidReceipt';end if;
 if new.kind='consumption' and exists(select 1 from charm.production_stock_movements receipt where receipt.id=substring(new.reference from 9)::bigint and receipt.material_id=new.material_id and receipt.quantity_base+coalesce((select sum(c.quantity_base) from charm.production_stock_movements c where c.reference='receipt:'||receipt.id::text and c.kind='consumption'),0)+new.quantity_base<0) then raise exception 'insufficientStock';end if;
 return new;
end $$;
create trigger production_stock_ledger_guard before insert or update or delete on charm.production_stock_movements for each row execute function charm.production_stock_guard();

create or replace function charm.notify_workspace_activity() returns trigger
language plpgsql security definer set search_path='' as $$
declare payload jsonb:=to_jsonb(new);previous jsonb:=case when tg_op='UPDATE' then to_jsonb(old) else '{}'::jsonb end;
 actor bigint:=charm.actor();owner_id bigint;record_id bigint;state text;recipient record;event_name text;event_token text;
begin
 record_id:=nullif(payload->>'id','')::bigint;
 owner_id:=coalesce(nullif(payload->>'salesperson_id','')::bigint,nullif(payload->>'submitted_by','')::bigint,nullif(payload->>'user_id','')::bigint,nullif(payload->>'owner_id','')::bigint,nullif(payload->>'created_by','')::bigint,nullif(payload->>'started_by','')::bigint,nullif(payload->>'actor_id','')::bigint);
 state:=coalesce(payload->>'status','');
 if tg_op='UPDATE' and (tg_table_name in ('clients','visits','reports','workdays') or coalesce(previous->>'status','')=state) then return new;end if;
 event_name:=case when tg_op='INSERT' then tg_table_name||'_submitted' else coalesce(nullif(state,''),tg_table_name||'_updated') end;
 event_token:=tg_table_name||':'||record_id||':'||tg_op||':'||coalesce(nullif(state,''),to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS'));
 for recipient in select id,role::text as role from charm.users where active and id<>coalesce(actor,-1)
   and ((case when tg_table_name in ('production_materials','production_formulas','production_batches') then role::text=any(array['admin','finance_officer']) else role::text=any(array['admin','finance_officer','salesperson']) end) or (owner_id is not null and id=owner_id)
        or (tg_table_name='production_batches' and state='released' and role='salesperson'))
 loop
   if tg_table_name in ('payments','expenses') and recipient.role not in ('admin','finance_officer') and recipient.id<>owner_id then continue;end if;
   insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
   values(recipient.id,null,event_name,event_token||':'||recipient.id,tg_table_name,record_id) on conflict do nothing;
 end loop;
 return new;
end $$;
drop trigger if exists workspace_activity_notify on charm.production_materials;
create trigger workspace_activity_notify after insert or update on charm.production_materials for each row execute function charm.notify_workspace_activity();
drop trigger if exists workspace_activity_notify on charm.production_formulas;
create trigger workspace_activity_notify after insert or update on charm.production_formulas for each row execute function charm.notify_workspace_activity();
drop trigger if exists workspace_activity_notify on charm.production_batches;
create trigger workspace_activity_notify after insert or update on charm.production_batches for each row execute function charm.notify_workspace_activity();
revoke execute on function charm.notify_workspace_activity() from public,anon,authenticated;
create function charm.production_reorder_notify() returns trigger language plpgsql security definer set search_path='' as $$
declare available numeric;threshold numeric;recipient record;actor bigint:=charm.actor();
begin
 select m.reorder_point into threshold from charm.production_materials m where m.id=new.material_id;
 available:=charm.production_stock_balance(new.material_id);
 if available<threshold and available-new.quantity_base>=threshold then
   for recipient in select id from charm.users where active and id<>coalesce(actor,-1) and role in ('admin','finance_officer') loop
     insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id)
     values(recipient.id,null,'reorderNeeded','reorder:'||new.material_id||':'||new.id,'production_materials',new.material_id) on conflict do nothing;
   end loop;
 end if;
 return new;
end $$;
create trigger production_reorder_alert after insert on charm.production_stock_movements for each row execute function charm.production_reorder_notify();

create function charm.production_start_batch(p_formula bigint,p_target numeric) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); batch_id bigint; item record;
begin
 if not charm.production_admin() then raise exception 'forbidden';end if;
 if p_target<=0 then raise exception 'invalid';end if;
 if not exists(select 1 from charm.production_formulas where id=p_formula and status='approved') then raise exception 'formulaNotApproved';end if;
 for item in select distinct b.material_id from charm.production_scaled_bom(p_formula,p_target) b order by b.material_id loop perform pg_advisory_xact_lock(item.material_id);end loop;
 if not exists(select 1 from charm.production_formula_items where formula_id=p_formula) then raise exception 'formulaEmpty';end if;
 for item in select * from charm.production_scaled_bom(p_formula,p_target) order by material_id loop
   if charm.production_stock_balance(item.material_id)<item.quantity then raise exception 'insufficientStock';end if;
 end loop;
 insert into charm.production_batches(formula_id,target_liters,started_by) values(p_formula,p_target,a) returning id into batch_id;
 for item in select * from charm.production_scaled_bom(p_formula,p_target) order by material_id loop
  declare lot record; remaining numeric:=item.quantity; take_quantity numeric;begin
    for lot in select receipt.id,receipt.reference,receipt.supplier_lot,receipt.expiry_date,receipt.retest_date,
       receipt.quantity_base+coalesce(sum(consume.quantity_base),0) available
      from charm.production_stock_movements receipt left join charm.production_stock_movements consume on consume.reference='receipt:'||receipt.id::text and consume.kind='consumption'
      where receipt.material_id=item.material_id and receipt.kind='receipt' and (receipt.expiry_date is null or receipt.expiry_date>=(now() at time zone 'Africa/Nairobi')::date) and (receipt.retest_date is null or receipt.retest_date>=(now() at time zone 'Africa/Nairobi')::date)
      group by receipt.id,receipt.reference,receipt.supplier_lot,receipt.expiry_date,receipt.retest_date,receipt.quantity_base
      having receipt.quantity_base+coalesce(sum(consume.quantity_base),0)>0 order by receipt.expiry_date nulls last,receipt.retest_date nulls last,receipt.id loop
     exit when remaining<=0;take_quantity:=least(remaining,lot.available);
     insert into charm.production_stock_movements(material_id,batch_id,kind,quantity_base,reference,supplier_lot,expiry_date,retest_date,notes,actor_id)
     values(item.material_id,batch_id,'consumption',-take_quantity,'receipt:'||lot.id::text,lot.supplier_lot,lot.expiry_date,lot.retest_date,'Batch '||batch_id||' FIFO lot consumption',a);
     remaining:=remaining-take_quantity;
    end loop;
    if remaining>0 then raise exception 'insufficientValidStock';end if;
   end;
 end loop;
 return batch_id;
end $$;

create function charm.production_record_qc(p_batch bigint,p_ph numeric,p_viscosity numeric,p_active_matter numeric,p_specific_gravity numeric,p_color text,p_foam text,p_result text,p_notes text default '') returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();check_id bigint;
begin
 if not charm.production_admin() then raise exception 'forbidden';end if;
 if not exists(select 1 from charm.production_batches where id=p_batch and status='qc_hold') then raise exception 'batchNotReadyForQc';end if;
 if p_ph is null or p_viscosity is null or p_active_matter is null or p_specific_gravity is null or coalesce(trim(p_color),'')='' or coalesce(trim(p_foam),'')='' then raise exception 'qualityDataRequired';end if;
 insert into charm.production_quality_checks(batch_id,ph,viscosity,active_matter,specific_gravity,color,foam_result,result,notes,tested_by)
 values(p_batch,p_ph,p_viscosity,p_active_matter,p_specific_gravity,p_color,p_foam,p_result,p_notes,a) returning id into check_id;
 update charm.production_batches set status=case when p_result='passed' then 'released' else 'rejected' end,completed_at=now() where id=p_batch;
 return check_id;
end $$;

create function charm.production_receive_stock(p_material bigint,p_purchase_quantity numeric,p_reference text,p_notes text default '',p_supplier_lot text default '',p_expiry date default null,p_retest date default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();movement_id bigint; converted numeric;
begin
 if not charm.production_admin() then raise exception 'forbidden';end if;
 if p_purchase_quantity<=0 then raise exception 'invalid';end if;
 select p_purchase_quantity*purchase_to_base into converted from charm.production_materials where id=p_material and active;
 if converted is null then raise exception 'notFound';end if;
 insert into charm.production_stock_movements(material_id,kind,quantity_base,reference,supplier_lot,expiry_date,retest_date,notes,actor_id) values(p_material,'receipt',converted,p_reference,coalesce(p_supplier_lot,''),p_expiry,p_retest,p_notes,a) returning id into movement_id;
 return movement_id;
end $$;

do $$ declare t text;begin
 foreach t in array array['production_materials','production_formulas','production_formula_items','production_batches','production_stock_movements','production_quality_checks'] loop
  execute format('alter table charm.%I enable row level security',t);
  execute format('revoke all on charm.%I from public,anon,authenticated',t);
  execute format('grant select on charm.%I to authenticated',t);
 end loop;
end $$;
create policy production_material_read on charm.production_materials for select to authenticated using(charm.production_admin() or charm.production_reader());
create policy production_formula_read on charm.production_formulas for select to authenticated using(charm.production_admin() or charm.production_reader() or (charm.production_role()='salesperson' and (status='approved' or exists(select 1 from charm.production_batches b where b.formula_id=id and b.status='released'))));
create policy production_items_read on charm.production_formula_items for select to authenticated using(charm.production_admin());
create policy production_batch_read on charm.production_batches for select to authenticated using(charm.production_admin() or charm.production_reader() or (charm.production_role()='salesperson' and status='released'));
create policy production_stock_read on charm.production_stock_movements for select to authenticated using(charm.production_admin() or charm.production_reader());
create policy production_qc_read on charm.production_quality_checks for select to authenticated using(charm.production_admin() or charm.production_reader() or exists(select 1 from charm.production_batches b where b.id=batch_id and b.status='released'));

grant usage,select on sequence charm.production_lot_seq,charm.production_materials_id_seq,charm.production_formulas_id_seq,charm.production_formula_items_id_seq,charm.production_batches_id_seq,charm.production_stock_movements_id_seq,charm.production_quality_checks_id_seq to authenticated;
grant usage on schema charm to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('charm-private','charm-private',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists charm_files_read on storage.objects;
create policy charm_files_read on storage.objects for select to authenticated using(bucket_id='charm-private' and (charm.file_access(name) or charm.production_sds_access(name,false) or (charm.finance_reader() and split_part(name,'/',1)='payments' and split_part(name,'/',2) ~ '^\d+$' and exists(select 1 from charm.payments where id=split_part(name,'/',2)::bigint))));
drop policy if exists charm_files_insert on storage.objects;
create policy charm_files_insert on storage.objects for insert to authenticated with check(bucket_id='charm-private' and (charm.file_access(name,true) or charm.production_sds_access(name,true)));
grant insert,update,delete on charm.production_materials,charm.production_formulas,charm.production_formula_items,charm.production_batches,charm.production_stock_movements,charm.production_quality_checks to authenticated;
create policy production_material_admin_write on charm.production_materials for all to authenticated using(charm.production_admin()) with check(charm.production_admin());
create policy production_formula_admin_write on charm.production_formulas for all to authenticated using(charm.production_admin()) with check(charm.production_admin());
create policy production_items_admin_write on charm.production_formula_items for all to authenticated using(charm.production_admin()) with check(charm.production_admin());
create policy production_batch_admin_write on charm.production_batches for all to authenticated using(charm.production_admin()) with check(charm.production_admin());
create policy production_stock_admin_write on charm.production_stock_movements for insert to authenticated with check(charm.production_admin());
create policy production_qc_admin_write on charm.production_quality_checks for insert to authenticated with check(charm.production_admin());

grant execute on function charm.production_start_batch(bigint,numeric),charm.production_record_qc(bigint,numeric,numeric,numeric,numeric,text,text,text,text),charm.production_receive_stock(bigint,numeric,text,text,text,date,date) to authenticated;
revoke execute on function charm.production_role(),charm.production_admin(),charm.production_reader(),charm.production_sds_access(text,boolean),charm.production_stock_balance(bigint),charm.production_inventory_balances(),charm.production_convert(bigint,numeric,text),charm.production_scaled_bom(bigint,numeric),charm.production_start_batch(bigint,numeric),charm.production_record_qc(bigint,numeric,numeric,numeric,numeric,text,text,text,text),charm.production_receive_stock(bigint,numeric,text,text,text,date,date),charm.production_reorder_notify(),charm.production_set_lot(),charm.production_formula_revision_guard(),charm.production_formula_components_guard(),charm.production_formula_guard(),charm.production_batch_release_guard(),charm.production_batch_guard(),charm.production_stock_guard(),charm.production_validate_formula_item() from public,anon,authenticated;
grant execute on function charm.production_start_batch(bigint,numeric),charm.production_record_qc(bigint,numeric,numeric,numeric,numeric,text,text,text,text),charm.production_receive_stock(bigint,numeric,text,text,text,date,date),charm.production_role(),charm.production_admin(),charm.production_reader(),charm.production_inventory_balances(),charm.production_scaled_bom(bigint,numeric),charm.production_sds_access(text,boolean) to authenticated;
commit;

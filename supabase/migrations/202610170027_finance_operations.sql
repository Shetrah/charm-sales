-- Finance operations: batch cost, purchase matching, invoicing, tax and classified revenue/expense.
begin;
create table charm.finance_invoice_settings(id boolean primary key default true check(id),tax_rate numeric(7,4) not null default 0 check(tax_rate between 0 and 1),credit_terms_days integer not null default 0 check(credit_terms_days between 0 and 365),updated_by bigint references charm.users(id),updated_at timestamptz not null default now());
insert into charm.finance_invoice_settings(id) values(true);
create table charm.finance_batch_costs(
 id bigserial primary key,batch_id bigint not null references charm.production_batches(id),utilities numeric(14,2) not null default 0 check(utilities>=0),direct_labor numeric(14,2) not null default 0 check(direct_labor>=0),tank_hours numeric(12,3) not null default 0 check(tank_hours>=0),tank_hour_rate numeric(14,2) not null default 0 check(tank_hour_rate>=0),filling_hours numeric(12,3) not null default 0 check(filling_hours>=0),filling_hour_rate numeric(14,2) not null default 0 check(filling_hour_rate>=0),waste_cost numeric(14,2) not null default 0 check(waste_cost>=0),coproduct_recovery numeric(14,2) not null default 0 check(coproduct_recovery>=0),notes text not null default '',recorded_by bigint not null references charm.users(id),created_at timestamptz not null default now(),unique(batch_id));
create table charm.finance_batch_cost_lines(
 id bigserial primary key,batch_cost_id bigint not null references charm.finance_batch_costs(id),material_id bigint references charm.production_materials(id),cost_type text not null check(cost_type in ('chemical','primary_packaging','secondary_packaging','import_duty','other')),standard_quantity numeric(18,6) not null default 0 check(standard_quantity>=0),actual_quantity numeric(18,6) not null default 0 check(actual_quantity>=0),unit text not null default '',unit_cost numeric(14,4) not null default 0 check(unit_cost>=0),description text not null default '',check((material_id is not null and cost_type in ('chemical','primary_packaging','secondary_packaging')) or material_id is null));
create table charm.finance_purchase_orders(
 id bigserial primary key,po_number text not null unique,supplier_id bigint not null references charm.finance_payees(id),status text not null default 'draft' check(status in ('draft','ordered','part_received','received','matched','cancelled')),currency text not null default 'KES',created_by bigint not null references charm.users(id),created_at timestamptz not null default now(),ordered_at timestamptz);
create table charm.finance_purchase_order_lines(
 id bigserial primary key,po_id bigint not null references charm.finance_purchase_orders(id),material_id bigint not null references charm.production_materials(id),quantity numeric(18,6) not null check(quantity>0),purchase_unit text not null,unit_price numeric(14,4) not null check(unit_price>=0));
create table charm.finance_goods_receipts(
 id bigserial primary key,grn_number text not null unique,po_id bigint not null references charm.finance_purchase_orders(id),status text not null default 'pending_qc' check(status in ('pending_qc','approved','rejected')),weight_ticket text not null default '',weighbridge_weight numeric(18,6) check(weighbridge_weight>=0),received_by bigint not null references charm.users(id),qc_by bigint references charm.users(id),qc_at timestamptz,notes text not null default '',created_at timestamptz not null default now());
create table charm.finance_goods_receipt_lines(
 id bigserial primary key,grn_id bigint not null references charm.finance_goods_receipts(id),po_line_id bigint not null references charm.finance_purchase_order_lines(id),received_quantity numeric(18,6) not null check(received_quantity>0),accepted_quantity numeric(18,6) not null default 0 check(accepted_quantity>=0),unit text not null,material_lot text not null default '',expiry_date date,retest_date date,unique(grn_id,po_line_id));
create table charm.finance_supplier_invoices(
 id bigserial primary key,invoice_number text not null,supplier_id bigint not null references charm.finance_payees(id),po_id bigint not null references charm.finance_purchase_orders(id),grn_id bigint not null references charm.finance_goods_receipts(id),request_id bigint references charm.finance_requests(id),currency text not null default 'KES',subtotal numeric(14,2) not null check(subtotal>=0),tax_amount numeric(14,2) not null default 0 check(tax_amount>=0),duty_amount numeric(14,2) not null default 0 check(duty_amount>=0),status text not null default 'pending_match' check(status in ('pending_match','matched','payment_requested','paid','rejected')),document_path text not null default '',submitted_by bigint not null references charm.users(id),reviewed_by bigint references charm.users(id),created_at timestamptz not null default now(),unique(supplier_id,invoice_number));
create table charm.finance_sales_invoices(
 id bigserial primary key,invoice_number text not null unique,order_id bigint not null references charm.orders(id),client_id bigint not null references charm.clients(id),batch_lot text,subtotal numeric(14,2) not null check(subtotal>=0),tax_rate numeric(7,4) not null default 0 check(tax_rate between 0 and 1),tax_amount numeric(14,2) not null default 0 check(tax_amount>=0),total numeric(14,2) not null check(total>=0),etims_control text not null default '',etims_status text not null default 'not_submitted' check(etims_status in ('not_submitted','queued','submitted','accepted','rejected','unavailable')),etims_response jsonb not null default '{}',credit_terms_days integer not null default 0 check(credit_terms_days between 0 and 365),due_date date not null,status text not null default 'issued' check(status in ('issued','paid','void')),issued_by bigint not null references charm.users(id),issued_at timestamptz not null default now(),unique(order_id));
create table charm.finance_operating_entries(
 id bigserial primary key,direction text not null check(direction in ('revenue','expense')),category text not null check(category in ('operational','financial','other','sales','tax','duty')),amount numeric(14,2) not null check(amount>0),occurred_on date not null,description text not null,reference text not null,invoice_id bigint references charm.finance_sales_invoices(id),account_id bigint references charm.finance_accounts(id),created_by bigint not null references charm.users(id),created_at timestamptz not null default now(),unique(direction,reference));
create index finance_batch_cost_lot on charm.finance_batch_costs(batch_id);
create index finance_purchase_status on charm.finance_supplier_invoices(status,created_at desc);
create index finance_sales_invoice_due on charm.finance_sales_invoices(status,due_date);
create index finance_operating_date on charm.finance_operating_entries(occurred_on,direction,category);

create function charm.finance_save_batch_cost(p_batch bigint,p_utilities numeric,p_labor numeric,p_tank_hours numeric,p_tank_rate numeric,p_fill_hours numeric,p_fill_rate numeric,p_waste numeric,p_recovery numeric,p_lines jsonb,p_notes text default '') returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();cid bigint;i jsonb;actual numeric;standard numeric;begin
 if not charm.finance_reader() or not exists(select 1 from charm.production_batches where id=p_batch and status in ('qc_hold','released','rejected')) then raise exception 'forbidden';end if;
 if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)>500 then raise exception 'invalid';end if;
 insert into charm.finance_batch_costs(batch_id,utilities,direct_labor,tank_hours,tank_hour_rate,filling_hours,filling_hour_rate,waste_cost,coproduct_recovery,notes,recorded_by) values(p_batch,p_utilities,p_labor,p_tank_hours,p_tank_rate,p_fill_hours,p_fill_rate,p_waste,p_recovery,coalesce(p_notes,''),a) on conflict(batch_id) do update set utilities=excluded.utilities,direct_labor=excluded.direct_labor,tank_hours=excluded.tank_hours,tank_hour_rate=excluded.tank_hour_rate,filling_hours=excluded.filling_hours,filling_hour_rate=excluded.filling_hour_rate,waste_cost=excluded.waste_cost,coproduct_recovery=excluded.coproduct_recovery,notes=excluded.notes returning id into cid;
 delete from charm.finance_batch_cost_lines where batch_cost_id=cid;
 for i in select value from jsonb_array_elements(p_lines) loop
  actual:=coalesce((i->>'actual_quantity')::numeric,0);standard:=coalesce((i->>'standard_quantity')::numeric,0);
  insert into charm.finance_batch_cost_lines(batch_cost_id,material_id,cost_type,standard_quantity,actual_quantity,unit,unit_cost,description) values(cid,nullif(i->>'material_id','')::bigint,i->>'cost_type',standard,actual,coalesce(i->>'unit',''),coalesce((i->>'unit_cost')::numeric,0),coalesce(i->>'description',''));
 end loop;
 perform charm.audit('batchCostUpdated','finance_batch_costs',cid,jsonb_build_object('batch_id',p_batch,'utilities',p_utilities,'labor',p_labor,'waste',p_waste));
 insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) select u.id,null,'batchCostReady','batch-cost:'||p_batch||':'||cid||':'||u.id,'production_batches',p_batch from charm.users u where u.active and u.role in ('admin','finance_officer','finance_manager') and u.id<>a on conflict do nothing;
 return cid;
end$$;

create function charm.finance_create_purchase_order(p_supplier bigint,p_number text,p_currency text,p_lines jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();pid bigint;i jsonb;begin
 if charm.finance_role() not in ('admin','finance_officer','finance_manager') then raise exception 'forbidden';end if;
 if coalesce(length(trim(p_number)),0) not between 1 and 80 or p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines) not between 1 and 300 or not exists(select 1 from charm.finance_payees where id=p_supplier and staff_id is null) then raise exception 'invalid';end if;
 insert into charm.finance_purchase_orders(po_number,supplier_id,currency,created_by,ordered_at,status) values(trim(p_number),p_supplier,coalesce(nullif(p_currency,''),'KES'),a,now(),'ordered') returning id into pid;
 for i in select value from jsonb_array_elements(p_lines) loop insert into charm.finance_purchase_order_lines(po_id,material_id,quantity,purchase_unit,unit_price) values(pid,(i->>'material_id')::bigint,(i->>'quantity')::numeric,i->>'unit',(i->>'unit_price')::numeric);end loop;
 perform charm.audit('purchaseOrderCreated','finance_purchase_orders',pid,jsonb_build_object('po_number',p_number,'supplier',p_supplier));
 insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) select u.id,null,'purchaseOrderNeedsGRN','purchase-order:'||pid||':'||u.id,'finance_purchase_orders',pid from charm.users u where u.active and u.role in ('admin','finance_officer','finance_manager') and u.id<>a on conflict do nothing;return pid;
end$$;
create function charm.finance_receive_purchase(p_po bigint,p_grn_number text,p_ticket text,p_weight numeric,p_lines jsonb,p_notes text default '') returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();gid bigint;i jsonb;begin
 if not charm.finance_reader() or coalesce(length(trim(p_grn_number)),0) not between 1 and 80 or coalesce(length(trim(p_ticket)),0)>200 or p_weight<0 or p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines) not between 1 and 300 then raise exception 'invalid';end if;
 if not exists(select 1 from charm.finance_purchase_orders where id=p_po and status in ('ordered','part_received')) then raise exception 'purchaseOrderLocked';end if;
 insert into charm.finance_goods_receipts(grn_number,po_id,weight_ticket,weighbridge_weight,received_by,notes) values(trim(p_grn_number),p_po,coalesce(p_ticket,''),p_weight,a,coalesce(p_notes,'')) returning id into gid;
 for i in select value from jsonb_array_elements(p_lines) loop insert into charm.finance_goods_receipt_lines(grn_id,po_line_id,received_quantity,accepted_quantity,unit,material_lot,expiry_date,retest_date) values(gid,(i->>'po_line_id')::bigint,(i->>'quantity')::numeric,coalesce((i->>'accepted_quantity')::numeric,0),i->>'unit',coalesce(i->>'lot',''),nullif(i->>'expiry','')::date,nullif(i->>'retest','')::date);end loop;
 perform charm.audit('goodsReceived','finance_goods_receipts',gid,jsonb_build_object('po_id',p_po,'weight_ticket',p_ticket,'weight',p_weight));return gid;
end$$;
create function charm.finance_approve_grn(p_grn bigint,p_approve boolean,p_reason text default '') returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();g charm.finance_goods_receipts;i record;remaining numeric;received numeric;begin
 if charm.finance_role() not in ('admin','finance_officer','finance_manager') then raise exception 'forbidden';end if;
 select * into g from charm.finance_goods_receipts where id=p_grn for update;if g.id is null or g.status<>'pending_qc' then raise exception 'financeLocked';end if;
 if p_approve is distinct from true then update charm.finance_goods_receipts set status='rejected',qc_by=a,qc_at=now(),notes=concat_ws(E'\\n',notes,p_reason) where id=p_grn;return;end if;
 for i in select l.*,p.material_id,p.purchase_unit,p.quantity ordered from charm.finance_goods_receipt_lines l join charm.finance_purchase_order_lines p on p.id=l.po_line_id where l.grn_id=p_grn for update loop
  if i.accepted_quantity<=0 or i.accepted_quantity>i.received_quantity or i.received_quantity>i.ordered then raise exception 'grnQuantityMismatch';end if;
  insert into charm.production_stock_movements(material_id,kind,quantity_base,reference,supplier_lot,expiry_date,retest_date,notes,actor_id) values(i.material_id,'receipt',i.accepted_quantity*(select purchase_to_base from charm.production_materials where id=i.material_id),'grn:'||g.grn_number,coalesce(nullif(i.material_lot,''),'GRN-'||g.grn_number||'-'||i.id::text),i.expiry_date,i.retest_date,'QC approved goods receipt; weight ticket '||g.weight_ticket,a);
 end loop;
 if not exists(select 1 from charm.finance_goods_receipt_lines where grn_id=p_grn and accepted_quantity>0) then raise exception 'grnEmpty';end if;
 update charm.finance_goods_receipts set status='approved',qc_by=a,qc_at=now() where id=p_grn;
 update charm.finance_purchase_orders set status='part_received' where id=g.po_id;
 perform charm.audit('goodsReceiptQcApproved','finance_goods_receipts',p_grn,jsonb_build_object('po_id',g.po_id,'weight_ticket',g.weight_ticket));
 insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) select u.id,null,'grnQualityApproved','grn-approved:'||p_grn||':'||u.id,'finance_goods_receipts',p_grn from charm.users u where u.active and u.role in ('admin','finance_officer','finance_manager') and u.id<>a on conflict do nothing;
end$$;
create function charm.finance_submit_supplier_invoice(p_po bigint,p_grn bigint,p_invoice_number text,p_subtotal numeric,p_tax numeric,p_duty numeric,p_currency text,p_document text) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();g charm.finance_goods_receipts;pid bigint;supplier bigint;begin
 if charm.finance_role() not in ('admin','finance_officer','finance_manager') then raise exception 'forbidden';end if;
 select * into g from charm.finance_goods_receipts where id=p_grn and po_id=p_po and status='approved';if not found then raise exception 'grnQcRequired';end if;
 select supplier_id into supplier from charm.finance_purchase_orders where id=p_po and status in ('part_received','received');if not found then raise exception 'purchaseOrderLocked';end if;
 if coalesce(length(trim(p_invoice_number)),0) not between 1 and 100 or p_subtotal<0 or p_tax<0 or p_duty<0 then raise exception 'invalid';end if;
 insert into charm.finance_supplier_invoices(invoice_number,supplier_id,po_id,grn_id,currency,subtotal,tax_amount,duty_amount,document_path,submitted_by) values(trim(p_invoice_number),supplier,p_po,p_grn,coalesce(nullif(p_currency,''),'KES'),p_subtotal,p_tax,p_duty,coalesce(p_document,''),a) returning id into pid;
 perform charm.audit('supplierInvoiceSubmitted','finance_supplier_invoices',pid,jsonb_build_object('po_id',p_po,'grn_id',p_grn,'invoice',p_invoice_number,'tax',p_tax,'duty',p_duty));return pid;
end$$;
create function charm.finance_match_supplier_invoice(p_invoice bigint,p_decision text,p_reason text default '') returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();i charm.finance_supplier_invoices;req bigint;begin
 if charm.finance_role() not in ('admin','finance_officer','finance_manager') then raise exception 'forbidden';end if;
 select * into i from charm.finance_supplier_invoices where id=p_invoice for update;if i.id is null or i.status<>'pending_match' then raise exception 'financeLocked';end if;
 if p_decision<>'matched' then update charm.finance_supplier_invoices set status='rejected',reviewed_by=a where id=p_invoice;perform charm.audit('supplierInvoiceRejected','finance_supplier_invoices',p_invoice,jsonb_build_object('reason',p_reason));return null;end if;
 if not exists(select 1 from charm.finance_goods_receipts g where g.id=i.grn_id and g.po_id=i.po_id and g.status='approved') then raise exception 'threeWayMatchRequired';end if;
 if i.subtotal>(select coalesce(sum(gl.accepted_quantity*pol.unit_price),0) from charm.finance_goods_receipt_lines gl join charm.finance_purchase_order_lines pol on pol.id=gl.po_line_id where gl.grn_id=i.grn_id) then raise exception 'threeWayAmountMismatch';end if;
 insert into charm.finance_requests(owner_id,kind,payee_id,category_id,amount,purpose,required_date,accountability_due,status)
 values(a,'supplier',i.supplier_id,coalesce((select id from charm.finance_categories where name='Suppliers' and active),(select id from charm.finance_categories where name='Other' and active)),i.subtotal+i.tax_amount+i.duty_amount,'PO/GRN/Invoice '||i.invoice_number,(now() at time zone 'Africa/Nairobi')::date,(now() at time zone 'Africa/Nairobi')::date,'pending') returning id into req;
 update charm.finance_supplier_invoices set status='payment_requested',request_id=req,reviewed_by=a where id=p_invoice;
 perform charm.audit('threeWayMatchPassed','finance_supplier_invoices',p_invoice,jsonb_build_object('po_id',i.po_id,'grn_id',i.grn_id,'request_id',req));
 perform charm.finance_notify(req,'supplierInvoiceMatched','supplier-invoice:'||p_invoice,array['admin','finance_officer','finance_manager'],true);
 return req;
end$$;
create sequence charm.finance_sales_invoice_seq;
create function charm.finance_issue_sales_invoice(p_order bigint,p_tax_rate numeric,p_terms_days integer,p_batch_lot text,p_etims_control text default '') returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();o charm.orders;inv bigint;vsubtotal numeric;vtax numeric;client bigint;begin
 select * into o from charm.orders where id=p_order and status='confirmed';if not found then raise exception 'confirmedOrderRequired';end if;
 if not charm.finance_reader() or p_tax_rate not between 0 and 1 or p_terms_days not between 0 and 365 then raise exception 'invalid';end if;
 if p_batch_lot<>'' and not exists(select 1 from charm.production_batches where lot_number=p_batch_lot and status='released') then raise exception 'invalidLot';end if;
 select coalesce(sum(line_total),0) into vsubtotal from charm.order_items where order_id=p_order;vtax:=round(vsubtotal*p_tax_rate,2);client:=o.client_id;
 insert into charm.finance_sales_invoices(invoice_number,order_id,client_id,batch_lot,subtotal,tax_rate,tax_amount,total,etims_control,etims_status,credit_terms_days,due_date,issued_by) values('CHM-INV-'||to_char(clock_timestamp() at time zone 'Africa/Nairobi','YYYYMMDD')||'-'||lpad(nextval('charm.finance_sales_invoice_seq')::text,6,'0'),p_order,client,nullif(p_batch_lot,''),vsubtotal,p_tax_rate,vtax,vsubtotal+vtax,coalesce(p_etims_control,''),case when coalesce(p_etims_control,'')='' then 'unavailable' else 'queued' end,p_terms_days,(now() at time zone 'Africa/Nairobi')::date+p_terms_days,a) returning id into inv;
 insert into charm.finance_operating_entries(direction,category,amount,occurred_on,description,reference,invoice_id,created_by) values('revenue','sales',vsubtotal,(now() at time zone 'Africa/Nairobi')::date,'Order '||p_order,'invoice:'||inv,inv,a);
 if vtax>0 then insert into charm.finance_operating_entries(direction,category,amount,occurred_on,description,reference,invoice_id,created_by) values('revenue','tax',vtax,(now() at time zone 'Africa/Nairobi')::date,'Tax on order '||p_order,'invoice-tax:'||inv,inv,a);end if;
 perform charm.audit('salesInvoiceIssued','finance_sales_invoices',inv,jsonb_build_object('order_id',p_order,'batch_lot',p_batch_lot,'tax',vtax,'etims_control',p_etims_control));
 perform charm.finance_notify(null,'salesInvoiceIssued','sales-invoice:'||inv,array['admin','finance_officer'],false);
 return inv;
end$$;
create function charm.finance_record_etims(p_invoice bigint,p_control text,p_status text,p_response jsonb default '{}') returns void language plpgsql security definer set search_path='' as $$declare a bigint:=charm.require_actor();begin
 if not charm.finance_reader() or p_status not in ('queued','submitted','accepted','rejected','unavailable') then raise exception 'invalid';end if;
 update charm.finance_sales_invoices set etims_control=coalesce(nullif(p_control,''),etims_control),etims_status=p_status,etims_response=coalesce(p_response,'{}') where id=p_invoice and status<>'void';if not found then raise exception 'notFound';end if;
 perform charm.audit('eTimsStatus','finance_sales_invoices',p_invoice,jsonb_build_object('status',p_status,'control',p_control));
end$$;
create function charm.finance_record_operating_entry(p_direction text,p_category text,p_amount numeric,p_date date,p_description text,p_reference text,p_account bigint default null) returns bigint language plpgsql security definer set search_path='' as $$declare a bigint:=charm.require_actor();id bigint;begin
 if not charm.finance_reader() or p_direction not in ('revenue','expense') or p_category not in ('operational','financial','other','sales','tax','duty') or p_amount<=0 or p_date is null or coalesce(length(trim(p_description)),0) not between 1 and 2000 or coalesce(length(trim(p_reference)),0) not between 1 and 200 then raise exception 'invalid';end if;
 insert into charm.finance_operating_entries(direction,category,amount,occurred_on,description,reference,account_id,created_by) values(p_direction,p_category,p_amount,p_date,trim(p_description),trim(p_reference),p_account,a) returning id into id;
 if p_account is not null then insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by) values(p_account,case when p_direction='revenue' then 'in' else 'out' end,p_amount,case when p_direction='revenue' then 'customer_receipt' else 'supplier' end,trim(p_reference),p_date::timestamp at time zone 'Africa/Nairobi',a);end if;
 perform charm.audit('operatingEntryRecorded','finance_operating_entries',id,jsonb_build_object('direction',p_direction,'category',p_category,'amount',p_amount,'reference',p_reference));return id;
end$$;

create function charm.finance_set_invoice_settings(p_tax_rate numeric,p_terms_days integer) returns void language plpgsql security definer set search_path='' as $$declare a bigint:=charm.require_actor();begin
 if charm.finance_role() not in ('admin','finance_officer','finance_manager') then raise exception 'forbidden';end if;
 if p_tax_rate not between 0 and 1 or p_terms_days not between 0 and 365 then raise exception 'invalid';end if;
 update charm.finance_invoice_settings set tax_rate=p_tax_rate,credit_terms_days=p_terms_days,updated_by=a,updated_at=now() where id=true;
 perform charm.audit('invoiceSettingsUpdated','finance_invoice_settings',1,jsonb_build_object('tax_rate',p_tax_rate,'credit_terms_days',p_terms_days));
end$$;
create function charm.finance_auto_invoice() returns trigger language plpgsql security definer set search_path='' as $$declare s charm.finance_invoice_settings;o charm.orders;subtotal numeric;tax numeric;inv bigint;begin
 if new.status='confirmed' and (tg_op='INSERT' or old.status is distinct from 'confirmed') then
  select * into s from charm.finance_invoice_settings where id=true;
  select coalesce(sum(line_total),0) into subtotal from charm.order_items where order_id=new.id;
  tax:=round(subtotal*s.tax_rate,2);
  insert into charm.finance_sales_invoices(invoice_number,order_id,client_id,batch_lot,subtotal,tax_rate,tax_amount,total,etims_status,credit_terms_days,due_date,issued_by)
  values('CHM-INV-'||to_char(clock_timestamp() at time zone 'Africa/Nairobi','YYYYMMDD')||'-'||lpad(nextval('charm.finance_sales_invoice_seq')::text,6,'0'),new.id,new.client_id,null,subtotal,s.tax_rate,tax,subtotal+tax,'unavailable',s.credit_terms_days,(now() at time zone 'Africa/Nairobi')::date+s.credit_terms_days,coalesce(new.confirmed_by,charm.actor())) returning id into inv;
  insert into charm.finance_operating_entries(direction,category,amount,occurred_on,description,reference,invoice_id,created_by) values('revenue','sales',subtotal,(now() at time zone 'Africa/Nairobi')::date,'Order '||new.id,'invoice:'||inv,inv,coalesce(new.confirmed_by,charm.actor()));
  if tax>0 then insert into charm.finance_operating_entries(direction,category,amount,occurred_on,description,reference,invoice_id,created_by) values('revenue','tax',tax,(now() at time zone 'Africa/Nairobi')::date,'Tax on order '||new.id,'invoice-tax:'||inv,inv,coalesce(new.confirmed_by,charm.actor()));end if;
  insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) select u.id,null,'salesInvoiceIssued','sales-invoice:'||inv||':'||u.id,'finance_sales_invoices',inv from charm.users u where u.active and u.role in ('admin','finance_officer','finance_manager') and u.id<>coalesce(charm.actor(),-1) on conflict do nothing;
 end if;return new;end$$;
create trigger finance_auto_sales_invoice after insert or update of status on charm.orders for each row execute function charm.finance_auto_invoice();
create function charm.finance_assign_invoice_lot(p_invoice bigint,p_lot text) returns void language plpgsql security definer set search_path='' as $$declare a bigint:=charm.require_actor();i charm.finance_sales_invoices;begin
 if not charm.finance_reader() or not exists(select 1 from charm.production_batches where lot_number=p_lot and status='released') then raise exception 'invalidLot';end if;
 update charm.finance_sales_invoices set batch_lot=p_lot,etims_status='unavailable' where id=p_invoice and status='issued' and (batch_lot is null or batch_lot='');if not found then raise exception 'invoiceLocked';end if;
 select * into i from charm.finance_sales_invoices where id=p_invoice;perform charm.audit('invoiceBatchAssigned','finance_sales_invoices',p_invoice,jsonb_build_object('batch_lot',p_lot));
 insert into charm.finance_notifications(recipient_id,request_id,event,event_key,entity,entity_id) select u.id,null,'invoiceBatchReady','invoice-lot:'||p_invoice||':'||u.id,'finance_sales_invoices',p_invoice from charm.users u where u.active and u.role in ('admin','finance_officer') and u.id<>a on conflict do nothing;
end$$;
create function charm.finance_operations_metadata() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not charm.finance_reader() then raise exception 'forbidden';end if;
 return jsonb_build_object(
 'production_materials',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'category',m.category,'base_unit',m.base_unit,'purchase_unit',m.purchase_unit,'purchase_to_base',m.purchase_to_base) order by m.name),'[]') from charm.production_materials m where m.active),
 'production_batches',(select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'lot_number',b.lot_number,'product_name',f.product_name,'target_liters',b.target_liters) order by b.id desc),'[]') from charm.production_batches b join charm.production_formulas f on f.id=b.formula_id where b.status in ('qc_hold','released','rejected')),
 'batch_used',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select batch_id,material_id,-sum(quantity_base) quantity from charm.production_stock_movements where kind='consumption' and batch_id is not null group by batch_id,material_id)x),
 'batch_standard',(with recursive bom(batch_id,formula_id,scale,path) as (select b.id,b.formula_id,b.target_liters/f.yield_liters,array[b.formula_id]::bigint[] from charm.production_batches b join charm.production_formulas f on f.id=b.formula_id where b.status in ('qc_hold','released','rejected') union all select b.batch_id,i.child_formula_id,b.scale*i.quantity/f.yield_liters,b.path||i.child_formula_id from bom b join charm.production_formula_items i on i.formula_id=b.formula_id join charm.production_formulas f on f.id=i.child_formula_id where i.child_formula_id is not null and not i.child_formula_id=any(b.path)) select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select b.batch_id,m.id material_id,sum(charm.production_convert(m.id,i.quantity,i.unit)*b.scale) quantity from bom b join charm.production_formula_items i on i.formula_id=b.formula_id join charm.production_materials m on m.id=i.material_id group by b.batch_id,m.id)x),
 'purchase_orders',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'po_number',p.po_number,'status',p.status) order by p.id desc),'[]') from charm.finance_purchase_orders p where p.status in ('ordered','part_received')),
 'po_lines',(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'po_id',l.po_id,'material_name',m.name,'purchase_unit',l.purchase_unit,'quantity',l.quantity) order by l.id),'[]') from charm.finance_purchase_order_lines l join charm.production_materials m on m.id=l.material_id),
 'pending_grns',(select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'grn_number',g.grn_number,'weight_ticket',g.weight_ticket) order by g.id),'[]') from charm.finance_goods_receipts g where g.status='pending_qc'),
 'approved_grns',(select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'grn_number',g.grn_number,'po_id',g.po_id) order by g.id desc),'[]') from charm.finance_goods_receipts g where g.status='approved'),
 'received_pos',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'po_number',p.po_number) order by p.id desc),'[]') from charm.finance_purchase_orders p where p.status in ('part_received','received')),
 'pending_invoices',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'invoice_number',i.invoice_number) order by i.id desc),'[]') from charm.finance_supplier_invoices i where i.status='pending_match'),
 'invoice_orders',(select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'client_name',c.name) order by o.id desc),'[]') from charm.orders o join charm.clients c on c.id=o.client_id where o.status='confirmed' and not exists(select 1 from charm.finance_sales_invoices i where i.order_id=o.id)),
 'released_batches',(select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'lot_number',b.lot_number) order by b.id desc),'[]') from charm.production_batches b where b.status='released'),
 'invoice_settings',(select to_jsonb(x) from charm.finance_invoice_settings x where id=true),
 'sales_invoices',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'invoice_number',i.invoice_number) order by i.id desc),'[]') from charm.finance_sales_invoices i where i.status='issued'),
 'unassigned_invoices',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'invoice_number',i.invoice_number) order by i.id desc),'[]') from charm.finance_sales_invoices i where i.status='issued' and nullif(i.batch_lot,'') is null));
end$$;
create function charm.finance_operations_register(p_view text,p_from date,p_to date,p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;total bigint;begin
 if not charm.finance_reader() then raise exception 'forbidden';end if;
 if p_page is null or p_page<1 or p_from is null or p_to is null or p_to<p_from then raise exception 'invalid';end if;
 if p_view='batch_costs' then
  select count(*) into total from charm.finance_batch_costs c;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from(select c.id,b.lot_number,f.product_name,coalesce(l.standard_cost,0)::numeric(14,2) standard_cost,coalesce(l.actual_cost,0)::numeric(14,2) actual_cost,(coalesce(l.actual_cost,0)-coalesce(l.standard_cost,0))::numeric(14,2) variance,coalesce(l.primary_packaging,0)::numeric(14,2) primary_packaging,coalesce(l.secondary_packaging,0)::numeric(14,2) secondary_packaging,(c.utilities+c.direct_labor+c.tank_hours*c.tank_hour_rate+c.filling_hours*c.filling_hour_rate)::numeric(14,2) overhead,c.waste_cost,c.coproduct_recovery,(coalesce(l.actual_cost,0)+c.utilities+c.direct_labor+c.tank_hours*c.tank_hour_rate+c.filling_hours*c.filling_hour_rate+c.waste_cost-c.coproduct_recovery)::numeric(14,2) total_cost from charm.finance_batch_costs c join charm.production_batches b on b.id=c.batch_id join charm.production_formulas f on f.id=b.formula_id left join lateral(select sum(standard_quantity*unit_cost) standard_cost,sum(actual_quantity*unit_cost) actual_cost,sum(actual_quantity*unit_cost) filter(where cost_type='primary_packaging') primary_packaging,sum(actual_quantity*unit_cost) filter(where cost_type='secondary_packaging') secondary_packaging from charm.finance_batch_cost_lines where batch_cost_id=c.id)l on true order by c.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='purchases' then
  select count(*) into total from charm.finance_purchase_orders;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from(select p.id,p.po_number,f.name supplier_name,p.status,p.currency,p.created_at from charm.finance_purchase_orders p join charm.finance_payees f on f.id=p.supplier_id order by p.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='goods_receipts' then
  select count(*) into total from charm.finance_goods_receipts;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from(select g.id,g.grn_number,p.po_number,g.status,g.weight_ticket,g.weighbridge_weight,g.qc_at from charm.finance_goods_receipts g join charm.finance_purchase_orders p on p.id=g.po_id order by g.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='supplier_invoices' then
  select count(*) into total from charm.finance_supplier_invoices;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('subtotal',x.subtotal::text,'tax_amount',x.tax_amount::text,'duty_amount',x.duty_amount::text)),'[]') into rows from(select i.id,i.invoice_number,f.name supplier_name,i.po_id,i.grn_id,i.status,i.subtotal,i.tax_amount,i.duty_amount,i.request_id from charm.finance_supplier_invoices i join charm.finance_payees f on f.id=i.supplier_id order by i.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='sales_invoices' then
  select count(*) into total from charm.finance_sales_invoices;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('subtotal',x.subtotal::text,'tax_amount',x.tax_amount::text,'total',x.total::text)),'[]') into rows from(select i.id,i.invoice_number,i.order_id,c.name client_name,i.batch_lot,i.subtotal,i.tax_amount,i.total,i.etims_status,i.due_date,i.etims_control from charm.finance_sales_invoices i join charm.clients c on c.id=i.client_id order by i.id desc limit 100 offset (p_page-1)*100)x;
 elsif p_view='operating' then
  select count(*) into total from charm.finance_operating_entries where occurred_on between p_from and p_to;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('amount',x.amount::text)),'[]') into rows from(select id,direction,category,amount,occurred_on,description,reference from charm.finance_operating_entries where occurred_on between p_from and p_to order by id desc limit 100 offset (p_page-1)*100)x;
 else raise exception 'invalid';end if;
 return jsonb_build_object('rows',rows,'total',total);
end$$;

alter table charm.finance_notifications alter column request_id drop not null;
do $$ declare t text;begin foreach t in array array['finance_invoice_settings','finance_batch_costs','finance_batch_cost_lines','finance_purchase_orders','finance_purchase_order_lines','finance_goods_receipts','finance_goods_receipt_lines','finance_supplier_invoices','finance_sales_invoices','finance_operating_entries'] loop execute format('alter table charm.%I enable row level security',t);execute format('revoke all on charm.%I from public,anon,authenticated',t);execute format('grant select on charm.%I to authenticated',t);end loop;end$$;
create policy finance_ops_read on charm.finance_batch_costs for select to authenticated using(charm.finance_reader());create policy finance_ops_lines_read on charm.finance_batch_cost_lines for select to authenticated using(charm.finance_reader());
create policy finance_po_read on charm.finance_purchase_orders for select to authenticated using(charm.finance_reader());create policy finance_po_lines_read on charm.finance_purchase_order_lines for select to authenticated using(charm.finance_reader());create policy finance_grn_read on charm.finance_goods_receipts for select to authenticated using(charm.finance_reader());create policy finance_grn_lines_read on charm.finance_goods_receipt_lines for select to authenticated using(charm.finance_reader());create policy finance_supplier_invoice_read on charm.finance_supplier_invoices for select to authenticated using(charm.finance_reader());create policy finance_sales_invoice_read on charm.finance_sales_invoices for select to authenticated using(charm.finance_reader() or exists(select 1 from charm.clients c where c.id=client_id and charm.can_access(c.salesperson_id)));create policy finance_operating_read on charm.finance_operating_entries for select to authenticated using(charm.finance_reader());
grant usage,select on sequence charm.finance_batch_costs_id_seq,charm.finance_batch_cost_lines_id_seq,charm.finance_purchase_orders_id_seq,charm.finance_purchase_order_lines_id_seq,charm.finance_goods_receipts_id_seq,charm.finance_goods_receipt_lines_id_seq,charm.finance_supplier_invoices_id_seq,charm.finance_sales_invoices_id_seq,charm.finance_operating_entries_id_seq,charm.finance_sales_invoice_seq to authenticated;
revoke execute on function charm.finance_save_batch_cost(bigint,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,jsonb,text),charm.finance_create_purchase_order(bigint,text,text,jsonb),charm.finance_receive_purchase(bigint,text,text,numeric,jsonb,text),charm.finance_approve_grn(bigint,boolean,text),charm.finance_submit_supplier_invoice(bigint,bigint,text,numeric,numeric,numeric,text,text),charm.finance_match_supplier_invoice(bigint,text,text),charm.finance_issue_sales_invoice(bigint,numeric,integer,text,text),charm.finance_record_etims(bigint,text,text,jsonb),charm.finance_record_operating_entry(text,text,numeric,date,text,text,bigint),charm.finance_operations_metadata(),charm.finance_operations_register(text,date,date,integer),charm.finance_set_invoice_settings(numeric,integer),charm.finance_assign_invoice_lot(bigint,text),charm.finance_auto_invoice() from public,anon,authenticated;
grant execute on function charm.finance_save_batch_cost(bigint,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,jsonb,text),charm.finance_create_purchase_order(bigint,text,text,jsonb),charm.finance_receive_purchase(bigint,text,text,numeric,jsonb,text),charm.finance_approve_grn(bigint,boolean,text),charm.finance_submit_supplier_invoice(bigint,bigint,text,numeric,numeric,numeric,text,text),charm.finance_match_supplier_invoice(bigint,text,text),charm.finance_issue_sales_invoice(bigint,numeric,integer,text,text),charm.finance_record_etims(bigint,text,text,jsonb),charm.finance_record_operating_entry(text,text,numeric,date,text,text,bigint),charm.finance_operations_metadata(),charm.finance_operations_register(text,date,date,integer),charm.finance_set_invoice_settings(numeric,integer),charm.finance_assign_invoice_lot(bigint,text) to authenticated;
notify pgrst, 'reload schema';
commit;

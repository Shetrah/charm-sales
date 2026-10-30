-- Company letterhead profile plus one rich payload used by the printable invoice and delivery note.
begin;

create table if not exists charm.company_profile(
 id boolean primary key default true check(id),
 legal_name text not null default 'CHARM KENYA',
 trading_name text not null default '',
 address_line1 text not null default '',
 address_line2 text not null default '',
 city text not null default 'Nairobi',
 country text not null default 'Kenya',
 phone text not null default '',
 email text not null default '',
 website text not null default '',
 tax_id text not null default '',
 bank_name text not null default '',
 bank_account_name text not null default '',
 bank_account_number text not null default '',
 bank_branch text not null default '',
 mobile_money_name text not null default '',
 mobile_paybill text not null default '',
 mobile_account text not null default '',
 delivery_terms text not null default 'Check quantities and the condition of goods at the time of delivery. A signed delivery note is proof of receipt.',
 invoice_terms text not null default 'Payment is due by the date shown on this invoice. Goods remain the property of the supplier until paid in full.',
 footer_note text not null default 'Thank you for your business.',
 updated_by bigint references charm.users(id),
 updated_at timestamptz not null default now()
);
insert into charm.company_profile(id) values(true) on conflict(id) do nothing;
alter table charm.company_profile enable row level security;
revoke all on charm.company_profile from public,anon,authenticated;
grant select on charm.company_profile to authenticated;
create policy company_profile_read on charm.company_profile for select to authenticated using(true);

create or replace function charm.company_profile_save(
 p_legal_name text,p_trading_name text default '',p_address_line1 text default '',p_address_line2 text default '',
 p_city text default '',p_country text default '',p_phone text default '',p_email text default '',p_website text default '',p_tax_id text default '',
 p_bank_name text default '',p_bank_account_name text default '',p_bank_account_number text default '',p_bank_branch text default '',
 p_mobile_money_name text default '',p_mobile_paybill text default '',p_mobile_account text default '',
 p_delivery_terms text default '',p_invoice_terms text default '',p_footer_note text default '') returns void
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor();name text:=trim(coalesce(p_legal_name,''));begin
 if not charm.is_admin() then raise exception 'forbidden';end if;
 if length(name) not between 1 and 120
  or coalesce(length(trim(coalesce(p_trading_name,''))),0)>120
  or coalesce(length(trim(coalesce(p_address_line1,''))),0)>200
  or coalesce(length(trim(coalesce(p_address_line2,''))),0)>200
  or coalesce(length(trim(coalesce(p_city,''))),0)>120
  or coalesce(length(trim(coalesce(p_country,''))),0)>120
  or coalesce(length(trim(coalesce(p_phone,''))),0)>40
  or coalesce(length(trim(coalesce(p_email,''))),0)>200
  or coalesce(length(trim(coalesce(p_website,''))),0)>200
  or coalesce(length(trim(coalesce(p_tax_id,''))),0)>40
  or coalesce(length(trim(coalesce(p_bank_name,''))),0)>120
  or coalesce(length(trim(coalesce(p_bank_account_name,''))),0)>120
  or coalesce(length(trim(coalesce(p_bank_account_number,''))),0)>60
  or coalesce(length(trim(coalesce(p_bank_branch,''))),0)>120
  or coalesce(length(trim(coalesce(p_mobile_money_name,''))),0)>120
  or coalesce(length(trim(coalesce(p_mobile_paybill,''))),0)>40
  or coalesce(length(trim(coalesce(p_mobile_account,''))),0)>60
  or coalesce(length(trim(coalesce(p_delivery_terms,''))),0)>600
  or coalesce(length(trim(coalesce(p_invoice_terms,''))),0)>600
  or coalesce(length(trim(coalesce(p_footer_note,''))),0)>300
 then raise exception 'invalid';end if;
 if trim(coalesce(p_email,''))<>'' and p_email not like '_%@_%.%' then raise exception 'invalid';end if;
 update charm.company_profile set legal_name=name,trading_name=trim(coalesce(p_trading_name,'')),address_line1=trim(coalesce(p_address_line1,'')),address_line2=trim(coalesce(p_address_line2,'')),
  city=trim(coalesce(p_city,'')),country=trim(coalesce(p_country,'')),phone=trim(coalesce(p_phone,'')),email=lower(trim(coalesce(p_email,''))),website=trim(coalesce(p_website,'')),tax_id=upper(trim(coalesce(p_tax_id,''))),
  bank_name=trim(coalesce(p_bank_name,'')),bank_account_name=trim(coalesce(p_bank_account_name,'')),bank_account_number=trim(coalesce(p_bank_account_number,'')),bank_branch=trim(coalesce(p_bank_branch,'')),
  mobile_money_name=trim(coalesce(p_mobile_money_name,'')),mobile_paybill=trim(coalesce(p_mobile_paybill,'')),mobile_account=trim(coalesce(p_mobile_account,'')),
  delivery_terms=trim(coalesce(p_delivery_terms,'')),invoice_terms=trim(coalesce(p_invoice_terms,'')),footer_note=trim(coalesce(p_footer_note,'')),
  updated_by=a,updated_at=now()
 where id=true;
 perform charm.audit('companyProfileUpdated','company_profile',1,jsonb_build_object('legal_name',name,'tax_id',upper(trim(coalesce(p_tax_id,'')))));
end$$;

-- Every field the invoice and delivery note documents render, in one role-checked read.
create function charm.sales_document_payload(p_order bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;begin
 if charm.actor() is null then raise exception 'unauthorized';end if;
 select jsonb_build_object(
  'company',(select to_jsonb(cp) from charm.company_profile cp where cp.id=true),
  'order',jsonb_build_object('id',o.id,'status',o.status,'total',o.total,'due_date',o.due_date,'confirmed_at',o.confirmed_at,'created_at',o.created_at,'customer_type',o.customer_type,'contract_reference',o.contract_reference,'contract_signed_by',o.contract_signed_by),
  'client',jsonb_build_object('id',c.id,'name',c.name,'contact',c.contact,'phone',c.phone,'location',c.location,'customer_segment',c.customer_segment,'credit_limit',c.credit_limit),
  'salesperson',jsonb_build_object('id',u.id,'name',u.name,'phone',u.phone,'email',u.email,'staff_code',u.staff_code),
  'items',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'description',i.product_description,'sku',pr.sku,'barcode',pr.barcode,'variant',trim(pr.category||' '||pr.capacity||coalesce(' '||pr.fragrance,'')),'quantity',i.quantity,'unit',i.unit,'unit_price',i.unit_price,'line_total',i.line_total) order by i.id),'[]') from charm.order_items i left join charm.products pr on pr.id=i.product_id where i.order_id=o.id),
  'invoice',(select jsonb_build_object('id',v.id,'invoice_number',v.invoice_number,'status',v.status,'subtotal',v.subtotal,'tax_rate',v.tax_rate,'tax_amount',v.tax_amount,'total',v.total,'batch_lot',v.batch_lot,'credit_terms_days',v.credit_terms_days,'due_date',v.due_date,'issued_at',v.issued_at,'etims_status',v.etims_status,'etims_control',v.etims_control) from charm.finance_sales_invoices v where v.order_id=o.id),
  'payments',jsonb_build_object(
    'verified',coalesce((select sum(p.amount) from charm.payments p where p.order_id=o.id and p.status='verified'),0),
    'pending',coalesce((select sum(p.amount) from charm.payments p where p.order_id=o.id and p.status='pending'),0),
    'lines',coalesce((select jsonb_agg(jsonb_build_object('reference',p.reference,'amount',p.amount,'received_at',p.received_at) order by p.received_at desc) from charm.payments p where p.order_id=o.id and p.status='verified'),'[]')),
  'delivery',(select jsonb_build_object('id',d.id,'delivery_number',d.delivery_number,'status',d.status,'scheduled_on',d.scheduled_on,'driver_name',d.driver_name,'driver_phone',d.driver_phone,'vehicle',d.vehicle,'notes',d.notes,'failure_reason',d.failure_reason,'dispatched_at',d.dispatched_at,'delivered_at',d.delivered_at,'created_by_name',cb.name,
    'items',(select coalesce(jsonb_agg(jsonb_build_object('description',i.product_description,'sku',pr.sku,'barcode',pr.barcode,'quantity',x.quantity,'unit',x.unit,'unit_price',i.unit_price,'line_total',i.line_total,'bottles',x.quantity*case when x.unit='carton' then coalesce(pr.carton,1) else 1 end) order by x.id),'[]') from charm.sales_delivery_items x join charm.order_items i on i.id=x.order_item_id left join charm.products pr on pr.id=x.product_id where x.delivery_id=d.id)
   ) from charm.sales_deliveries d left join charm.users cb on cb.id=d.created_by where d.order_id=o.id),
  'credit_notes',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'credit_note',r.credit_note,'amount',r.credit_amount,'quantity',r.quantity,'reason',r.reason,'lot',r.batch_lot,'created_at',r.updated_at) order by r.id desc),'[]') from charm.sales_returns r where r.order_id=o.id and r.status='credited')
 ) into result
 from charm.orders o join charm.clients c on c.id=o.client_id join charm.users u on u.id=o.salesperson_id
 where o.id=p_order and (charm.can_access(o.salesperson_id) or charm.finance_reader());
 if result is null then raise exception 'notFound';end if;
 return result;
end$$;

grant execute on function charm.company_profile_save(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text) to authenticated;
grant execute on function charm.sales_document_payload(bigint) to authenticated;
notify pgrst,'reload schema';
commit;

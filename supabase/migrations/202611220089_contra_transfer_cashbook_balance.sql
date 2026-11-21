begin;

-- Use the same account balance source as Finance metadata. finance_cashbook
-- includes legacy verified receipts whose account was assigned later through
-- finance_receipt_allocations, even when finance_ledger.account_id is null.
create or replace function charm.finance_transfer_accounts(
 p_key uuid,p_source bigint,p_destination bigint,p_amount text,p_date date,p_reference text,p_description text
) returns bigint language plpgsql security definer set search_path='' as $$
declare
 a bigint:=charm.finance_lock_actor();
 old bigint;
 v numeric;
 balance numeric;
 account_count integer;
 transfer_id bigint;
 ref text:=trim(coalesce(p_reference,''));
 details text:=trim(coalesce(p_description,''));
begin
 perform charm.require_finance();
 old:=charm.claim(p_key,'finance_transfer_accounts',jsonb_build_array(p_source,p_destination,p_amount,p_date,ref,details));
 if old is not null then return old; end if;
 v:=charm.finance_money(p_amount);
 if p_source is null or p_destination is null or p_source=p_destination
   or p_date is null or p_date<'2020-01-01'::date
   or p_date>(now() at time zone 'Africa/Nairobi')::date
   or length(ref) not between 1 and 200 or length(details) not between 1 and 2000 then
  raise exception 'invalid';
 end if;
 -- Lock both accounts in ID order so concurrent transfers cannot deadlock or overspend.
 perform id from charm.finance_accounts
  where id in (p_source,p_destination) and active order by id for update;
 select count(*) into account_count from charm.finance_accounts
  where id in (p_source,p_destination) and active;
 if account_count<>2 then raise exception 'invalid'; end if;
 if exists(select 1 from charm.finance_account_transfers where lower(trim(reference))=lower(ref)) then
  raise exception 'duplicateReference';
 end if;
 select coalesce(sum(case when direction='in' then amount else -amount end),0)
  into balance from charm.finance_cashbook where account_id=p_source;
 if balance<v then raise exception 'insufficientFunds'; end if;
 insert into charm.finance_account_transfers(source_account_id,destination_account_id,amount,occurred_on,reference,description,created_by)
  values(p_source,p_destination,v,p_date,ref,details,a) returning id into transfer_id;
 -- The source debit and destination credit commit or roll back together.
 insert into charm.finance_ledger(account_id,direction,amount,kind,reference,occurred_at,recorded_by)
  values
   (p_source,'out',v,'contra_transfer',ref,p_date::timestamp at time zone 'Africa/Nairobi',a),
   (p_destination,'in',v,'contra_transfer',ref,p_date::timestamp at time zone 'Africa/Nairobi',a);
 perform charm.audit('financeContraTransfer','finance_account_transfers',transfer_id,
  jsonb_build_object('source_account_id',p_source,'destination_account_id',p_destination,
   'amount',v::text,'occurred_on',p_date,'reference',ref));
 return charm.finish(p_key,transfer_id);
end$$;

revoke all on function charm.finance_transfer_accounts(uuid,bigint,bigint,text,date,text,text) from public,anon,authenticated;
grant execute on function charm.finance_transfer_accounts(uuid,bigint,bigint,text,date,text,text) to authenticated;
notify pgrst,'reload schema';
commit;

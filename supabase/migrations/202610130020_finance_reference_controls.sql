begin;
create unique index finance_disbursement_reference_normalized on charm.finance_disbursements(account_id,lower(trim(reference)));
create unique index finance_refund_reference_normalized on charm.finance_accountability(account_id,lower(trim(reference))) where kind='refund' and status='accepted';
create unique index finance_receipt_reference_normalized on charm.finance_receipt_allocations(account_id,lower(trim(reference)));
create unique index finance_statement_reference_normalized on charm.finance_statement_lines(account_id,lower(trim(reference)),direction);
notify pgrst,'reload schema';
commit;

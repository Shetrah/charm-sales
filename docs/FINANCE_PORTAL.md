# Integrated Finance Portal

The dashboard lives at `/finance`, with focused sidebar pages under `/finance/expenses`, `/finance/requests`, `/finance/suppliers`, `/finance/disbursements`, `/finance/accountability`, `/finance/cashbook`, `/finance/receipts`, `/finance/budgets`, `/finance/statements`, `/finance/accounts` and `/finance/audit`. It uses the same Supabase Auth mapping and `charm.users` IDs, customers, orders, payments and audit log. Default currency is KES. No production secrets, synthetic transactions, automatic transfer claims or destructive record migration are included. `/finance/expenditure` and `/finance/operating` are retired bookmarks: they redirect to `/finance/expenses`, and the operating posting action now lives on `/finance/cashbook`.

## Install or complete the partially installed schema

Read-only inspection on 13 October 2026 found migrations 001–009 and an early finance foundation/API already present in the configured project. The hosted finance tables lacked the expenditure-date field, receipt allocations, reporting views and later tools. No hosted financial writes or migrations were executed by this implementation.

1. Back up the database and private Storage, then validate in a staging Supabase project.
2. After baseline **001–009**, review and apply **`supabase/finance-upgrade-reviewed.sql`** only when the project holds nothing newer than it. The bundle is a frozen snapshot of finance migrations **010–023**; it handles an existing partial 010/011 installation and can be reapplied inside that range without replacing records or IDs. Do not rerun `setup-reviewed.sql`.
3. Fresh migration-managed environments may instead apply the versioned files **010–023 in order**. The bundle is generated from those files by `python tools/build-finance-bundle.py`. It replaces the obsolete eight-argument accountability API with the current dated API, preserves transactions, refreshes policies/triggers and reloads PostgREST.
4. A project that already replayed files past **0023** — including the consolidated expense register in **0053–0056** — continues with the individual files in `supabase/migrations` in filename order and never re-applies the bundle. The bundle would replace newer function bodies with their 0021-era definitions, and it is not widened to cover 0024+ because migration 0027 reaches into production and sales objects outside finance.
5. Ensure `charm` is in Supabase Data API exposed schemas. Check the `supabase_realtime` publication includes finance requests, payments, accountability, ledger, budgets, notifications and statement lines. Migration 013 adds these when the publication exists. Table RLS still controls each subscriber's access. The 10-second visible-page refresh remains available when Realtime cannot connect.
6. Redeploy **`add-staff`** with the three-role allowlist. Configure Auth redirect URLs, Edge allowed origins and public Vercel variables as described in `VERCEL_ENV.md`. Service credentials belong only in Supabase Edge secrets; never in Vite variables.
7. An Admin uses Team → Add staff / Edit staff information to provision a Finance Officer with a temporary password. Admins cannot change their own role or disable/delete themselves. Historical Finance Manager, Management and Auditor roles are consolidated to Finance Officer by migration 021, preserving their staff IDs.
8. A Finance Officer configures expense categories and departments (Expenses → Categories & departments), monthly category budgets, payment accounts, verified staff/supplier destinations and independently confirmed opening funds. Accounts start with **zero** funds. Each account can have one opening posting. Subsequent confirmed customer receipts and refunds supply recorded funds. No example balances are installed.
9. Rebuild and redeploy Vercel with the existing public Supabase environment variables. Run the hosted acceptance checks below before enabling real financial operations.

## Roles and workflow

| Role | Responsibilities |
| --- | --- |
| Salesperson | Own requests, documents, payment/status history, receipt reports, unused-fund refunds and own statements. |
| Admin | Access all portals through the Admin portal. Manage staff and approve staff/supplier requests. Can oversee all Finance functions; self-approval remains prohibited. |
| Finance Officer | Approved staff queue (unapproved staff requests are hidden), confirmed partial/full payments, accountability/refund review, settlement, customer receipt verification and reconciliation. Supplier requests go to Admin for approval. Includes payees, accounts, budgets, funding, audit and reporting. |


A staff request contains amount, purpose, category, required date, accountability due date and optional PDF/image support. The default accountability deadline is seven days after the default required date and can be edited before approval. Returned requests are corrected and resubmitted by their owner. Rejections/returns require a reason. Supporting documents are stored in private `charm-finance` Storage; allowed files are PDF/JPEG/PNG/WebP up to 10 MB.

Approval reserves the approved amount against the category's required-month budget. Disbursement requires a verified recipient, an active account, sufficient confirmed account funds, a unique account/reference (case and surrounding whitespace normalized for duplicate checks), proof, a payment timestamp and an explicit confirmation. The recipient snapshot is retained with the transaction. Partial payments cannot exceed the approved amount. Another outstanding staff advance blocks a new advance to that person.

**Payments use confirmed manual recording.** Finance completes and independently verifies the actual Cash, Bank, M-Pesa or configured Other payment outside the portal, then records it. The application does not initiate provider transfers. No provider integration or callback credentials were supplied; automated bank/M-Pesa transfers are not implemented or represented as successful.

Accountability records actual expense dates and reports with receipts. A refund requires a reference, destination account and proof; Finance independently confirms receipt before accepting it. Pending or returned submissions do not reduce outstanding balances. Accepted spending plus accepted refunds cannot exceed funds actually disbursed. Settlement requires zero staff balance and no pending accountability. Closing cancels further disbursement, retains history, and releases unused approval/refunds from the budget commitment; final accepted spending/supplier payments remain budget usage.

Supplier payments use the same approval, budget, proof, partial-payment and immutable cashbook controls. Finance Officers submit; an Admin approves. The same officer may then record the independently confirmed supplier payment. The request's verified supplier identity is retained in every confirmed payment.

## One company expense register

`/finance/expenses` is the single expense workspace: the multi-line capture form, today/week/month/year totals, pending/approved/settled pipeline, category, department, source and monthly analysis, drafts, and the company register with CSV/PDF export. Keying an expense once is enough — approval, the independently confirmed payment and the cashbook posting are the same record seen from three angles, and the register reports it as one line. Operating postings, which used to be a second expense book, are recorded from the Cashbook toolbar instead.

The register reads seven mutually exclusive streams so a cost is counted exactly once: approved company expenses (`R-`), accepted receipt spending against staff advances (`A-`), supplier payments with no purchase-order invoice (`D-`), purchase-order-backed cost of sales (`S-`, reported as cost of sales rather than expense), operating cashbook postings (`O-`), advances carrying no accepted accountability yet (`V-`), and approved-but-unpaid commitments (`C-`). The database enforces the guard behind it: `charm.finance_requests` permits at most one row per `(source_type, source_id)`, so an upstream document cannot be re-keyed as a second expense.

A company expense paid to a named supplier that is not a verified payee still disburses: the payment captures the paid-from account and snapshots the recipient text, matching the server rule for `kind='expense'`. Retired categories and departments stay visible in Categories & departments so they can be reinstated, while entry forms only offer active ones.

## Existing data and finance tools

- Travel requests in `charm.expenses` are linked one-to-one by `source_expense_id`. Existing approval is **not** treated as proof of payment. Positive legacy requests enter financial review; rejected ones remain rejected. There is a link from travel-request details to the financial record. Financial approvals synchronize still-pending legacy records; legacy rejection prevents funding a linked pending request. Original IDs, audit events and ownership remain available.
- Customer receipts are the existing `charm.payments`, not another receipt table. Finance verifies a pending receipt with existing proof and allocates its actual account. Existing verified receipts are captured once by their source payment ID, with an unknown account until verified statement matching assigns it. Verification and ledger capture share one transaction, and confirmed order balances retain their existing rules.
- Cashbook postings are append-only. Staff advances and supplier payments are cash out; confirmed refunds/customer receipts are cash in. Opening funding is shown in account balances and cashbook but excluded from operating cash-flow charts. It is not expenditure or sales.
- Bank/M-Pesa reconciliation records actual statement lines and matches a cashbook ID only when account, amount, direction, normalized reference and Nairobi date agree. A transaction can be matched once. Receipt account allocation does **not** pretend a bank statement has been reconciled. Statement ingestion is manual; no external bank feed is connected.
- Monthly expense reports use accepted receipt expenditure dates and actual supplier-payment dates. Staff disbursement alone is an advance, not recognized spending. Dashboards use server aggregates and exact decimal strings; chart lengths alone use approximate numbers for presentation.
- Date/staff filters apply to registers. Pending/approved requests use required dates; disbursements/cash flow use payment dates; expenditure uses actual expense dates. Outstanding/overdue advances show all unsettled requests for the selected staff scope, including older periods.
- Requests expose paid, accepted spending, refunds, pending accountability and outstanding balance for salesperson statements. Cashbook, expenditure, customer receipts, budgets, reconciliation and the complete filtered finance audit register are exportable. Request detail shows the most recent 200 events; the audit register is paginated.

CSV exports are UTF-8 and neutralize spreadsheet formula execution. A server-side stable snapshot supplies all matching permitted rows, up to 5,000; larger exports require narrower filters. PDF export supports up to 1,000 entries and renders Unicode text using browser fonts, including Chinese. PDF table contents are rasterized; CSV is preferable for searching/processing large reports. Exports never silently stop at the displayed 100-row page.

## Notifications and financial controls

Notifications are persistent database rows created in the same transaction as workflow actions, with recipient/event uniqueness. The bell shows an exact unread count, paginated history and links to requests. Admin receives submissions; Finance receives approvals and accountability; owners receive decisions/disbursement/settlement updates. Realtime invalidates queries and polling supplies a fallback.

Sound is muted until the user explicitly enables browser audio. Mute controls are in the notification dialog. Historical rows do not replay alerts. IDs are tracked per logged-in account; supported Web Locks serialize cross-tab sound claims, with local-storage deduplication as a fallback. Browser suspension/audio permissions remain authoritative. Physical speaker output and hosted Realtime delivery require device verification.

All financial write APIs validate the authenticated legacy user/active role in PostgreSQL, not browser metadata. Direct browser financial inserts/updates/deletes are denied. Money is `NUMERIC`, returned as exact text. UUID claims protect retries and reject a changed payload. A transaction-level advisory lock coordinates finance writes and staff role changes; request/budget/account row locks and uniqueness constraints guard shared balances and duplicate payments. This conservative serialization favors correctness for this company portal; hosted load testing should establish throughput before larger deployments.

Disbursements, cashbook entries, document metadata, confirmed account allocations, accepted accountability and closed requests are protected against modifications/deletion. Audit events retain actor, timestamp, before/after configuration/request details, decisions, reasons and payment references. Financial corrections require reviewed compensating operations; a general journal/reversal module is not provided by this release. The cashbook is an operational finance ledger; statutory double-entry accounting would require a separate reviewed general-ledger integration.

## Verification and remaining deployment checks

Automated PostgreSQL/PGlite tests exercise real SQL/RLS, role denial, exact cents, missing/exceeded budgets, self-approval, partial payments, idempotent retries/conflicting payloads, proof requirements, insufficient funds, outstanding advances, refunds/settlement, immutable postings, customer balance integration, supplier flows, legacy links and repeatable compatibility upgrades. Playwright exercises the actual React UI against an isolated SQL-backed transport; its accounts/files are test-only and never used in production.

Before production use, validate separately authenticated Salesperson, Admin and Finance Officer accounts against hosted Supabase; test concurrent disbursements/budget approvals from independent PostgreSQL sessions; verify private uploads/signed reads on Supabase Storage; verify temporary-password onboarding, password recovery and Realtime/RLS reconnects; and test notification sound, camera/file selection and location on the actual phones. Hosted financial writes, provider transfers, multi-session hosted concurrency tests and a Vercel redeploy have not been performed here.


## Focused Finance workflow upgrade

Apply migration 023 after 021 (there is no migration 022), or use the regenerated repeatable finance bundle for a partial installation. Migration 023 adds all-time approved/partial disbursement queues, accountability/settlement queues and outstanding/overdue drill-downs, retaining existing ownership and payment validation. The UI checks this migration capability and displays a setup error rather than misleading empty queues when it is missing.

Actions invalidate and refetch the current account, register, request details, dashboard metrics and notifications immediately after the database confirms the action. Request details show the committed stage and the next responsible action. Supabase Realtime delivers changes between logged-in users when the finance tables are published and the connection is healthy; a five-second visible-page fallback refresh covers disconnected Realtime. This is not a claim of instantaneous delivery without hosted Realtime configuration.

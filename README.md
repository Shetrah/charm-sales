# Charm Company Hub 2.2.0 — Premium Edition

Company management system built with React, TypeScript, Vite and Supabase, sharing existing company identities and business records.

- **Admin** (`/admin`): access every portal, manage staff and approve financial requests.
- **Salesperson** (`/sales`): customers, orders, collections and field activity. Own financial requests and accountability at `/my-requests`.
- **Finance Officer** (`/finance`): accounts, budgets, disbursements, suppliers, reconciliation, accountability, audit and reports. Admin can also access it.
- **Password settings** (`/account/password`): change the temporary password entered by Admin.
- **My profile** (`/account/profile`): update your name, phone, area and profile photo.

Run `npm ci`, configure public Supabase values in `.env.local`, then `npm run dev`. Verify with `npm test`, `npm run test:e2e` and `npm run build`.

See [company portal setup](docs/COMPANY_HUB.md), [Finance controls](docs/FINANCE_PORTAL.md), [migration guide](docs/MIGRATION.md), [reporting](docs/REPORTING.md), [mobile/PWA status](docs/MOBILE_PWA.md) and [Vercel configuration](docs/VERCEL_ENV.md).

React source/assets live in `src/` and `frontend-public/`. Historical SQL migrations remain in `supabase/migrations/`. Unused Laravel source and dependencies have been removed. Company database records and private configuration have not been deleted.

Payments are recorded after confirmation; the system does not initiate bank/M-Pesa transfers. Visit photos and general supporting documents are optional where the underlying workflow already permits it. Customer-payment confirmation, finance payment attestations, contractual records, GPS visit check-in and production quality gates remain intact.

## Version 2.2.0 release notes

- Rebuilt the application presentation around the company logo's deep-violet (`#2905A1`) and teal (`#00BDB5`) brand palette.
- Introduced a premium shared workspace, clearer visual hierarchy, compact role-aware mobile navigation, and phone-friendly cards/forms across the application.
- Updated the PWA shell cache key and install theme to ensure the new shell replaces the previous cached shell.
- Finance Expenses now distinguishes raw-material purchases (through **Purchase → Goods Receipt → Supplier Invoice**) from other operational and financial expenses. Use **Record other operational / financial expense** for day-to-day operating costs.
- Added a real **Contra Entry** workflow for transfers between company-owned cash, bank and M-Pesa accounts. It posts equal debit/credit ledger movements atomically, checks the source balance, records one unique reference and audit event, and excludes transfers from income/expense summaries while updating both account balances.

### Required SQL Editor migration

Before using Contra Entry, run `supabase/sql-editor/20261104_finance_contra_transfers.sql` once in the Supabase SQL Editor. The same script is included as `supabase/migrations/202611040060_finance_contra_transfers.sql`. It is additive: it creates a transfer register, extends the ledger transaction kind, adds secured RPCs and adjusts finance cashflow summaries to exclude internal transfers. Do not run this against a different schema or project. No migration is automatically applied by the frontend.

Production activation also requires the existing reviewed migrations, deployed `add-staff` function and a frontend redeployment.

### Staff notification and profile update

Apply `supabase/migrations/202611040061_self_profile.sql` after migration 060. It adds a self-only profile update RPC, narrows confirmed-order alerts to the salesperson and fulfillment role, and adds notification events to Realtime. The browser notification bell can play a sound after the user enables it during a browser interaction. The app cannot force sound or notification permission on a device.

The service worker can display Web Push in the device notification tray. Enabling that requires `VITE_WEB_PUSH_PUBLIC_KEY`, a deployed authenticated `notification-subscribe` function, and a server-side push sender configured with matching VAPID keys. The sender must fan out only to the recipients already recorded in `charm.finance_notifications`; no push subscriptions or credentials are provisioned by the frontend.

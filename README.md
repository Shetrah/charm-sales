# Charm Company Hub

Company management system built with React, TypeScript, Vite and Supabase, sharing existing company identities and business records.

- **Admin** (`/admin`): access every portal, manage staff and approve financial requests.
- **Salesperson** (`/sales`): customers, orders, collections and field activity. Own financial requests and accountability at `/my-requests`.
- **Finance Officer** (`/finance`): accounts, budgets, disbursements, suppliers, reconciliation, accountability, audit and reports. Admin can also access it.
- **Password settings** (`/account/password`): change the temporary password entered by Admin.

Run `npm ci`, configure public Supabase values in `.env.local`, then `npm run dev`. Verify with `npm test`, `npm run test:e2e` and `npm run build`.

See [company portal setup](docs/COMPANY_HUB.md), [Finance controls](docs/FINANCE_PORTAL.md), [migration guide](docs/MIGRATION.md) and [Vercel configuration](docs/VERCEL_ENV.md).

React source/assets live in `src/` and `frontend-public/`. Historical SQL migrations remain in `supabase/migrations/`. Unused Laravel source and dependencies have been removed. Company database records and private configuration have not been deleted.

Payments are recorded after confirmation and proof; the system does not initiate bank/M-Pesa transfers. Production activation requires reviewed migrations, the deployed `add-staff` function and a frontend redeployment.

# Charm Kenya Sales Portal

React + TypeScript + Vite + Tailwind CSS, backed by Supabase Auth, the existing `charm` PostgreSQL schema, private Storage and secure SQL/Edge operations. Prepared for Vercel at `sales.charmkenya.com`. No production migrations or cutover have been performed.

The replacement frontend is in `src/`; its original Charm logo/favicon is in `frontend-public/assets/`. Versioned additive migrations and RPCs are in `supabase/migrations/`. Laravel files remain available for rollback until hosted staging verification and explicitly approved production cutover.

```powershell
npm ci
Copy-Item .env.example .env.local
# Configure the staging project's public Supabase URL and publishable key.
npm run dev
npm test
node node_modules/@playwright/test/cli.js install chromium
npm run test:e2e
npm run build
npm run preview
```

Read [migration, account onboarding and deployment instructions](docs/MIGRATION.md), [verification results](docs/VALIDATION.md), and the [future Expo/mobile API contract](docs/MOBILE_API.md). The [previous Laravel setup](docs/LARAVEL_README.md) remains for rollback; it is not the new frontend deployment procedure.

The [whole-portal UI and team upgrade](docs/UI_UPGRADE.md) adds phone record cards, role-based workspaces, improved dialogs, financial progress, submission monitoring, live updates and admin staff profiles/editing. Existing installations need only the new additive `202610120008_team_management.sql` after review/staging validation; do not rerun the original setup bundle.

Implemented workflows include client assignment, catalogue/pricing, exact multi-line orders, admin confirmation, partial verified payments/balances, private proofs/photos, next-day itineraries/travel budgets, advance expenses/review, daily reports/follow-ups, browser GPS visits/check-out, workdays and paginated route timelines/latest reported coordinates. English/Simplified Chinese and light/dark preferences persist on login and throughout the workspace.

Sales are counted at admin confirmation using Nairobi month boundaries. Payments do not create sales. Database RLS and secure transactional RPCs enforce ownership, admin approvals, blocked self-approval, duplicate-submission protection, immutable evidence after verification and audit logging. No payroll or commissions.

The connected database was inspected read-only before migrations: 2 users, 48 products, 1 client and 1 audit record; transaction/field tables were empty. Existing rows, IDs and ownership were untouched. The duplicate barcode and 751ml source anomaly remain preserved.

Set up a separate Supabase staging project, apply the reviewed migrations, expose the protected `charm` schema, establish verified Auth mappings, configure SMTP/redirect URLs/private Storage and deploy the invite Edge Function before using the new portal. Do not put database passwords or service-role keys in frontend variables. Production changes and replacing the live portal require explicit approval. Browser GPS is manual while open; native background tracking and an Expo app are future work.

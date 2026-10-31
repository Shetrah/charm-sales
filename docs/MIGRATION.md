# Charm Kenya migration and cutover

The replacement is a React 19 / TypeScript / Vite / Tailwind 4 application connected to Supabase Auth, the existing `charm` PostgreSQL tables, private Storage, SQL RPCs and the secure add-staff Edge Function. Vercel builds only the frontend. The obsolete Laravel application has been removed as requested. SQL history and business records remain. See COMPANY_HUB.md for current portal roles and temporary-password onboarding.

## Database inspected before migrations

On 12 October 2026 a read-only transaction inspected the configured database's `information_schema.columns` and table counts through the existing Laravel connection. The live schema matched the supplied Laravel migrations, including `reports.follow_up_date`. Observed counts: users 2, products 48, clients 1, audit_logs 1; orders, order_items, payments, visits, plans, expenses, reports, workdays and location_points 0 each. No business rows were inserted, edited or deleted. No live schema, policies, Auth accounts, Storage settings, domain or DNS were changed.

Versioned SQL lives in `supabase/migrations`, in filename order. Baseline `CREATE TABLE IF NOT EXISTS` supports an empty staging project and leaves existing tables untouched. Catalogue inserts use `ON CONFLICT (id) DO NOTHING`, preserving approved prices and every existing identifier. The 48 references have no imported quotation prices. Variants 18/20 retain duplicate barcode `0745760226559`; variant 24 retains `751ml`. New fields are additive; no historical order attribution, approval timestamp, balance, client assignment, file path or location timestamp is rewritten. New RLS grants replace browser access only; Laravel's trusted database connection remains separate.

For SQL Editor setup, `supabase/setup-reviewed.sql` combines the seven baseline files **001–009** in order and ends with a PostgREST schema-cache refresh. Review it and apply once to staging. It is not the current schema: finance **010–023** are frozen in `supabase/finance-upgrade-reviewed.sql`, and everything after 023 is only available as individual files in `supabase/migrations`. Apply the missing files in filename order, and see FINANCE_PORTAL.md for why the finance bundle is never re-applied over a project that already holds 024+. Do not rerun `setup-reviewed.sql` over partially applied React migrations; apply only the missing individual files after inspection. `php tools/check-react-setup.php` is a read-only diagnostic of function/mapping presence using the existing Laravel connection; it never prints credentials. Exposing `charm` alone does not install any migrations. A 404 for `actor` is resolved by installing the missing migration, or by refreshing the cache only if the function already exists. Auth-to-staff mapping remains a separate verified onboarding step below.

Before applying to any populated environment, run `supabase/preflight.sql`, save the results securely and compare its schema to the inspected baseline. Stop on drift or unexpected existing RLS/Storage policies: permissive policies combine with OR and can bypass the intended restrictions. Review existing grants and policies explicitly; these migrations do not silently drop unknown policies. Take a restorable database backup and private bucket backup. Apply first to a clone; compare record counts, IDs, monthly sales, balances and source flags afterward. Existing Laravel migration bookkeeping and Sanctum tokens are retained privately; they are not granted to frontend roles.

## Installation and verification

Use Node 20.19+ (or Node 22.12+). From the repository root:

```powershell
npm ci
Copy-Item .env.example .env.local
# Fill .env.local with the staging project public URL and publishable key.
npm run dev
npm test
node node_modules/@playwright/test/cli.js install chromium
npm run test:e2e
npm run build
npm run preview
```

Do not replace the existing server `.env`. Private database credentials remain server-only. Vite reads only the public `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` from `.env.local`/Vercel. The build's public directory is `frontend-public`; Laravel PHP and legacy JavaScript never enter `dist`.

`npm test` runs actual PostgreSQL SQL, privileges and RLS in isolated PGlite, with minimal Auth/Storage schema fixtures; it never connects to the configured live database. `npm run test:e2e` builds with test variables, launches its own isolated PostgreSQL bridge on 127.0.0.1:54329 and serves the build through Vite preview on 127.0.0.1:5174. The test Auth transport is synthetic and strictly test-only. It exercises the real React application and migration functions, not real Supabase email, JWT verification, Storage uploads or PostgREST. Use a separate Supabase staging project to verify those services before cutover. Tests set public variables only within the test process and do not edit `.env.local`.

## Supabase staging setup

1. Clone the existing database/Storage into a separate Supabase project, preserving primary and foreign keys; do not reseed over production data. For a new local Supabase project install its CLI and Docker, run `supabase start`, then `supabase migration up --local`. For a cloned hosted staging project, review and execute each SQL migration in order in its SQL editor, or use the migration CLI only after baselining the existing schema. Never run `db reset` against an existing environment. These SQL files do not require Laravel.
2. In API settings expose `charm` after the RLS migrations have completed successfully. Keep `public` as needed by Supabase and grant no anonymous access to business tables. The client selects `db.schema: charm`; no service-role key belongs in Vite.
3. Disable public sign-ups. Set Auth Site URL to the staging site's origin initially, later `https://sales.charmkenya.com`. Configure redirects: `http://localhost:5173/auth/callback`, `http://127.0.0.1:5173/auth/callback`, `https://sales.charmkenya.com/auth/callback`, and the explicitly chosen staging callback URL. Use exact URLs rather than an unrestricted wildcard.
4. Configure Auth email delivery/SMTP, invitation and password-reset templates. Templates must send the Supabase confirmation link with the configured redirect. Test delivery and expired links. UI supports the callback password-setting flow with a 12-character minimum; set the same or stronger password policy in Supabase.
5. The private bucket migration creates/hardens `charm-private` (5 MB; JPEG, PNG, WebP). Copy existing objects preserving `visits/{id}/…` and `payments/{id}/…` paths when changing projects. Ownership checks apply to signed URL creation and uploads. Payments cannot replace attached proof after verification. Signed URLs last 60 seconds; objects remain private. Failed attach operations may leave orphan uploads; schedule server-side retention/cleanup after reviewing an audit/attachment reconciliation report.
6. Deploy the staff account function to STAGING only: `supabase functions deploy add-staff --project-ref STAGING_PROJECT_REF`. Set Edge secrets `ALLOWED_ORIGINS` for the staging site (comma-separated exact origins). Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` to Edge runtime. Never put the last key in frontend/Vercel public variables. `verify_jwt=false` is deliberate for publishable-key compatibility: the function itself validates the bearer token via `auth.getUser(token)` and the active admin role via RPC, and the service-only linking RPC rechecks the admin.

Custom schema and SPA settings follow [Supabase custom schema documentation](https://supabase.com/docs/guides/api/using-custom-schemas) and [Vercel Vite documentation](https://vercel.com/docs/frameworks/frontend/vite).

## Account migration: preserve identity, reset credentials

Laravel bigint `charm.users.id` stays the canonical salesperson ID for all historical ownership. Supabase Auth UUIDs are linked through `charm.auth_accounts`; roles and active status are read from the trusted legacy users table, never from user-editable Auth metadata. Authenticated users cannot insert a mapping, change roles or read password hashes. Authenticated but unmapped/inactive accounts cannot access records. There is no automatic email-trigger mapping.

Do not copy Laravel bcrypt/Argon password hashes into Supabase Auth. Create or invite Auth users, verify their email and have them set a new password. First, manually create/invite the existing admin in the staging Auth dashboard. Record its Auth UUID. In a trusted SQL editor link that UUID to the existing admin ONLY after checking both records' email and role:

```sql
-- Replace UUID and legacy ID after checking identity; never select password hashes.
insert into charm.auth_accounts(auth_user_id,salesperson_id)
select a.id,u.id from auth.users a join charm.users u on lower(u.email)=lower(a.email)
where a.id='REPLACE_WITH_AUTH_UUID'::uuid and u.id=REPLACE_WITH_LEGACY_ADMIN_ID
  and u.role='admin' and u.active;
-- Confirm exactly one mapping was inserted. Do not infer identity from email alone.
```

That admin can add staff with a temporary password from the Team screen; see COMPANY_HUB.md. Use each existing staff member's exact verified email: the linking RPC reuses the original staff ID and preserves their current role, name and activity flag. A genuinely new email creates a new staff record. If casing duplicates exist, reconcile explicitly first; the linker fails rather than guessing. Existing Auth users or partial invitation/link failures require trusted administrator reconciliation: confirm the Auth UUID/email, then call the service-only `link_staff` RPC from the trusted SQL editor with the requesting admin UUID. Do not delete staff, change emails to bypass an error, or retry an invite with different identity data. An invited but unlinked user receives no data access until reconciled. Test the first admin callback and at least two independent salesperson accounts before onboarding the team.

Supabase Auth sessions replace Laravel sessions and Sanctum tokens; old passwords and mobile tokens will no longer log in to the replacement. Retire pending old-client submission queues at cutover or explicitly reconcile their UUIDs. The old website continues to work until domain cutover; do not enable both frontends for writes during reconciliation.

## Business rules and secure API

All business mutations go through explicitly granted RPCs. Authenticated roles have scoped SELECT, no table INSERT/UPDATE/DELETE or sequence access. Security-definer functions fix an empty search path, resolve the active caller through Auth mapping, verify ownership/admin roles, validate payloads and write audit events atomically.

Orders accept 1–100 lines and positive two-decimal prices as text. PostgreSQL NUMERIC performs exact totals; frontend previews use BigInt cents. Prices are per selected bottle/carton unit; carton packing never multiplies the monetary line again. Proposed prices are manually entered; admins configure catalogue reference bottle prices. Confirmation uses database time, immutable original salesperson attribution, and Nairobi month bounds `[start, next month)`. Client reassignment does not rewrite historical orders. Pending/rejected orders and all payments are excluded from sales.

Verified payments alone reduce confirmed order balances. Partial payments are supported, and approval locks the parent order before the payment to serialize competing verifications and prevent overpayment. A repeated approval fails. The actual submitter cannot approve their own order/payment; legacy orders lacking a submitter use the historical owner for this check. A staff member cannot approve their own plan/expense/report. Admin-submitted records therefore require another admin.

Submissions use UUID receipts protected by transaction advisory locks. Retrying the same UUID/actor/operation/payload returns the original ID; changing payload or actor with that UUID fails. The frontend retains a key while retrying the same form payload. Nothing uses client-provided approval times or role metadata. Approved records have no arbitrary edit/delete path. Payroll/commissions are excluded.

Tables load 20 records at a time with server filters, count, debounced search and owner indexes. Selector queries fetch at most 20 candidates; products retain identifiers/source text. Queries are keyed by Auth UUID and cleared on account changes; approvals invalidate summaries and related lists. Daily routes page 200 points with separately queried latest location; displayed coordinates are a route diagram/timeline rather than a street basemap. Search on tables without text fields uses the numeric record ID.

## Vercel staging and production

Import this repository into Vercel with root directory `.`; framework Vite; install `npm ci`; build `npm run build`; output `dist`. Add the two public variables for the appropriate Supabase project, then rebuild. `vercel.json` rewrites app paths to `/index.html`, with assets served from `/assets`. Visit and refresh every screen on the staging domain. Do not point DNS at this build until the acceptance gate below is met and production cutover is explicitly approved.

After approval: put the old portal into maintenance/read-only mode; make a final backup/manifest; apply reviewed additive migrations to the existing project or reconcile/copy final records to the approved target; establish tested Auth mappings; recheck counts and financial totals; configure production redirect/Edge origins; build with production public variables; attach `sales.charmkenya.com` in Vercel and follow its exact DNS instructions. Verify TLS and live sign-in, direct routes, role isolation and private upload expiry. Keep the previous host, files and backup available. Roll back DNS to Laravel if checks fail; reconcile any new Supabase-auth-only staff before restoring legacy access. No automated destructive down migration or production deployment is provided.

## Acceptance gate and remaining service checks

Run real staging Auth login/logout, invite/reset/callback expiry, two salesperson ownership tests through direct REST and RPC calls, admin/self-approval rejection, simultaneous payment approvals, duplicate retry races, exact totals, Nairobi month boundaries, private upload MIME/size/access/signed URL expiry, and delayed location replay. Test all screens/forms/dialogs in both languages/themes on physical phones/tablets, geolocation denied/available, store photo/proof uploads and direct deployed route refresh. Record real staging outcomes before production approval.

Local PostgreSQL and browser checks do not prove hosted Auth email delivery, real signed JWT validation, Storage service behavior, Vercel routing, SMTP, or phone GPS accuracy. No production credentials or project configuration were changed. Native background tracking, Expo application, offline local encrypted queue, background permission handling and notifications remain future work; their API contracts are prepared in `docs/MOBILE_API.md`. The browser performs manual captures only while open; there is no claim of tracking through a closed tab or locked phone. Local tests simulate tablet/mobile layouts in Chromium, not physical iPhone/Android engines. The obsolete Laravel application has been removed. Complete hosted verification before enabling new workflows.

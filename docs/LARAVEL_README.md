# Charm Kenya Sales Portal

Laravel 13 / PHP 8.3+ application with a private Supabase PostgreSQL schema and Supabase Storage integration. The working Laravel portal now includes a responsive purple/teal workspace, light/dark themes, English/Simplified Chinese, server-paginated records, searchable selectors and interactive approvals. See [WORKSPACE_UPGRADE.md](WORKSPACE_UPGRADE.md) for measured performance, verification, upgrade commands and remaining limitations. This source is the actual application; any separately hosted earlier preview is separate demo software.

## What is implemented

- Supplied company logo and PNG favicon; responsive purple/teal portal, login and real database-backed Blade views.
- Admin and salesperson authorization; restricted client/record ownership; admin registration; web session and mobile Sanctum tokens.
- 48 product variants extracted from the quotation: category, capacity, fragrance, barcode, units per carton. No source prices imported. Product reference prices are nullable and admin-editable.
- Multi-line orders with bottle/carton ordering, proposed prices, exact integer-cent arithmetic, server validation and immutable line descriptions. Admin confirmation determines the sales month in Africa/Nairobi; confirmed_at is distinct from submitted created_at.
- Verified payments reduce balances; pending payments do not. Order row locking prevents concurrent verification from overpaying. Payments never add sales a second time.
- Monthly confirmed sales totals, salesperson comparison and outstanding client balances, including order due dates.
- Next-day plans, future client-travel expense approval requests, daily reports, client visit GPS capture, notes, follow-up dates and private photo/payment-proof uploads.
- Workday start/end API, bounded location batches, timestamp validation and record UUIDs for mobile offline retry; route retrieval API.
- Audit events for approvals and account/pricing changes. Disabling a database account blocks API and portal access.

## Setup on a PHP host

1. Back up any existing database. Use a new dedicated Supabase project if possible.
2. In Supabase SQL editor run `CREATE SCHEMA IF NOT EXISTS charm;`. Do not add charm to the Data API's exposed schemas. Tables use RLS without public policies. Laravel's trusted server database role accesses this private schema; neither anon nor authenticated Supabase browser roles should get access. Do not put database passwords or service role keys in a phone app or browser.
3. Use Supabase's Connect panel to copy the correct session-pooler host, username and port (IPv4-compatible hosting where applicable). Fill .env.example, save as .env on the server. Require TLS.
4. Install PHP 8.3+ with pdo_pgsql, mbstring, openssl, tokenizer, XML, ctype, fileinfo, curl and DOM; install Composer.
5. Run `composer install`, then `php artisan key:generate`, `php artisan migrate`, `php artisan db:seed`. There are no seeded users, sample transactions or imported prices.
6. Create your first admin through `php artisan tinker`: `App\Models\User::create(['name'=>'Your Name','email'=>'your-email@example.com','password'=>'YOUR_UNIQUE_LONG_PASSWORD','role'=>'admin']);`. Keep real passwords out of shell history and source control.
7. Create a PRIVATE Supabase Storage bucket named charm-private (image/jpeg, image/png, image/webp, max 5 MB). Configure SUPABASE_URL and the server-only service role key for the storage endpoints.
8. Point sales.charmkenya.com's document root to this package's public directory, never the project root. Enable HTTPS. Make storage and bootstrap/cache writable by PHP. Set APP_DEBUG=false and APP_ENV=production. Only enable config caching after the application runs successfully.
9. Log in, register the approximately 15 salespeople, enter actual clients and approved reference prices, then run the acceptance checks below before onboarding staff.

The host must support PHP + Composer + outbound HTTPS AND PostgreSQL connectivity, not only MySQL. Supabase Auth is not used here: Laravel authentication/Sanctum owns user identity, with users stored in Supabase PostgreSQL. No Supabase project, production domain or DNS was modified during creation.

## API

Prefix mobile endpoints with /api. POST /token accepts email, password, device; subsequent requests use Authorization: Bearer TOKEN and Accept: application/json. Delete /api/token to revoke the current token. Web POST routes use CSRF protection.

GET /snapshot?month=2026-10 returns authorized dashboard records.
POST /clients, /orders, /orders/{id}/confirm, /orders/{id}/reject, /payments, /payments/{id}/verify.
POST /records/{plans|expenses|reports}, /records/{kind}/{id}/review.
POST /workdays; POST /workdays/{id}/end; POST /workdays/{id}/locations with points array (submission_key UUID, latitude, longitude, accuracy_m, recorded_at ISO-8601). GET /workdays/{id}/route.
POST /visits with arrival GPS and outcome; POST /uploads/{visits|payments}/{id} multipart file; GET same path redirects to a short-lived signed image.
POST /users and /products/{id}/pricing are admin-only.

For order items unit_price always means price PER SELECTED ORDERING UNIT. Carton quantity is informational and must not be silently multiplied into the money calculation a second time. Store a separate UUID submission_key per immutable payload; retry the same UUID after a network failure. New changes require a new UUID. Unique key races can return a conflict; retry to retrieve the already saved record.

## Product source flags

- Variant 24: Shower Gel / Milan Fogland capacity is 751ml in the source. Preserved, flagged; do not silently change to 750ml.
- Variants 18 and 20: 200ml Pheromone and Milan Fogland share barcode 0745760226559. Preserved, flagged; barcode is NOT the database primary key.
- Source spelling FRAGANT YLANG-YLANG normalized to Fragrant Ylang-Ylang in the display catalogue.

## Acceptance tests required on the configured host

1. Admin creates salesperson A/B and assigns distinct clients. A cannot fetch B's data or submit an order for B's client, and cannot confirm orders or verify payments.
2. Multi-line order 2 x 12.35 + 3 x 8.20 totals exactly 49.30. Pending orders do not affect monthly sales. Confirm once; a second confirmation returns conflict.
3. Confirm just before/after Nairobi month boundary. The order falls into exactly one month. Submitted and confirmed timestamps remain separate.
4. Submit 10.00 payment on a 49.30 order. Balance stays 49.30 until admin verifies, then becomes 39.30. Concurrent payment verifications cannot exceed 49.30 total.
5. Repeat the same submission UUID: no duplicate order/payment/location. Ownership still applies on retries.
6. Locations outside active workday boundaries are rejected; points recorded inside the workday can be uploaded after workday ends during delayed sync. A cannot access B's route.
7. Test session login/logout, CSRF rejection, blocked inactive accounts, upload type/size restrictions, private photos and signed URL expiry.
8. Product seed has 48 variants, all prices null, duplicate barcode preserved, 751ml flag preserved.

## Remaining production work

- Flutter Android/iOS app, background location permissions/services, persistent offline queue, encrypted local storage, visible tracking indicators, battery-aware sampling and device field testing. Web GPS captures arrival only; it cannot guarantee continuous screen-locked tracking.
- Real geographic basemap and route timeline, configurable territories, visit checkout workflow, notification delivery and follow-up reminders.
- Price approval limits, cancellation/returns/credit-note workflow, dispatch/delivery stages and statement/export polish. The current API deliberately offers no arbitrary confirmed-order edit or delete endpoint.
- MFA, password-reset onboarding, automatic backups/retention policy, upload cleanup, pagination at scale and runtime security/performance tests.
- Expense reimbursement workflow beyond advance request approval. Factory training/meeting expense exclusion currently relies on declared request purpose and manager review.
- Real-browser visual QA on desktop, tablet and phones, including device GPS and private Supabase Storage uploads. Automated DOM and responsive-style checks are included, but do not replace device testing.

Payroll and commission calculation are excluded.

Field tracking, admin activity review and daily-report follow-ups are documented in [FIELD_ACTIVITY.md](FIELD_ACTIVITY.md). Apply migrations and clear compiled views when updating another environment.
# charm-sales

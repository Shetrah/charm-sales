# Whole-portal interface and team upgrade

This upgrade uses the existing connected React application. No hosted database changes or deployment were performed.

## Interface changes

- Every record page now shares the updated spacing, colours, focus states, entry transitions, empty states and financial status presentation. Product variants use catalogue cards; the team uses staff cards. Phone layouts use readable cards for clients, orders, payments, balances, visits, itineraries, expenses, reports, routes and audit entries instead of horizontally squeezed tables.
- The large empty “Page snapshot” strip is removed. Nonempty pages show compact matching-record counts and clearly labelled page-only monetary values. Confirmation/verification remains the source of financial truth.
- Navigation separates business management and team monitoring for admins, and sales/field work for salespeople. Admin field pages are monitoring/review screens, without personal visit/report submission or workday-start controls. Four phone tabs provide the most useful role-specific destinations; the menu retains access to the remaining authorized screens.
- Phone dialogs use the full viewport, a fixed header, independently scrollable content, a sticky action area, large tap targets, 16px inputs, safe-area padding and background scroll locking. Keyboard Escape, native modal focus containment and restored focus remain supported. Desktop dialogs are wider and scroll internally.
- Orders and payments have submission/review progress and exact financial amounts. Confirmed order details show verified collection progress and remaining balance; pending funds never reduce balances. Expenses distinguish requested from approved travel budgets. Entry forms preview their financial effect before submission.
- Admin monitoring includes six-month confirmed sales, interactive line/bar views, team rankings, pending approval counts, overdue orders, reached follow-up dates, recent submission updates, staff/client names and timestamped reported locations. Counts come from scoped server queries; activity lists and workdays are bounded and explicitly labelled.

## Team and location capabilities: one new migration

For a database that already has migrations 001–007, review and apply **only** `supabase/migrations/202610120008_team_management.sql` to staging first. Do not rerun the original setup bundle. The new migration adds nullable staff phone/territory and client location accuracy/capture timestamps; installs secure `update_staff`, `staff_profile` and `set_client_location` RPCs; and publishes existing business tables to Supabase Realtime when its publication exists. No staff/client/transaction records, IDs, historical salesperson attribution or monetary values are replaced.

Staff cards show role, active status, email and current-month confirmed sales. “View details” loads exact admin-only monthly/all-time sales, outstanding balances, approved travel, client and submission/activity counts, a six-month sales chart, Auth linkage, contact/territory and the latest reported GPS coordinates/time/accuracy. Counts link to the salesperson-filtered records. Staff information can be edited inside the same dialog; name, phone, territory, role and activity status are audit logged. Admins cannot change their own role or disable themselves. Staff cannot call the editing/profile RPCs. Login email remains managed through Supabase Auth and is not changed independently in the business table. Passwords, hashes and tokens are never shown.

Visits and route reporting retain explicit browser GPS capture. Client creation additionally offers optional store-coordinate capture when physically at the store. The stored coordinates include server capture time and reported GPS accuracy. Ownership and coordinate-range checks run on the server. The browser does not claim native background tracking or continuous tracking when locked/closed.

Location capture now tries a fresh precise position for up to 25 seconds, then a fresh standard browser position for up to 20 seconds if the provider is unavailable or times out. Permission denials are not retried automatically. It distinguishes insecure HTTP, policy restrictions, unsupported browsers, browser/OS permission denial, provider failure and timeout. Successful retries clear old error messages; coarse positions retain their actual reported accuracy and show a warning. `localhost` is supported; an HTTP LAN address on a phone is not equivalent to localhost. No guessed/IP-derived coordinates are saved as GPS evidence.

## Live updates and fallback

One account-scoped subscription listens for authorized `charm` business changes and debounces cache refresh by 350ms. The publication intentionally excludes the credential-bearing `users` table; staff edits generate a safe audit event, and all views also refresh on a ten-second visible-page fallback and window focus. Submissions/approvals invalidate related queries immediately; open record details and staff profiles refresh too. Signing out or changing users clears cached data and removes the subscription. No new anonymous permissions are added.

Hosted Realtime must be enabled and migration 008 applied for change events; channel connection alone does not prove publication delivery. Verify with two real authenticated browser sessions in staging. The local browser-test REST bridge does not implement hosted Realtime, so its process sets `VITE_REALTIME_ENABLED=false` and verifies the fallback/connected workflows instead. Normal app builds enable Realtime by default. Disconnected sockets continue using the visible-page fallback.

## Verification commands

```powershell
npm test
node node_modules/@playwright/test/cli.js install chromium
npm run test:e2e
npm run build
```

The browser command builds a separate test-only production artifact in `tests/.artifacts/browser-dist`, using synthetic public test configuration, then serves it on port 5174. It leaves your existing dev server on port 5173 and the normal `dist` build untouched. Tests use one worker to reduce Windows memory pressure. SQL tests use actual isolated PostgreSQL/RLS and never connect to the configured hosted database. The Supabase email/Storage/Realtime services and physical phone GPS still require hosted/device checks. All new interface text supports English and Simplified Chinese; motion is suppressed under reduced-motion preferences.

## Staff lifecycle and finance extension

Migration 009 adds confirmed admin deactivation/reactivation and directory removal, preserving staff IDs, clients, sales, financial balances and audit history. Removed accounts cannot be resurrected through ordinary profile editing. Finance migrations 010–021 consolidate finance duties into Finance Officer alongside Admin and Salesperson; deploy the new `add-staff` Edge Function for temporary-password onboarding. See [Finance Portal setup and controls](FINANCE_PORTAL.md).

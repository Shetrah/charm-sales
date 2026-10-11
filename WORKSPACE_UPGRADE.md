# Charm sales workspace upgrade

The existing Laravel application now provides a responsive purple/teal workspace, persistent device-aware light/dark modes, immediate English/简体中文 switching, readable status badges, a monthly team-sales chart, searchable paginated records, searchable client/team/order selectors, record-detail dialogs, confirmation dialogs, exact-cent order estimates, and asynchronous forms with validation and submission progress. The original logo, favicon, sessions, Sanctum login, account creation, visit/itinerary/report/expense flows, uploads and route endpoints remain in use. Financial summaries cover all authorised records and are independent of list filters. Verified payments and outstanding balances are all-time values; sales belong to the selected confirmation month.

## Run or upgrade

The workspace index migration has already been applied in this local Supabase project. The existing development server continues to serve port 8000. On another installation:

```powershell
composer install
php artisan migrate --force
php artisan optimize:clear
php artisan serve --host=127.0.0.1 --port=8000
```

No Node build is needed to run the application. JavaScript and CSS are served from `public/`. For local HTTP, set `APP_URL=http://127.0.0.1:8000` and `SESSION_SECURE_COOKIE=false`. For production HTTPS, use the production URL and `SESSION_SECURE_COOKIE=true`, `APP_ENV=production`, `APP_DEBUG=false`. Keep the document root at `public/`.

## Translations and preferences

The shared source catalogues are `lang/en.json` and `lang/zh_CN.json`. JavaScript uses generated `public/translations.js`; Laravel validation files are generated from the same templates. After editing translations:

```powershell
python tools/build-translations.py
php artisan view:clear
```

Theme is applied by a small head script before styles load. Language and theme persist in local storage; a language cookie also selects server translations, while API clients can send `X-Locale: en` or `X-Locale: zh_CN`. Switching does not request records again. Dates display in Africa/Nairobi; numbers follow the chosen locale and retain KES. Product categories and fragrance labels are mapped for display only. Stored names, notes, barcodes, capacity anomalies, prices and historical order descriptions are not rewritten. Signature-fragrance wording should still receive the business team's marketing review.

## Query and API changes

`GET /workspace/summary?month=2026-10` uses two aggregate queries without financial caching. `GET /workspace/records/{kind}` accepts `q`, `status`, `page`, `per_page` (default 20, maximum 50) and `sort` (`newest`, `oldest`, `name`, `amount`). Order queries also accept `confirmed=1` and a confirmation month. Responses include `records`, `total`, `page`, `last_page`, and `per_page`. Record details and order items load through `GET /workspace/records/{kind}/{id}`. These endpoints use session authentication, active-account checks, owner scoping and private/no-store headers. Team-account endpoints remain admin-only and exclude passwords and remember tokens.

The existing `/api/snapshot` endpoint and response keys remain, with **bounded collections**: `page` and `per_page` (default/maximum 50), plus per-collection `pagination` continuation metadata. Mobile clients must follow `has_more` rather than assuming that one response contains every historical record. Use `monthly_sales`, `outstanding`, `verified_paid`, and the grouped `chart` for complete totals, rather than summing paged arrays. Existing route APIs have not changed.

The product catalogue is cached for five minutes and invalidated after price edits. Owner records and financial totals are not shared in cache. Composite indexes support owner pagination, confirmed-month queries and verified-payment joins. Referenced products are retrieved in one query during order submission rather than once per line. Substring searches remain `LOWER(...) LIKE` queries; very large datasets may warrant reviewed trigram indexes, not currently installed.

## Financial correctness

Confirmation and verification retain their transactions and row locks. Only confirmed orders count as sales; only verified payments reduce balances. Confirmation timestamps and new workflow timestamps now write UTC, with explicit UTC database-session configuration and Nairobi reporting boundaries. This fixes the observed late-night month-shift bug. Existing database timestamps have not been rewritten. If older confirmed transactions exist, separately audit late-month records before considering any historical correction.

## Verification

```powershell
php tests/account-smoke.php
php tests/dashboard-smoke.php
php tests/localisation.php
php tests/http-workspace.php
php tests/financial-workflows.php
php tests/render-ui-fixtures.php
npm ci
npm run test:ui
php tests/performance.php
```

Account checks use isolated SQLite. Financial checks use the configured PostgreSQL database inside a rollback-only transaction with an isolated in-memory cache: exact 49.30 order arithmetic, bottle/carton units, idempotent UUID retries, ownership and admin restrictions, Nairobi month boundaries, pending/verified payment behavior, duplicate approvals, excess-payment rejection, scoped pagination/search, snapshot bounds, private account details, reference-cache invalidation, itinerary approval, GPS-visit persistence and private photo upload/signed-download behavior with mocked Storage. Fixture rows do not remain after completion. HTTP-kernel checks verify authenticated screens, private/no-store headers and anonymous-request rejection. Concurrent multi-worker verification has not been load-tested; the existing order/payment lock sequence is retained.

UI checks execute the actual rendered Blade templates and production JavaScript in jsdom. They cover every main panel in both themes and languages, no-data-reload switching, preserved input, translated errors, confirmation/details, search debounce, pagination, duplicate submissions, password visibility, date formatting, responsive CSS rules, reduced motion and at least 4.5:1 contrast for the checked text tokens. Browser automation was unavailable in this session: visual desktop/tablet/mobile QA, actual native dialog/layout behavior, device GPS and real Storage uploads remain to be verified. DOM simulation does not measure screen layout.

## Observed performance

Read-only timings against the same small local Supabase dataset, from three successive rendered-dashboard runs (including database access and Blade rendering):

| Metric | Before | Updated warm reference cache |
|---|---:|---:|
| Queries per dashboard | 10 | 2 |
| Run 1 | 6,243 ms | 1,328 ms |
| Run 2 | 6,160 ms | 1,616 ms |
| Run 3 | 6,171 ms | 1,759 ms |
| Mean | 6,191 ms | 1,568 ms |
| Initial HTML | 43,917 bytes | 49,959 bytes |

Observed mean rendering time dropped approximately 75%; this is not a large-dataset or production load benchmark. An observed cold-cache run took 6,487 ms with three queries, demonstrating connection/cache variability. HTML grew approximately 14% because the functional forms and controls expanded. Translation scripts are separate reusable assets; historical record collections are no longer embedded in the dashboard. Opening a list adds its paginated database request. Supabase/network latency still affects perceived speed.

Payroll, commissions, background web tracking, MFA and password-reset onboarding remain outside this upgrade.

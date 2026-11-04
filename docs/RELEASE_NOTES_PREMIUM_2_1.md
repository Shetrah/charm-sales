# Charm Company Hub 2.1.0 — Premium UI release

## Scope
This release is a frontend presentation and usability update. It preserves the existing Supabase schema, migrations, RPC definitions, authentication, role checks, plugins/integrations, storage configuration, business rules and stored business records.

## Included
- Premium shared visual layer for page headings, cards, controls, forms, dialogs, focus states and responsive spacing.
- Mobile-first PWA bottom navigation reduced to four role-appropriate primary destinations plus a More button that opens the existing role-filtered navigation drawer.
- Mobile finance navigation prioritizes Dashboard, Expenses, Cashbook and Disbursements; all other finance destinations remain in the existing sidebar.
- Finance navigation now includes a Contra Entry information destination.
- Finance purchase area is labelled Raw material purchases, matching the existing purchase-order, goods-receipt and supplier-invoice workflow.
- Expenses page separates the existing company expense register from raw-material purchasing and exposes the existing operating-entry RPC as a dedicated operational / financial expense action.
- Operating expenses are posted through the existing finance RPC, against the selected account, and the UI limits manual expense categories to Operational, Financial and Other.
- Visit photos are explicitly optional. Existing GPS capture and all other business/approval requirements remain intact.
- PWA shell cache version bumped so deployed clients fetch the updated UI assets. Private business records and authenticated requests remain excluded from service-worker caching.
- App/package version bumped from 2.0.0 to 2.1.0.

## Contra entry limitation
The UI includes the requested Contra Entry destination, but recording is intentionally not enabled in this UI-only release. The existing backend does not provide an atomic two-account transfer operation. Creating separate expense and receipt postings would distort financial totals and risk a one-sided transfer. A safe contra operation requires a secured backend function that posts both account legs together, prevents duplicates, audits the transfer and supports reversals. No backend or database change has been made here.

## Evidence requirements
Visit photos are optional and finance requests already state that supporting documents are optional; existing payment-confirmation attestations, contract documents, GPS capture and other essential controls have not been weakened. No database-side evidence constraints were altered.

## Verification
The TypeScript project check (`tsc -b --pretty false`) passed after the frontend changes. The production bundle and Vitest suite could not be completed in this Linux workspace because the uploaded dependency tree contains Windows Rollup native binaries but not the required Linux optional package (`@rollup/rollup-linux-x64-gnu`). A clean `npm ci` was also blocked here by package-registry DNS resolution. This is an environment/dependency-platform limitation, not a passing build or test result. On the normal development machine, run `npm ci`, `npm run build`, `npm test`, and `npm run test:e2e` before publishing.

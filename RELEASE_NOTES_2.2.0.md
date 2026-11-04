# Charm Company Hub 2.2.0 — Premium UI Modernization

## Scope

This release modernizes the existing React/Vite application presentation while retaining the established Supabase integration, authentication, role gates, data-access helpers, business records, plugins, and existing RPC contracts. The only database addition is the separately documented contra-transfer migration requested for the new Finance feature.

## User experience

- Rebuilt the visual system around the Charm logo's violet `#2905A1` and teal `#00BDB5` colours.
- Refreshed the workspace/sidebar, mobile header, login screen, portal cards, dashboards, records, forms, dialogs, buttons, statuses, tables, navigation and cards.
- Introduced role-aware mobile bottom navigation with a More drawer for remaining permitted destinations.
- Improved touch target sizes, safe-area spacing, narrow-screen layouts, text wrapping, horizontal overflow handling and responsive cards.
- Applied consistent premium styling to Sales Operations, Production, Logistics, Visits, People, Reports and Finance.
- Preserved English/Chinese language controls and existing light/dark preference behaviour.
- Updated PWA install theme and shell cache version while retaining the existing service-worker caching/security policy.

## Finance changes

- Raw-material procurement is clearly labelled **Purchase · raw materials** and remains in the existing purchase order → goods receipt/QC → supplier invoice workflow.
- Finance Expenses remains the company expense register and existing expense-request workflow.
- Added a clear **Record other operational / financial expense** action using the existing `finance_record_operating_entry` RPC. It supports the existing operational, financial and other categories and can post against the selected existing account.
- Added **Contra Entry** UI for moving funds between active company-owned cash, bank and M-Pesa accounts. It records source, destination, amount, date, reference and description; requires the source balance; and shows transfer balances/history.
- Contra transfers are not revenue or expenses. The migration posts matching cashbook legs in one transaction, updates account balances, and excludes transfer legs from income/expense and cashflow totals.

## Evidence requirements

Visit photos and general supporting documents remain optional where the existing workflow already permits it. Essential controls remain in place for customer payment confirmation, finance disbursement/payment attestations, contractual evidence, GPS check-in consent and production quality control.

## SQL Editor migration

Run `supabase/sql-editor/20261104_finance_contra_transfers.sql` once in the correct Charm Supabase project before using Contra Entry. The migration is additive and does not rewrite historical rows. It assumes the existing Charm finance migrations and helper functions are already deployed. The frontend does not run migrations automatically.

## Preservation checks

- `src/lib/supabase.ts` unchanged.
- `src/lib/data.ts` unchanged.
- Existing Supabase migration history unchanged; the new contra migration is additive.
- Existing npm dependencies and scripts unchanged; only the app version was updated.
- Existing Supabase API/RPC contracts reused except for the new contra RPCs introduced by the provided SQL migration.

## Verification status

- TypeScript project check: passed (`tsc -b --pretty false`).
- SQL Editor migration copy in `supabase/migrations/` and `supabase/sql-editor/`: byte-for-byte identical.
- ZIP integrity: verified after packaging.
- Full Vite build and Vitest startup: not verified in this Linux packaging environment because the supplied `node_modules` does not include Rollup's Linux optional binary (`@rollup/rollup-linux-x64-gnu`). Reinstall dependencies on the Windows development machine with `npm ci`, then run `npm run build`, `npm test` and `npm run test:e2e`.

# Visual system 3.0 (presentation only)

This update restyles the whole portal with one modern design layer, `src/modern-theme.css`,
which loads last so it governs the final appearance.

## What changed
- Design tokens for light and dark themes (brand violet and teal retained), applied across every page.
- Sidebar, header, phone tab bar and drawer restyled; sidebar footer utilities are full-width and readable.
- Buttons, inputs, tables, badges, stat tiles, finance KPI tiles, dialogs, notices and empty states restyled.
- Inter font loaded from Google Fonts (the CSS already named it).
- Phone header fits on narrow screens; the language switch is icon-only on phones.
- Phone drawer now sits above its backdrop; the shadow shows only while the drawer is open.
- Service-worker shell cache renamed so returning users receive the new shell.

## What did not change
No TSX logic, routes, translations, Supabase migrations, RPCs, RLS, storage or permissions were modified.
Printable document and contract previews keep their existing paper layout (`documents.css`, `contract.css`).

## Verification
- Production build (`npm run build`) passes.
- Screens checked in light and dark mode on desktop (1440px) and phone (390px): login, overview, clients,
  orders, finance, people, field travel, create-record dialog, phone drawer, salesperson views.
- Unit tests: 105 of 113 pass. The 8 failures are in `tests/finance.test.ts` (PGlite finance controls) and
  fail identically on the original upload, so they are not caused by this update.

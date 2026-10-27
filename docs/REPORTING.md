# Management reporting and AI narrative

Admin users open **Management reports** at `/reporting`. The page reads only recorded visits and orders through
`charm.build_sales_report` and stores a reproducible snapshot in `charm.management_reports`.

## Data flow

1. `refresh_management_report(period, date, salesperson, client)` is admin-only.
   - Resolves daily / weekly (Monday–Sunday) / monthly bounds in `Africa/Nairobi`.
   - Serialises concurrent generation with an advisory lock per period and filter set.
   - Hashes the snapshot (excluding `generatedAt`). An unchanged hash reuses the snapshot (`cached: true`).
   - A changed hash archives the previous snapshot, narrative, model and generation time in
     `charm.management_report_versions`, then increments `version`.
   - Returns the report row; the frontend then requests a narrative without blocking the page.
2. Triggers on `charm.visits` and `charm.orders` mark affected reports `is_stale` until refreshed.
3. `build_sales_report` returns factual totals, previous-period totals, salespeople, visit detail and order detail.
   Order values are described as recorded/confirmed order values, never verified revenue.

## Narrative

The factual snapshot is always available. The narrative is an optional layer:

- `report-ai` Edge Function (admin JWT required) minimises the snapshot, calls an OpenAI-compatible provider,
  validates a strict six-section JSON object and stores it through `charm.store_ai_narrative` with the service role.
- If the function, provider or key is unavailable, the page stores a deterministic summary built from the same facts
  through `charm.store_report_narrative` with status `template`. No record is lost and no fake AI text is shown.
- `ready` narratives are labelled **AI interpretation**; `template`, `failed` and unavailable states are labelled as
  facts. Management insights explicitly state they are not forecasts.

### Required configuration (server-only)

Set these as Supabase Edge Function secrets. Never place them in `VITE_*` variables, the bundle or `localStorage`.

| Secret | Purpose |
| --- | --- |
| `REPORT_AI_API_KEY` (or `OPENAI_API_KEY`) | Provider key. Without it, reports use the deterministic summary. |
| `REPORT_AI_MODEL` | Optional model name. Default `gpt-4o-mini`. |
| `REPORT_AI_API_URL` | Optional OpenAI-compatible chat-completions endpoint. |
| `ALLOWED_ORIGINS` | Optional comma-separated CORS allow-list, same as `add-staff`. |

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are injected by Supabase.

```bash
supabase functions deploy report-ai
supabase secrets set REPORT_AI_API_KEY=... REPORT_AI_MODEL=...
```

Until this is deployed and tested, the interface shows the deterministic summary with an explicit non-AI status.
It does not claim that AI is active.

## Safety and cost controls

- Only admins can read reports or invoke `report-ai`; the function re-checks `charm.is_admin()`.
- The provider receives at most 60 visits, 40 orders and 30 salespeople, with note fields truncated to 700 characters.
- Phone numbers, emails, addresses and storage paths are not part of the snapshot.
- User-written notes are labelled untrusted in the system prompt; instructions inside them are treated as data.
- Provider calls time out after 30 seconds, retry once on 429/5xx, and log only status/error codes, never prompts or keys.
- Narrative validation rejects missing sections, non-string values, empty sections and oversized output.

## Exports

All exports are generated from the stored snapshot, so a downloaded file matches the version shown:

- **PDF** — branded letterhead, period, version, KPIs, outcome/salesperson bars, narrative sections, footer disclaimer.
- **XLSX** — Summary, Salespeople, Visits, Orders and Narrative sheets with numeric cells and stable headers.
- **CSV** — same facts plus a narrative sheet section, using the existing formula-injection-safe CSV escaping.

The XLSX writer is dependency-free (`src/lib/xlsx.ts`) and produces a standard ZIP/OpenXML workbook.

## Verification

```bash
npm run test        # migration + unit tests (PGlite)
npx tsc -b
npm run build
```

Reporting must be checked with a real admin account against the migrated database. Without database credentials,
routing, type checks, builds and migration tests can be verified locally, but live snapshot generation and the
provider call cannot be claimed as tested.

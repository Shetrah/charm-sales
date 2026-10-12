# React Native / Expo API contract

Use Supabase Auth sessions with the public project URL/key and refresh-token storage through Expo SecureStore. The existing `charm.auth_accounts` mapping preserves salesperson IDs. Never ship a database password or service-role key in the app. Call RPCs on the `charm` schema; PostgreSQL applies the same authorization as the web application. Keep all monetary strings unchanged through JSON and offline storage.

| RPC | Parameters | Result |
|---|---|---|
| submit_order | p_key UUID, p_client bigint, p_due date/null, p_items array of product_id, quantity integer, unit bottle/carton, unit_price decimal string | order ID |
| submit_payment | p_key, p_order, p_amount decimal string, p_reference, p_received UTC ISO timestamp, p_notes/null | payment ID |
| submit_record | p_key, p_kind plans/expenses/reports, p_date Nairobi date, p_client/null, p_budget decimal string/null, p_notes, p_follow_up/null | record ID |
| submit_visit | p_key, p_client, p_lat, p_lng, p_accuracy, p_outcome, p_notes, p_reason/null, p_next/null, p_follow_up/null | visit ID |
| checkout_visit | p_id | void |
| start_workday | none | workday ID |
| end_workday | p_id | void |
| location_batch | p_workday, p_points array of submission_key UUID, latitude, longitude, accuracy_m, recorded_at UTC ISO timestamp | accepted input point count |
| monthly_summary | p_month date | exact decimal string totals and team breakdown |

Read records with authenticated RLS-scoped paginated table queries. Use stable `(recorded_at,id)` ordering for route replay. For writes, persist a UUID and its immutable canonical payload before sending; retry the identical payload/key after timeout. New edits require a new key. Receipts reject UUID reuse with a different actor, operation or payload. Location batches are atomic, 1–200 points, and idempotent per point UUID. Delayed locations recorded between the server's workday start/end can sync after the day closes; timestamps outside those bounds fail. Obtain server start time from the workday record before queueing. Device clock skew should be detected against server timestamps, and invalid batches should be split for explicit user review rather than silently changing evidence timestamps.

Workday starts/ends currently require connectivity, and visit check-in/check-out timestamps are server-generated. A future app should not promise fully offline visit check-ins until an explicit trusted timestamp/device validation design is implemented. Only the location batch contract supports delayed recorded timestamps today. Expenses require a client and a future Nairobi date. Failed sales require an explicit reason.

Upload photos to private `charm-private`, using `{visits|payments}/{record_id}/{random_uuid}.{jpg|png|webp}` after record creation, then `attach_file(p_kind,p_id,p_path)`. File limits are 5 MB and image types only. Read through short-lived signed URLs; never cache them as public object links. Reconcile orphaned uploads server-side; clients cannot overwrite/delete evidence. Proof attachments to verified payments are immutable.

Native background tracking requires an implemented Expo location task, Android/iOS permissions and visible tracking state, consent, retention limits, battery-aware sampling, encrypted account-scoped queue, logout cleanup and physical-device testing. The existing browser only captures location on explicit action while open. Its manual status is not evidence that a background service is running. The future app should store device/platform/tracking mode separately before advertising native background status; this migration does not invent native heartbeat data.

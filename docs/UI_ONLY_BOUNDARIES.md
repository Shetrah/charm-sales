# UI-only update boundaries

This update intentionally changes only frontend presentation, navigation, translations, app metadata, service-worker shell cache version and documentation.

No Supabase migration, SQL function, RPC signature, RLS policy, table, view, trigger, storage bucket, authentication provider or external integration was changed.

A true contra entry is not representable safely through the currently exposed frontend APIs. It must not be emulated with a revenue entry plus an expense entry. The required future backend operation must post a balanced outgoing and incoming ledger pair atomically, retain one unique transfer reference, audit both accounts, prevent duplicate submissions and support a controlled reversal.

## Evidence controls retained

Visit photos are clearly labelled optional in the visit workflow. Existing finance-request supporting documents are optional where the workflow already permits them. Payment confirmation, required order contract documentation, GPS capture, purchase goods-receipt/QC controls and approval checks remain in place. This UI update does not relax server-side evidence requirements.

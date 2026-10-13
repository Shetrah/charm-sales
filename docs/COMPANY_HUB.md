# Charm Company Hub setup

Apply reviewed migrations **021** after 001–020. For a partial finance install, use `supabase/finance-upgrade-reviewed.sql` after baseline 001–009 instead. Historical migrations remain necessary.

Migration 021 consolidates Finance Manager, Management and Auditor accounts into Finance Officer, preserving IDs and records. Review any existing accounts with those former roles: they receive the consolidated Finance Officer permissions. Assignable roles are Admin, Salesperson and Finance Officer.

Admin lands at `/admin`, Salesperson at `/sales`, Finance Officer at `/finance`. Admin's Company portals chooser accesses all portals. Salespeople access their own finances at `/my-requests`. Only Admin approves staff and supplier requests. Self-approval is blocked; an officer may pay an Admin-approved supplier request they created because the verified recipient is the supplier.

## Temporary-password staff creation

Deploy `supabase functions deploy add-staff --project-ref YOUR_PROJECT_REF`. Set `ALLOWED_ORIGINS` to comma-separated exact site origins, including `https://charm-sales.vercel.app` and any custom domain. Server credentials belong only in Edge runtime, never Vite variables.

The function validates the Auth token and Admin permissions, creates an email-confirmed Supabase Auth account, then links the existing company staff ID where applicable. Temporary passwords require at least 12 characters and are never stored in company tables, audit logs or request receipts. Admin shares the password directly with the employee; adding staff needs no invitation email or SMTP. Staff can change it from the sidebar's Update password link. Configure Supabase Auth's password policy at least as strongly as the UI minimum.

If account creation succeeds but database linking fails, the Auth account is preserved and cannot access company data until Admin verifies and reconciles its email/UUID mapping. Existing Auth accounts are not overwritten or reset: edit their staff information or use password recovery. SMTP and callback URLs remain necessary for forgotten-password emails. Remove the old hosted `invite-staff` function after verifying the replacement; deleting local source does not uninstall hosted functions.

Rebuild/redeploy the frontend after migrations and function deployment. Verify account creation, password changes, role routing, approval, reconciliation and mobile navigation against hosted staging. Local tests use an isolated PostgreSQL/Auth fixture and do not verify hosted Edge/Auth responses.

## Cleanup

Unused Laravel source, Composer/vendor dependencies, PHP tests, duplicate legacy assets, compiled views/sessions/cache and obsolete Laravel documentation were removed. React source/assets, npm dependencies, catalogue source, SQL history, current tests and deployment guides remain. Git metadata and private configuration are preserved. No hosted database, Auth or Storage records were deleted.

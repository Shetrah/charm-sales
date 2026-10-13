# Fix “Supabase configuration is missing” on Vercel

Local `.env.local` is intentionally ignored by Git and is not uploaded to Vercel. Vite embeds public variables at build time, so a deployed build must be rebuilt after changing environment settings.

In the Vercel project that serves `charm-sales.vercel.app`, open Settings → Environment Variables and add:

| Name | Value |
|---|---|
| `VITE_SUPABASE_URL` | The same public Supabase project URL as the working local app |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | The same public publishable key as the working local app |

Select Production; select Preview too if using preview deployments. Add actual values, without surrounding quotes. Then open Deployments → latest deployment → Redeploy. Merely adding variables does not update existing JavaScript. Keep framework Vite, build `npm run build`, output `dist` and root directory `.`.

Do not upload the Laravel `.env`, database password or Supabase service-role key. Only public Supabase configuration belongs in these `VITE_` variables.

For Auth email/reset callbacks, add `https://charm-sales.vercel.app/auth/callback` to Supabase Auth Redirect URLs. If using that domain as the live portal, set its origin as Site URL too. For the staff-invite Edge Function, include `https://charm-sales.vercel.app` in `ALLOWED_ORIGINS` and set `AUTH_REDIRECT_URL` to its callback URL; preserve other explicitly authorized local/custom-domain origins as needed.

Sources: [Vite environment variables](https://vite.dev/guide/env-and-mode), [Vercel environment management](https://vercel.com/docs/environment-variables/managing-environment-variables).

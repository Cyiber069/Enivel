# Enivel Worker setup — SMS codes + driver pop-up reminders (about 20 minutes, free)

One small Cloudflare Worker does two jobs:
1. sends the 6-digit SMS codes (BulkSMS), and
2. every minute, sends due pickup reminders to drivers' phones, even when Enivel is closed.

## A. Accounts
1. **BulkSMS** (bulksms.com): sign up, buy a small bundle (about R100), create an API token in the dashboard.
   Make the login value: base64 of `username:password`
   (Windows PowerShell: `[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("username:password"))`).
2. **Cloudflare** (dash.cloudflare.com): free account.

## B. Create the Worker
1. Workers & Pages → Create → Worker → name it `enivel` → Deploy.
2. **Edit code** → delete everything → paste all of `worker.js` from this repo → **Deploy**.
3. **Settings → Variables and Secrets**, add:

| Name | Type | Value |
|---|---|---|
| `BULKSMS_TOKEN` | Secret | base64 value from A1 |
| `OTP_SECRET` | Secret | any long random text (40+ characters) |
| `SUPABASE_SECRET` | Secret | Supabase → Project Settings → API Keys → **Secret key** (`sb_secret_...`) |
| `VAPID_PRIVATE_JWK` | Secret | the whole contents of `vapid-private-key.json` (sent to you separately, not in GitHub) |
| `SUPABASE_URL` | Text | `https://kakzsotpfzgghlfanaut.supabase.co` |
| `VAPID_PUBLIC` | Text | `BKheEhf5bBBdo03cigjmNlnMpnVThdRGP3XezC02uptJGuKtmCx8s1j-FerApO4pNhS3aRJAkRjmpjtzS9s6iog` |
| `VAPID_SUBJECT` | Text | `mailto:acxebikes@gmail.com` |
| `ALLOWED_ORIGIN` | Text | `https://cyiber069.github.io` |
| `SENDER` | Text | `Enivel` |

4. **Rate limits (required for SMS):** Workers & Pages → **KV** → Create namespace `enivel-limits`. Then in the Worker: **Settings → Bindings → Add → KV namespace**, variable name `LIMITS`, namespace `enivel-limits`. This stops people spamming SMS codes at your cost or guessing codes.
5. **Settings → Triggers → Cron Triggers → Add**: `* * * * *` (every minute). Save.
6. Open `https://enivel.<your-name>.workers.dev/health` in a browser. It should show
   `{"ok":true,"sms":true,"limits":true,"reminders":true}`.

## C. Connect it to the app
1. Supabase → SQL Editor → run the latest `supabase/setup.sql` again (adds the reminder sender; safe to re-run).
2. Live app → log in as admin → More → **SMS gateway** → paste `https://enivel.<your-name>.workers.dev` → Save.
3. Driver phones: open the live app → driver home → **Get reminders even when Enivel is closed** → Allow.
   On iPhone: first Share → **Add to Home Screen**, open Enivel from the Home Screen, then tap the button.

Never put `SUPABASE_SECRET`, `VAPID_PRIVATE_JWK` or the BulkSMS login in GitHub or in chat.

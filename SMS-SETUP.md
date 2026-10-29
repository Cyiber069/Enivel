# Enivel SMS codes — setup (about 15 minutes)

Provider: **BulkSMS** (bulksms.com, South African, pay-as-you-go, roughly R0.25–R0.35 per SMS).
The app never holds the BulkSMS password. A small Cloudflare Worker (free) sends the codes.

1. Create a BulkSMS account at https://www.bulksms.com and buy a small credit bundle.
   In the BulkSMS dashboard create an API token, or just use your username and password.
   Make the Basic-auth value: base64 of `username:password` (on Windows PowerShell:
   `[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("username:password"))`).
2. Create a free Cloudflare account at https://dash.cloudflare.com → Workers & Pages → Create → Worker.
   Name it `enivel-otp`, click Edit code, replace everything with the contents of `sms-worker.js`, Deploy.
3. In the Worker: Settings → Variables and Secrets:
   - Secret `BULKSMS_TOKEN` = the base64 value from step 1
   - Secret `OTP_SECRET` = any long random string (40+ characters)
   - Variable `ALLOWED_ORIGIN` = the address where Enivel is hosted (e.g. https://enivel.netlify.app)
   - Variable `SENDER` = `Enivel` (optional)
4. Copy the Worker URL, e.g. `https://enivel-otp.<your-name>.workers.dev`.
5. Open Enivel as admin → More → **SMS gateway** → paste the URL → Save.
   From then on sign-up, phone login and two-step verification send real SMS codes.
   Leave it empty and the app stays in test mode (code shown on screen).

Costs: Cloudflare free tier covers 100 000 requests/day. BulkSMS charges per message only.

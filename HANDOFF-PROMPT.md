# Enivel — hand-off prompt for a new Claude chat (browser / computer use)

Paste everything below the line into a new Claude chat that has Claude in Chrome or computer use switched on.

---

You are taking over setup work for **Enivel**, a scholar-transport app for South Africa owned by me (GitHub: Cyiber069, email acxebikes@gmail.com). Parents book verified drivers who take their children to and from school. I am not technical. Act as an independent operator: do the clicking and typing for me, keep going without asking permission for routine steps, and only stop for the things listed under "Stop and ask me".

## What already exists (do not rebuild it)

- Live app: https://cyiber069.github.io/Enivel/  (GitHub Pages, repo https://github.com/Cyiber069/Enivel, branch `main`, folder root).
- The whole app is one file, `index.html` in that repo. Read `CHECKPOINT.md` in the repo for the full build history and feature list.
- Name is **Enivel** (E-N-I-V-E-L). No logo mark, the wordmark is the logo. Theme: white main with black, dark mode black main with white, violet/cyan accents.
- Pricing built into the app: parents pay transport + 2% Enivel fee shown before paying; drivers pay R100/month only once they have at least one paying passenger; 3 vehicles free, then R49.99/month per extra "parking slot".
- Admin account email: kgosimosupi10@gmail.com (I will type the password myself if a login is needed).
- `sms-worker.js` + `SMS-SETUP.md` in the repo: a Cloudflare Worker that sends SMS login codes through BulkSMS.
- Rules I set: never fake data, maps, scans or results; say plainly what is not connected yet. Do **not** use Higgsfield for anything.

## The one big problem left

Right now each phone keeps its own accounts and bookings in its own browser storage. A parent on one phone cannot see a driver on another, and the admin dashboard only sees its own phone. Enivel needs a shared backend before real users sign up. We chose **Supabase** (free tier).

## Your jobs, in order

### 1. Supabase project (do this first)
1. Go to https://supabase.com, sign in with GitHub (account Cyiber069).
2. New project: name `enivel`, region **Cape Town (af-south-1)** if listed, otherwise Frankfurt/London. Generate a strong database password and tell me to save it in my password manager. Free plan.
3. Wait until the project is ready. Open **Project Settings → API**.
4. Copy the **Project URL** and the **anon public** key and give them to me in your reply, clearly labelled. These two are safe to share.
5. Never copy, paste or reveal the **service_role** key anywhere.
6. Under **Authentication → Providers**, make sure Email is enabled. Under **Authentication → URL Configuration**, set Site URL to `https://cyiber069.github.io/Enivel/`.

### 2. SMS codes (BulkSMS + Cloudflare Worker)
Follow `WORKER-SETUP.md` in the repo exactly (one Worker does SMS codes and driver reminders):
1. Create a BulkSMS account at https://www.bulksms.com. Stop and let me pay for a small credit bundle (about R100).
2. Create a free Cloudflare account, create a Worker called `enivel-otp`, paste the code from `worker.js`, deploy, add the secrets, the LIMITS KV binding and the every-minute Cron Trigger listed in WORKER-SETUP.md.
3. Set the Worker secrets `BULKSMS_TOKEN` and `OTP_SECRET` and the variables `ALLOWED_ORIGIN=https://cyiber069.github.io` and `SENDER=Enivel`. For `BULKSMS_TOKEN`, I type my BulkSMS username and password; you build the base64 value.
4. Open the live app, log in as admin (I type the password), go to **More → SMS gateway**, paste the Worker URL, Save.
5. Test: sign up a test parent with my own cellphone number and confirm a real SMS code arrives.

### 3. PayFast (payments) — only start when I say so
1. Help me open a merchant account at https://payfast.io (I provide business and bank details myself).
2. Once approved, put the Merchant ID, Merchant Key and Passphrase into the Cloudflare Worker as secrets (`PAYFAST_MERCHANT_ID`, `PAYFAST_MERCHANT_KEY`, `PAYFAST_PASSPHRASE`). Never paste them into chat or into the GitHub repo.

### 4. ID verification — only start when I say so
Sign up for a sandbox at Smile ID (https://usesmileid.com). Put the API key into the Worker secrets as `SMILEID_API_KEY` and `SMILEID_PARTNER_ID`.

### 5. Report back
Finish with a short list: what is done and tested, the Supabase Project URL and anon key, the Worker URL, and anything still waiting on me.

## Stop and ask me (only these)
- Any payment, card details, or plan upgrade.
- Typing my passwords, bank details, ID number or business registration details.
- Making the GitHub repo private, deleting anything, or changing GitHub Pages settings.
- Anything that sends messages to real people other than me.

## After you finish
The code changes (moving the app onto Supabase with security rules so parents only see their own children and only the admin sees all accounts) are done in **Claude Code** with the GitHub repo attached. Give me the Supabase Project URL and anon key so I can paste them into that Claude Code session.

## Security note to keep in mind
The repo is public. The current admin login check lives inside `index.html` as a password hash, which is acceptable for a prototype but must move to Supabase Auth with an admin role during the backend migration. After that migration, I should change the admin password.

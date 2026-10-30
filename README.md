# Enivel

Verified scholar transport for South Africa. Parents book checked drivers, get pickup and drop-off alerts, live tracking and one monthly payment.

Live app: https://cyiber069.github.io/Enivel/

## What's in this repository
- `index.html` — the whole app (parents, drivers, private chauffeur, admin), built from the source by `build.sh`.
- `supabase/setup.sql` — the database and its security rules. Run it in Supabase → SQL Editor after every update (safe to re-run).
- `worker.js` + `WORKER-SETUP.md` — the Cloudflare Worker for SMS codes (BulkSMS) and driver pop-up reminders.
- `sw.js` — lets drivers get pickup reminders with Start trip buttons even when Enivel is closed.
- `CHECKPOINT.md` — build notes, decisions and what is still to be connected.
- `HANDOFF-PROMPT.md` — instructions for a browser-based Claude to do account setup.

## Features
**Parents:** verified drivers with badges and reviews; shared, private chauffeur and once-off trips; live map while a child is on board; pickup, drop-off and "driver outside" alerts; journey stepper with progress; schedules incl. exam times and second locations; days off and holiday/closure planner; handover code for home drop-off; trusted guardians; waiting list for full routes; chat with quick replies; SOS; payments with the 2% fee shown up front; referral credit.

**Drivers:** verification with automated screening; vehicles with seat checks; routes, smart stop order, Trip Mode; GPS-verified and automatic pickup/drop-off with undo; 30/10-minute reminders incl. pop-ups when the app is closed; Enivel hours; expenses and profit; on-time score and badges; waiting list handling.

**Admin:** overview, accounts, verification with Approve / Retry / Ban, money ledger, giveaways, announcements, reports, legal details, SMS gateway.

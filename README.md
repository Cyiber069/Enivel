# Enivel

Verified scholar transport for South Africa. Parents book checked drivers, get pickup and drop-off alerts, live tracking and one monthly payment.

- `index.html` — the whole app (parents, drivers, private chauffeur, admin). Hosted with GitHub Pages.
- `worker.js` + `WORKER-SETUP.md` — the Cloudflare Worker for SMS codes (BulkSMS) and driver pop-up reminders.
- `sw.js` — lets drivers get pickup reminders with Start trip buttons even when Enivel is closed.
- `supabase/` — the database setup script and how to run it.
- `CHECKPOINT.md` — build notes and what is still to be connected.

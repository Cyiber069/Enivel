# Enivel — checkpoint (2026-10-29, v3)
Live: https://claude.ai/artifact/RjFH6vUQQa6DAZb1PfQusm   Source: /home/user/enivel/index.html (single file)
Name: Enivel (confirmed). Logo: wordmark only, no icon mark.
Admin: kgosimosupi10@gmail.com (SHA-256 hash in page; pure-JS fallback if crypto.subtle is missing).
Done in v3: sign-in/sign-up first screen, show/hide password, splash animation on reopen, parent home with search bar + interactive house→stop→school scene (sets pickup, stop, drop-off on the user doc), ride options (Shared / Private chauffeur / Once-off trip), once-off trip requests→offers→single payment→driver pick up/drop off, trusted guardians named on alerts, SOS button on tracking/trip pages, ETA on tracking, progress rings, trip timeline.
Fees: 2% parent fee; driver R100/mo once >=1 passenger; 3 vehicles free then R49.99/mo parking slot.
Next ideas: real gateway (PayFast/Yoco), real GPS map, push/SMS, hosted backend for public users, native wrapper.

## v4 (same day)
Added: eye icon password toggle; strict email + SA cellphone validation; phone OTP at signup (test mode shows the code in-app, real SMS gateway still needed); "Log in with phone" via OTP; two-step verification prompt after signup with SMS-code or 4-digit PIN, enforced at login, toggle in Account > Security; logo slides from centre to left on open; glass header; page transition fade; richer 3D scene (gradients, shadows, pine trees, pulse when a child is on board); referral codes with R50 credit for both, credit applied at monthly payment; "Not riding today" per child (driver sees it); driver pickup-order editor and parent "Stop N of M"; Mon–Fri attendance strip; driver on-time score (home KPI + route cards).

## v5 = Enivel 2.0
- Fixed giant phone icon (.btn svg sizing). Accent colours (violet/cyan/amber) for animations, ride icons, rings, KPIs, tabs; aurora background on sign-in; shimmer buttons; border-beam on a child's card while on board; animated road dashes; number tickers on admin KPIs; gradient splash with loader.
- Admin header has Admin | App switch (App = parent-side experience with the admin account). Demo-data button removed from overview; overview warns when demo records are present.
- Screening engine (screenUser): ID checksum, impossible DOB, age <18, duplicate ID across accounts, duplicate/identical document images across accounts and within a submission, low resolution and blur (Laplacian) per photo, police clearance >6 months or future-dated, PrDP expired, missing docs. Suspicious -> admin notified. Verify page shows flags per driver AND parent with Approve / Retry photos (note sent) / Ban·fake (permanent; logs out, cancels bookings, pauses routes, login refused). Lift ban available.
- Reviews page per driver (average, 1–5 distribution, comments, on-time %, passengers). Linked from route cards, driver home rating KPI, driver More.
- NOT connected: a real third-party ID/Home Affairs verification API and SMS gateway. Seat scan is a heuristic. Payments test mode.

## v6 = Enivel 2.1 (maps, GPS, schedules)
- Real maps: Leaflet + OpenStreetMap tiles, Nominatim geocoding + address autocomplete (ZA, structured: number, street, suburb, city, province, postcode), OSRM road routing with km/min. All of this is BLOCKED inside the claude.ai artifact preview (tiles, fetch, GPS refused) and shows honest "needs the hosted app" fallbacks. It works when index.html is hosted on a normal https site.
- Driver GPS: watchPosition every 5 s into route.live; parents see car on map only while their child is on board. Pickup/drop-off are geofenced (200 m + GPS accuracy) against the pinned address; blocked otherwise with the distance shown. Events store driver coordinates + verified flag. "📣 I'm outside" hoot (sound on driver, chime + alert on parent). Proximity alert at 500 m.
- Progress bar + ETA from real distance (pickup point -> school vs driver position). No simulation anywhere now.
- Schedules per booking: normal times, second location (days + time), exam window (dates, days, school pickup). Parent proposes, driver accepts/declines with reason; parent home shows today's agreed times with an "Exam time" tag.
- Day off scheduling with reasons; SA public holidays 2026–27 with 7-day notice; driver "Not driving a day" broadcast to their parents; PrDP/police-clearance expiry reminders; admin announcements; CSV statements (downloads capability); driver earnings chart.
- Hosting: no GitHub token in this session; user said NOT to use Higgsfield (an empty placeholder site "enivel-app" was created there before the instruction; nothing deployed). Next: host index.html on Netlify/Vercel/GitHub Pages for real maps + GPS.

## v8 polish (same day)
Intro slides on first visit; parent journey stepper (Driver out → Picked up → On the way % → At school); driver next-stop card + full-screen Trip Mode (nearest pending child by GPS, I'm outside / Picked up / Dropped off, queue strip); driver badges (Verified, 25+/100+ trips, On-time pro, 5-star, experience); confetti after payment and first verified login; swipe-to-dismiss sheets; typed toasts with icons; unread count on bell; notifications grouped Today/Earlier; chat quick replies + read ticks; colour avatars; spotlight hover on cards; skeleton while shared storage loads; PWA manifest + theme colour + apple icon (install to home screen works when hosted); empty-state art.

## SMS provider chosen: BulkSMS via Cloudflare Worker
Files: sms-worker.js (Worker code: /send signs an HMAC token + sends SMS through BulkSMS; /check verifies), SMS-SETUP.md (15-min setup). App: Admin → More → SMS gateway stores otpEndpoint in settings/config; otpModal uses the Worker when set, else test mode.

## Hosting
Live at https://cyiber069.github.io/Enivel/ (GitHub Pages, main branch, root). The hosted index.html wraps the app source with a full <head> incl. viewport meta (build.sh). Phone fit tested at 320, 390, 430, 768 and 1366 px.

## Live database (Supabase) — built and tested
- Project URL https://kakzsotpfzgghlfanaut.supabase.co, publishable key in index.html (public by design).
- `supabase/setup.sql`: one closed `docs` table + security-definer functions fetch_docs / put_doc / del_doc /
  award_referral / phone_taken / is_admin, admins table auto-filled for the owner email (first account only).
  Tested with 36 rule checks on real Postgres (PGlite).
- App: on the live site it detects Supabase, signs in with Supabase Auth, syncs every 6 s (full refresh every 60 s),
  defers re-render while the user is typing or a sheet is open. Preview on claude.ai keeps its own storage.
- Demo ("Try demo") runs fully in the browser, marked with a yellow bar, writes nothing to the live database.
  Demo accounts: naledi@demo.enivel, brasipho@demo.enivel, admin@demo.enivel, password demo1234.
- Live build (build.sh) strips the preview-only admin password hash. Admin on the live site = Supabase account.
- End-to-end test with four separate phones: 23/23 pass (sign-up, referral, privacy, approve, book, geofenced
  pickup alert, live-location privacy, admin money, PIN 2FA, ban, demo isolation).
- Owner must: run setup.sql, set Confirm email off, set Site URL, create admin account with a NEW password.
- Later: real email sender (SMTP) then Confirm email on; phone-number login via Supabase phone auth;
  move photos to Supabase Storage; realtime instead of polling at scale.

## Pickup reminders + chauffeur prompts
Driver gets in-app reminders 30 and 10 minutes before each pickup (route pickup time, agreed schedule incl. exam school pickup, once-off trips). Catches up if the app is opened late; stacks if several are due; skipped once the trip is started, child picked up or absent, weekends, SA public holidays, driver off days. Countdown card on driver home. Phone pop-ups when the driver allows notifications and the app is open or in the background; true push with the app fully closed needs a push service later. Private chauffeur: setup card on driver Routes, request button on parent Find when none listed. Uber/Bolt order integration: not possible (no public API to receive/accept trips).

## Driver convenience (auto pickup, Enivel hours, phone pop-ups)
- Auto pickup/drop-off: during an active trip with GPS, a stop of 45 s inside ~60–120 m of a child's home then driving off marks pickup (recorded at the stop position); 30 s at school marks drop-off; afternoon school pickup only after 11:00 / near agreed time. Siblings share one 10-second Undo; Undo deletes the event and alert and tells the parent. Driver setting in More (default on).
- Enivel hours card on driver home: today's windows from routes + agreed schedules, "Free for other work until 14:15 / go offline by 14:05".
- Phone pop-ups: sw.js + Web Push (VAPID). Driver app saves a 7-day reminder plan to its own profile; Supabase due_push() (service role only) picks due items, drops absent / already-picked-up children, skips started trips; Worker cron every minute encrypts (RFC 8291) and sends. Buttons: Start trip / Open Enivel. iPhone needs Add to Home Screen first. Tested: SQL 7/7, encryption decrypts with independent library, VAPID signature verifies. Not testable here: real delivery to a phone.
- VAPID public key in app + WORKER-SETUP.md; private key given to the owner separately, not in git.
- Four-phone live test now 26/26.

## 30 Oct 2026 — bug sweep + legal pack (terms version 2026-10-30)
Fixed (from an independent code review, each replayed in a browser test):
- XSS: notification links (client whitelist + server strips), image src (safeImg + server only accepts data:image/*), no user text in inline handlers (removeKid, journey search).
- Money: giveaway pays the transport price once and blocks already-paid months; payment status is per booking (no double charge, sponsored months count as paid); Enivel credit applies to every payment and is recorded (credit_used) so profit/paid totals are right; parking slots charged every month; R100 driver fee re-checked whenever passengers/slots/month change.
- Data: removing a child cancels its bookings and tells the driver; pages survive missing children; orphan bookings auto-cancelled.
- Live site: server enforces route capacity and one account per phone; parents see true seat counts and driver stats (route_load, driver_stats); suspended accounts are signed out; due_push only uses children booked with that driver; phone_taken no longer open to anonymous callers.
- Worker: KV-backed rate limits (3 codes/phone/15 min, 10/network/hour), 5 tries per code, single-use codes, constant-time compare. Owner must add the LIMITS KV binding.
- Dates use the local (SA) day everywhere; reminder sender uses Africa/Johannesburg.
Legal: Legal centre with 11 documents (~8,000 words): Important terms (CPA s49), Terms of Service, Driver Agreement, Privacy Policy (POPIA incl. s26/35/71/72), Child Safeguarding, Payments & refunds, Acceptable use, Location & automated features, Device storage, Complaints & disputes (mediation/AFSA, consumer forums preserved), PAIA summary. Acceptance recorded per user with version; existing users must accept new versions; parent consent recorded per child; drivers now upload operating licence/permit and passenger liability insurance; drivers under 21 flagged. Company details editable in Admin → More → Legal details (placeholders highlighted until filled).
Tests: database 46/46, reminders 8/8, Worker 9/9, push crypto 2/2, four-phone live test 29/29, browser regressions all pass.
Needs a South African attorney's review before launch.

## 30 Oct 2026 (round 9)
- Demo mode removed everywhere (link, admin buttons, loader stubbed; leftover demo data purged in preview). Only real accounts.
- Theme: light by default on every device (ignores phone dark setting); no header toggle; after first sign-in a "Choose your look" sheet; saved per account (users.theme); change in Settings (tab renamed from More).
- Map: OpenStreetMap tiles tinted to match light/dark, cached per screen (no rebuild/flicker on refresh), recenter + follow-vehicle buttons, numbered stops on driver map, road route with casing.
- Parents: Handover code (hashed per child; home drop-off needs the code or the parent's in-app confirmation; 5 wrong tries alert the parent). Holidays & closures planner (termBreaks; days off, driver told, reminders skip).
- Drivers: Smart stop order (nearest-neighbour + 2-opt from GPS or farthest stop; km estimate). Expenses & profit (private 'expenses' collection; month KPIs, categories, 6-month table).
- Waiting list for full routes ('waitlist' collection; driver app offers freed seats to first in line for 24 h).
- Pickup/drop-off location now correct for afternoon school pickup and home drop-off (stopPoint/stopLabel).
- Legal: v2 pack, 16 documents ~23,500 words (new: Parent Terms, Vehicles & insurance, Security & breach, Incidents & emergencies, Promotions). TERMS_VERSION 2026-10-30.2 forces re-acceptance. Attorney points listed in chat.
- Tests: database 54/54, reminders 9/9, Worker 9/9, four-phone live 29/29, new features 28/28, all older browser suites pass.

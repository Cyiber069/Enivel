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

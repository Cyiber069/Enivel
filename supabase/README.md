# Switch on the Enivel database (about 3 minutes)

1. **Run the setup script.** Supabase dashboard → your `enivel` project → **SQL Editor** → **New query**.
   Open `supabase/setup.sql` from this repo, copy all of it, paste, click **Run**.
   The result should say `Enivel backend ready`. Running it again later is safe.

2. **Email sign-in settings.** Authentication → **Sign In / Providers** → **Email**:
   - Email provider: **on**
   - **Confirm email: off** for now. Supabase's built-in email sender only delivers to your own team
     and about 2 emails an hour, so new users would never receive the link. Phone codes still verify people.
     Turn it back on after connecting a real email sender (Authentication → Emails → SMTP, e.g. Resend or Brevo).
   - Minimum password length: 8.

3. **Site address.** Authentication → **URL Configuration**:
   - Site URL: `https://cyiber069.github.io/Enivel/`
   - Redirect URLs: add `https://cyiber069.github.io/Enivel/`

4. **Create the admin account straight away.** Open the live app, log in with `kgosimosupi10@gmail.com`
   and a **new** password (not the one shared in chat). The app asks "Create the admin account?" → Confirm.
   The first account with that email becomes the admin automatically.

## How the security works
- The `docs` table is closed. Every read goes through `fetch_docs` and every write through `put_doc` / `del_doc`,
  which check who is asking.
- Parents see only their own children, bookings, payments and messages. Drivers see a child only while that child
  is booked on their route. Live driver location is shown only to parents with a child booked on that route.
- Other people only ever see a public profile: no ID numbers, ID photos, verification documents or PINs.
- Nobody can approve, unban or credit themselves, change a payment, or send messages as someone else.
- The admin is whoever is in the `admins` table (filled automatically for the owner's email, first account only).

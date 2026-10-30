-- =====================================================================
-- Enivel backend setup. Paste this whole file into Supabase:
-- Dashboard → SQL Editor → New query → paste → Run. Safe to run again.
-- All reads/writes go through the functions below, which enforce who may
-- see and change what. The table itself is closed to direct access.
-- =====================================================================

create table if not exists public.docs (
  coll       text        not null,
  id         text        not null,
  data       jsonb       not null default '{}'::jsonb,
  owner      uuid        not null,
  parties    text[]      not null default '{}',
  deleted    boolean     not null default false,
  updated_at timestamptz not null default now(),
  primary key (coll, id)
);
create index if not exists docs_updated_idx on public.docs (updated_at);
create index if not exists docs_parties_idx on public.docs using gin (parties);
alter table public.docs enable row level security;
revoke all on public.docs from anon, authenticated;

-- Admins. The first account created with the owner's email becomes admin
-- automatically. Create that account straight after running this script.
create table if not exists public.admins (user_id uuid primary key, created_at timestamptz not null default now());
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

create or replace function public._grant_owner_admin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if lower(new.email) = 'kgosimosupi10@gmail.com' and not exists (select 1 from public.admins) then
    insert into public.admins (user_id) values (new.id) on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists enivel_owner_admin on auth.users;
create trigger enivel_owner_admin after insert on auth.users
  for each row execute function public._grant_owner_admin();
-- if the owner account already exists, make it admin now
insert into public.admins (user_id)
  select id from auth.users where lower(email) = 'kgosimosupi10@gmail.com'
  and not exists (select 1 from public.admins) limit 1;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

-- People connected to a document (they may read it).
create or replace function public._parties(p_coll text, p_data jsonb) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare r text[] := '{}'; k text; pid text;
begin
  foreach k in array array['userId','parentId','driverId','from','to','by'] loop
    if jsonb_typeof(p_data -> k) = 'string' then r := r || (p_data ->> k); end if;
  end loop;
  if p_coll = 'offers' and jsonb_typeof(p_data -> 'requestId') = 'string' then
    select d.data ->> 'parentId' into pid from public.docs d where d.coll = 'requests' and d.id = p_data ->> 'requestId';
    if pid is not null then r := r || pid; end if;
  end if;
  return r;
end $$;

-- What other signed-in people may see of someone's profile (no ID numbers, documents, PINs).
create or replace function public._public_user(d jsonb) returns jsonb
language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', d -> 'id', 'name', d -> 'name', 'role', d -> 'role', 'createdAt', d -> 'createdAt',
    'years', d -> 'years',
    'phone', case when d ->> 'role' = 'driver' then d -> 'phone' end,
    'verification', jsonb_build_object('status', coalesce(d #> '{verification,status}', '"none"'::jsonb)),
    'banned', d -> 'banned', 'suspended', d -> 'suspended',
    'offDays', d -> 'offDays', 'offNote', d -> 'offNote'))
$$;

-- Read everything the caller is allowed to see. p_since = only changes after that time.
create or replace function public.fetch_docs(p_since timestamptz default null)
returns table (coll text, id text, data jsonb, deleted boolean, updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me text := auth.uid()::text; adm boolean := public.is_admin();
begin
  if auth.uid() is null then return; end if;
  return query
  select d.coll, d.id,
    case
      when adm or d.owner = auth.uid() then d.data
      when d.coll = 'users' then public._public_user(d.data)
      when d.coll = 'kids' then (d.data - 'handoverHash' - 'handoverSalt') || case when d.data ? 'handoverHash' and jsonb_typeof(d.data -> 'handoverHash') = 'string' then '{"handoverOn":true}'::jsonb else '{}'::jsonb end
      when d.coll = 'routes' and not exists (
             select 1 from public.docs b
             where b.coll = 'bookings' and not b.deleted
               and b.data ->> 'routeId' = d.id and b.data ->> 'parentId' = me
               and b.data ->> 'status' in ('active','trip'))
        then d.data - 'live'
      else d.data
    end,
    d.deleted, d.updated_at
  from public.docs d
  where (p_since is null or d.updated_at > p_since)
    and (p_since is not null or not d.deleted)
    and (
      adm
      or d.owner = auth.uid()
      or me = any (d.parties)
      or d.coll in ('users','routes','vehicles','ratings','settings','requests')
      or (d.coll = 'kids' and exists (
            select 1 from public.docs b
            where b.coll = 'bookings' and not b.deleted
              and b.data ->> 'kidId' = d.id and b.data ->> 'driverId' = me
              and b.data ->> 'status' in ('active','trip')))
    );
end $$;

-- Photos and documents: only data:image/... values are accepted.
create or replace function public._images_ok(p_coll text, d jsonb) returns boolean
language plpgsql immutable as $$
declare v text;
begin
  if p_coll = 'vehicles' and jsonb_typeof(d -> 'photos') = 'object' then
    for v in select value from jsonb_each_text(d -> 'photos') loop
      if v is not null and v !~ '^data:image/(jpeg|jpg|png|webp|gif|svg\+xml)[;,]' then return false; end if; end loop;
  end if;
  if p_coll = 'users' then
    if jsonb_typeof(d -> 'idPhoto') = 'string' and (d ->> 'idPhoto') !~ '^data:image/(jpeg|jpg|png|webp|gif|svg\+xml)[;,]' then return false; end if;
    if jsonb_typeof(d #> '{verification,docs}') = 'object' then
      for v in select value from jsonb_each_text(d #> '{verification,docs}') loop
        if v is not null and v !~ '^data:image/(jpeg|jpg|png|webp|gif|svg\+xml)[;,]' then return false; end if; end loop;
    end if;
  end if;
  return true;
end $$;

-- One account per phone number; a route can never take more children than seats.
create or replace function public._check_unique_and_capacity(p_coll text, p_id text, d jsonb) returns void
language plpgsql stable security definer set search_path = public as $$
declare seats int; used int;
begin
  if p_coll = 'users' and coalesce(d ->> 'phone','') <> '' and exists (
       select 1 from public.docs where coll = 'users' and not deleted and id <> p_id and data ->> 'phone' = d ->> 'phone') then
    raise exception 'That phone number already has an account'; end if;
  if p_coll = 'bookings' and d ->> 'status' = 'active' and coalesce(d ->> 'once','false') <> 'true' then
    if exists (select 1 from public.docs where coll = 'bookings' and id = p_id and data ->> 'status' = 'active') then return; end if;
    select nullif(data ->> 'seats','')::int into seats from public.docs where coll = 'routes' and id = d ->> 'routeId' and not deleted;
    select count(*) into used from public.docs where coll = 'bookings' and not deleted and id <> p_id
      and data ->> 'routeId' = d ->> 'routeId' and data ->> 'status' = 'active' and coalesce(data ->> 'once','false') <> 'true';
    select used + count(*) into used from public.docs where coll = 'waitlist' and not deleted and data ->> 'routeId' = d ->> 'routeId'
      and data ->> 'status' = 'offered' and data ->> 'parentId' <> coalesce(d ->> 'parentId','')
      and (data ->> 'offeredAt')::bigint > (extract(epoch from now())*1000)::bigint - 86400000;
    if seats is not null and used >= seats then raise exception 'This route is full'; end if;
  end if;
end $$;

-- Seats taken per route and public driver stats (no personal details), for everyone signed in.
drop function if exists public.route_load();
create or replace function public.route_load()
returns table (route_id text, used int, held int)
language sql stable security definer set search_path = public as $$
  with b as (select data ->> 'routeId' rid, count(*)::int n from public.docs
             where coll = 'bookings' and not deleted and data ->> 'status' = 'active' and coalesce(data ->> 'once','false') <> 'true' group by 1),
       w as (select data ->> 'routeId' rid, count(*)::int n from public.docs
             where coll = 'waitlist' and not deleted and data ->> 'status' = 'offered'
               and (data ->> 'offeredAt')::bigint > (extract(epoch from now())*1000)::bigint - 86400000 group by 1)
  select coalesce(b.rid, w.rid), coalesce(b.n,0), coalesce(w.n,0) from b full join w on b.rid = w.rid
$$;
create or replace function public.driver_stats()
returns table (driver_id text, passengers int, trips int, pickups int, ontime int)
language sql stable security definer set search_path = public as $$
  with p as (
    select data ->> 'driverId' did, count(*)::int n from public.docs
    where coll = 'bookings' and not deleted and data ->> 'status' = 'active' group by 1),
  e as (
    select ev.data ->> 'driverId' did,
      count(*) filter (where ev.data ->> 'type' = 'dropoff')::int trips,
      count(*) filter (where ev.data ->> 'type' = 'pickup')::int pickups,
      count(*) filter (where ev.data ->> 'type' = 'pickup' and (
        r.data ->> 'pickupTime' !~ '^\d{1,2}:\d{2}$'
        or extract(hour from to_timestamp((ev.data ->> 'ts')::bigint / 1000.0) at time zone 'Africa/Johannesburg') * 60
           + extract(minute from to_timestamp((ev.data ->> 'ts')::bigint / 1000.0) at time zone 'Africa/Johannesburg')
           <= split_part(r.data ->> 'pickupTime', ':', 1)::int * 60 + split_part(r.data ->> 'pickupTime', ':', 2)::int + 15))::int ontime
    from public.docs ev left join public.docs r on r.coll = 'routes' and r.id = ev.data ->> 'routeId'
    where ev.coll = 'events' and not ev.deleted and ev.data ->> 'type' in ('pickup','dropoff')
    group by 1)
  select coalesce(p.did, e.did), coalesce(p.n,0), coalesce(e.trips,0), coalesce(e.pickups,0), coalesce(e.ontime,0)
  from p full join e on p.did = e.did
$$;

-- Create or replace one document, with per-collection rules.
create or replace function public.put_doc(p_coll text, p_id text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; adm boolean := public.is_admin(); cur public.docs%rowtype; d jsonb := p_data;
begin
  if auth.uid() is null then raise exception 'Please sign in again'; end if;
  if p_coll not in ('users','kids','vehicles','routes','bookings','requests','offers','messages','events','transactions','notifications','ratings','settings','expenses','waitlist') then
    raise exception 'Unknown collection %', p_coll; end if;
  if octet_length(p_data::text) > 3000000 then raise exception 'That is too large to save (photos too big?)'; end if;
  if p_coll = 'settings' and not adm then raise exception 'Only the admin can change settings'; end if;
  if p_id !~ '^[A-Za-z0-9_-]{1,64}$' then raise exception 'Invalid id'; end if;
  -- in-app links must be a plain screen name
  if p_coll = 'notifications' and jsonb_typeof(d -> 'link') = 'string' and (d ->> 'link') !~ '^[a-z0-9-]{1,30}$' then
    d := d - 'link'; end if;
  -- photos and documents must be real image data
  if not public._images_ok(p_coll, d) then raise exception 'Photos must be image files'; end if;

  select * into cur from public.docs where coll = p_coll and id = p_id;

  if found and not cur.deleted then
    -- update an existing document
    if not (adm or cur.owner = auth.uid()
            or (me = any (cur.parties) and p_coll in ('bookings','notifications','messages','waitlist'))) then
      raise exception 'You cannot change this'; end if;
    if p_coll = 'transactions' and not adm then raise exception 'Payments cannot be changed'; end if;
    if not adm and cur.owner <> auth.uid() then
      -- connected people may only change one field each
      if p_coll = 'notifications' then d := cur.data || jsonb_build_object('read', coalesce(d -> 'read', 'false'::jsonb), 'answered', coalesce(d -> 'answered', cur.data -> 'answered', 'false'::jsonb));
      elsif p_coll = 'waitlist' then d := cur.data || jsonb_build_object('status', coalesce(d -> 'status', cur.data -> 'status'), 'offeredAt', coalesce(d -> 'offeredAt', cur.data -> 'offeredAt', 'null'::jsonb));
      elsif p_coll = 'messages' then d := cur.data || jsonb_build_object('read', coalesce(d -> 'read', 'false'::jsonb));
      elsif p_coll = 'bookings' then
        d := cur.data || jsonb_build_object('schedule', coalesce(d -> 'schedule', cur.data -> 'schedule', 'null'::jsonb))
             || case when me = cur.data ->> 'driverId' and (cur.data ->> 'once') = 'true' and (p_data ->> 'status') = 'done'
                     then jsonb_build_object('status','done') else '{}'::jsonb end;
      end if;
    end if;
    if p_coll = 'users' and not adm then
      -- people cannot approve, unban or credit themselves
      d := d || jsonb_build_object(
        'role', cur.data -> 'role', 'banned', coalesce(cur.data -> 'banned','false'::jsonb),
        'suspended', coalesce(cur.data -> 'suspended','false'::jsonb),
        'banReason', coalesce(cur.data -> 'banReason','null'::jsonb), 'bannedAt', coalesce(cur.data -> 'bannedAt','null'::jsonb),
        'referredBy', coalesce(cur.data -> 'referredBy','null'::jsonb));
      if coalesce((d ->> 'credit')::numeric, 0) > coalesce((cur.data ->> 'credit')::numeric, 0) then
        d := jsonb_set(d, '{credit}', coalesce(cur.data -> 'credit', '0'::jsonb)); end if;
      if coalesce(d #>> '{verification,status}', 'none') not in ('none','pending')
         and (d #>> '{verification,status}') is distinct from (cur.data #>> '{verification,status}') then
        d := jsonb_set(d, '{verification}', coalesce(d -> 'verification', '{}'::jsonb) || jsonb_build_object('status', coalesce(cur.data #> '{verification,status}', '"none"'::jsonb))); end if;
      if coalesce(d ->> 'idStatus', 'pending') <> 'pending'
         and (d ->> 'idStatus') is distinct from (cur.data ->> 'idStatus') then
        d := jsonb_set(d, '{idStatus}', coalesce(cur.data -> 'idStatus', '"pending"'::jsonb)); end if;
    end if;
    perform public._check_unique_and_capacity(p_coll, p_id, d);
    update public.docs set data = d, parties = public._parties(p_coll, d), updated_at = now()
    where coll = p_coll and id = p_id;
  else
    -- create a new document
    if found and cur.deleted and not (adm or cur.owner = auth.uid()) then raise exception 'You cannot change this'; end if;
    if not adm then
      if p_coll = 'users' then
        if p_id <> me then raise exception 'You can only create your own profile'; end if;
        if coalesce(d ->> 'role','') not in ('parent','driver') then raise exception 'Choose parent or driver'; end if;
        d := (d - 'banned' - 'suspended' - 'referredBy') || jsonb_build_object('credit', 0, 'verification', jsonb_build_object('status','none'));
      elsif p_coll in ('kids','requests','ratings','bookings','waitlist') and coalesce(d ->> 'parentId','') <> me then raise exception 'You cannot create this';
      elsif p_coll = 'expenses' and coalesce(d ->> 'driverId','') <> me then raise exception 'You cannot create this';
      elsif p_coll in ('vehicles','routes','offers') and coalesce(d ->> 'driverId','') <> me then raise exception 'You cannot create this';
      elsif p_coll = 'messages' and coalesce(d ->> 'from','') <> me then raise exception 'You cannot create this';
      elsif p_coll = 'transactions' and coalesce(d ->> 'from','') <> me then raise exception 'You cannot create this';
      elsif p_coll = 'events' and not (coalesce(d ->> 'driverId','') = me or coalesce(d ->> 'by','') = me or coalesce(d ->> 'parentId','') = me) then raise exception 'You cannot create this';
      end if;
    end if;
    perform public._check_unique_and_capacity(p_coll, p_id, d);
    insert into public.docs (coll, id, data, owner, parties, deleted, updated_at)
    values (p_coll, p_id, d, auth.uid(), public._parties(p_coll, d), false, now())
    on conflict (coll, id) do update
      set data = excluded.data, owner = excluded.owner, parties = excluded.parties, deleted = false, updated_at = now();
  end if;
end $$;

-- Delete (kept as an empty marker so other phones notice it is gone).
create or replace function public.del_doc(p_coll text, p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_coll = 'transactions' and not public.is_admin() then raise exception 'Payments cannot be deleted'; end if;
  if not exists (select 1 from public.docs where coll = p_coll and id = p_id and (owner = auth.uid() or public.is_admin())) then
    raise exception 'You cannot delete this'; end if;
  update public.docs set deleted = true, data = '{}'::jsonb, updated_at = now() where coll = p_coll and id = p_id;
end $$;

-- R50 for both people, once, when a new account uses a referral code.
create or replace function public.award_referral(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare ref public.docs%rowtype; me text := auth.uid()::text;
begin
  if auth.uid() is null or coalesce(trim(p_code),'') = '' then return null; end if;
  if not exists (select 1 from public.docs where coll = 'users' and id = me and not deleted) then return null; end if;
  if exists (select 1 from public.docs where coll = 'users' and id = me and jsonb_typeof(data -> 'referredBy') = 'string') then return null; end if;
  select * into ref from public.docs where coll = 'users' and not deleted and id <> me and upper(data ->> 'refCode') = upper(trim(p_code)) limit 1;
  if not found then return null; end if;
  update public.docs set data = jsonb_set(data, '{credit}', to_jsonb(coalesce((data ->> 'credit')::numeric,0) + 50)), updated_at = now()
    where coll = 'users' and id = ref.id;
  update public.docs set data = data || jsonb_build_object('referredBy', ref.id, 'credit', coalesce((data ->> 'credit')::numeric,0) + 50), updated_at = now()
    where coll = 'users' and id = me;
  return ref.id;
end $$;

-- Is this cellphone number already on an account? (used before sign-up)
create or replace function public.phone_taken(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.docs where coll = 'users' and not deleted and data ->> 'phone' = p)
$$;

revoke execute on function public._parties(text, jsonb) from public, anon, authenticated;
revoke execute on function public._grant_owner_admin() from public, anon, authenticated;
revoke execute on function public._public_user(jsonb) from public, anon, authenticated;
revoke execute on function public.put_doc(text, text, jsonb), public.del_doc(text, text),
  public.fetch_docs(timestamptz), public.award_referral(text) from public, anon;
grant execute on function public.put_doc(text, text, jsonb), public.del_doc(text, text),
  public.fetch_docs(timestamptz), public.award_referral(text), public.is_admin() to authenticated;
revoke execute on function public.phone_taken(text) from public, anon;
grant execute on function public.phone_taken(text) to authenticated;
revoke execute on function public._images_ok(text, jsonb), public._check_unique_and_capacity(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.route_load(), public.driver_stats() to authenticated;
revoke execute on function public.route_load(), public.driver_stats() from public, anon;

select 'Enivel backend ready' as status;

-- =====================================================================
-- Phone pop-up reminders (sent by the Enivel Worker every minute).
-- Each driver's app saves a plan of upcoming reminders on their own profile.
-- At send time we skip a child who is absent today or already picked up,
-- and skip the whole reminder once the trip has started.
-- =====================================================================
create table if not exists public.push_log (ptag text primary key, sent_at timestamptz not null default now());
alter table public.push_log enable row level security;
revoke all on public.push_log from anon, authenticated;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role; end if; end $$;

create or replace function public.due_push()
returns table (endpoint text, p256dh text, auth text, title text, body text, tag text, url text)
language plpgsql security definer set search_path = public as $$
declare
  nowms bigint := (extract(epoch from now()) * 1000)::bigint;
  today text := to_char(now() at time zone 'Africa/Johannesburg', 'YYYY-MM-DD');
  u record; it jsonb; sub jsonb; k record; names text[]; t text;
begin
  delete from public.push_log where sent_at < now() - interval '3 days';
  for u in select d.id, d.data from public.docs d
           where d.coll = 'users' and not d.deleted
             and jsonb_typeof(d.data -> 'pushPlan') = 'array'
             and jsonb_typeof(d.data -> 'pushSubs') = 'array'
             and jsonb_array_length(d.data -> 'pushSubs') > 0 loop
    if coalesce(u.data -> 'offDays', '[]'::jsonb) ? today then continue; end if;
    for it in select value from jsonb_array_elements(u.data -> 'pushPlan') loop
      if (it ->> 'at')::bigint > nowms or (it ->> 'at')::bigint < nowms - 180000 then continue; end if;
      t := u.id || ':' || (it ->> 'key');
      if exists (select 1 from public.push_log where ptag = t) then continue; end if;
      insert into public.push_log (ptag) values (t);
      if coalesce(it ->> 'kind', '') <> 'once' and exists (
           select 1 from public.docs r where r.coll = 'routes' and r.id = it ->> 'routeId' and r.data #>> '{live,active}' = 'true') then
        continue; end if;
      names := '{}';
      for k in select kd.id, kd.data from public.docs kd
               where kd.coll = 'kids' and not kd.deleted
                 and kd.id in (select jsonb_array_elements_text(coalesce(it -> 'kidIds', '[]'::jsonb)))
                 and exists (select 1 from public.docs bk where bk.coll = 'bookings' and not bk.deleted
                             and bk.data ->> 'kidId' = kd.id and bk.data ->> 'driverId' = u.id
                             and bk.data ->> 'status' in ('active','trip')) loop
        if coalesce(k.data -> 'absences', '[]'::jsonb) ? today then continue; end if;
        if exists (select 1 from jsonb_array_elements(coalesce(k.data -> 'termBreaks', '[]'::jsonb)) tb
                   where tb ->> 'from' <= today and today <= tb ->> 'to') then continue; end if;
        if exists (select 1 from public.docs e where e.coll = 'events' and not e.deleted
                   and e.data ->> 'kidId' = k.id and e.data ->> 'type' = 'pickup'
                   and (e.data ->> 'ts')::bigint > (it ->> 'slot')::bigint - 3600000) then continue; end if;
        names := names || (k.data ->> 'name');
      end loop;
      if coalesce(array_length(names, 1), 0) = 0 then continue; end if;
      for sub in select value from jsonb_array_elements(u.data -> 'pushSubs') loop
        endpoint := sub ->> 'endpoint'; p256dh := sub #>> '{keys,p256dh}'; auth := sub #>> '{keys,auth}';
        title := 'Pickup in ' || (it ->> 'mins') || ' min';
        body := array_to_string(names, ', ') || ' · ' || coalesce(it ->> 'label', 'Pickup') || ' at ' || coalesce(it ->> 'time', '');
        tag := it ->> 'key'; url := coalesce(it ->> 'routeId', '');
        return next;
      end loop;
    end loop;
  end loop;
end $$;

-- Remove a phone that no longer accepts pop-ups (uninstalled, permission removed).
create or replace function public.drop_push_sub(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  update public.docs set data = jsonb_set(data, '{pushSubs}',
      coalesce((select jsonb_agg(s) from jsonb_array_elements(data -> 'pushSubs') s where s ->> 'endpoint' <> p_endpoint), '[]'::jsonb))
  where coll = 'users' and jsonb_typeof(data -> 'pushSubs') = 'array'
$$;

revoke execute on function public.due_push(), public.drop_push_sub(text) from public, anon, authenticated;
grant execute on function public.due_push(), public.drop_push_sub(text) to service_role;
select 'Enivel reminders ready' as status;

-- =====================================================================
-- Sign in with Face ID / fingerprint (passkeys).
-- Each phone's public key is saved on the person's own profile (never shown
-- to anyone else). The Enivel Worker looks it up here to check a sign-in.
-- =====================================================================
create or replace function public.passkey_lookup(p_cred_id text)
returns table (user_id text, email text, pk text, alg int, banned boolean, suspended boolean)
language sql stable security definer set search_path = public, auth as $$
  select d.id, u.email::text, k ->> 'pk', coalesce((k ->> 'alg')::int, -7),
         coalesce((d.data ->> 'banned')::boolean, false), coalesce((d.data ->> 'suspended')::boolean, false)
  from public.docs d
  join auth.users u on u.id::text = d.id
  cross join lateral jsonb_array_elements(coalesce(d.data -> 'passkeys', '[]'::jsonb)) k
  where d.coll = 'users' and not d.deleted and k ->> 'id' = p_cred_id
  limit 1
$$;
revoke execute on function public.passkey_lookup(text) from public, anon, authenticated;
grant execute on function public.passkey_lookup(text) to service_role;
select 'Enivel Face ID sign-in ready' as status;


-- =====================================================================
-- Handover code check, done on the server so drivers never see the code.
-- At most 5 tries per child per 15 minutes; the 5th wrong try alerts the parent.
-- =====================================================================
create table if not exists public.handover_attempts (kid_id text not null, at timestamptz not null default now());
alter table public.handover_attempts enable row level security;
revoke all on public.handover_attempts from anon, authenticated;
create or replace function public.handover_check(p_kid text, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare k record; tries int; want text; got text;
begin
  if auth.uid() is null then return 'signin'; end if;
  select id, data into k from public.docs where coll = 'kids' and id = p_kid and not deleted;
  if not found then return 'nokid'; end if;
  if not public.is_admin() and not exists (select 1 from public.docs b where b.coll = 'bookings' and not b.deleted
      and b.data ->> 'kidId' = p_kid and b.data ->> 'driverId' = auth.uid()::text and b.data ->> 'status' in ('active','trip')) then return 'notyours'; end if;
  want := k.data ->> 'handoverHash'; if want is null then return 'ok'; end if;
  select count(*) into tries from public.handover_attempts where kid_id = p_kid and at > now() - interval '15 minutes';
  if tries >= 5 then return 'locked'; end if;
  if jsonb_typeof(k.data -> 'handoverSalt') = 'string' then got := encode(sha256(convert_to((k.data ->> 'handoverSalt') || ':' || coalesce(p_code,''), 'UTF8')), 'hex');
  else got := encode(sha256(convert_to('ho:' || p_kid || ':' || coalesce(p_code,''), 'UTF8')), 'hex'); end if;
  if got = want then delete from public.handover_attempts where kid_id = p_kid; return 'ok'; end if;
  insert into public.handover_attempts (kid_id) values (p_kid);
  if tries + 1 >= 5 then
    insert into public.docs (coll, id, data, owner, parties) values ('notifications', 'ho' || replace(gen_random_uuid()::text,'-',''),
      jsonb_build_object('userId', k.data ->> 'parentId', 'type', 'info', 'link', 'p-home', 'read', false, 'ts', (extract(epoch from now())*1000)::bigint,
        'text', 'Wrong handover code entered 5 times for ' || coalesce(k.data ->> 'name','your child') || '. Handover is locked for 15 minutes. Call your driver.'),
      auth.uid(), array[k.data ->> 'parentId']);
    return 'locked'; end if;
  return 'wrong';
end $$;
revoke execute on function public.handover_check(text, text) from public, anon;
grant execute on function public.handover_check(text, text) to authenticated;

select 'Enivel handover check ready' as status;

-- The sign-in screen needs the Worker address before anyone is signed in.
create or replace function public.public_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('otpEndpoint', coalesce((select data ->> 'otpEndpoint' from public.docs where coll = 'settings' and id = 'config' and not deleted), ''))
$$;
grant execute on function public.public_config() to anon, authenticated;

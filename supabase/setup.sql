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
      or d.coll in ('users','routes','vehicles','ratings','settings','requests','checks')
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
  if p_coll not in ('users','kids','vehicles','routes','bookings','requests','offers','messages','events','transactions','notifications','ratings','settings','expenses','waitlist','checks','audit') then
    raise exception 'Unknown collection %', p_coll; end if;
  if octet_length(p_data::text) > 3000000 then raise exception 'That is too large to save (photos too big?)'; end if;
  if p_coll = 'settings' and not adm then raise exception 'Only the admin can change settings'; end if;
  if p_coll = 'audit' and not adm then raise exception 'Only the admin can write the audit log'; end if;
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
      elsif p_coll in ('expenses','checks') and coalesce(d ->> 'driverId','') <> me then raise exception 'You cannot create this';
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

-- r10:kidcore
-- =====================================================================
-- Round 10 · Kid accounts (kidcore). Run after setup.sql. Safe to run again.
-- A parent gives a child their own login. The child signs in with their own
-- email + password and sees only their own rides. Parents decide what the
-- child may do (kids.perms). Kids never see prices, payments or ID numbers.
-- This file replaces fetch_docs, put_doc and _parties with versions that keep
-- every existing rule and add the kid rules.
-- =====================================================================

-- One-time links that join a new kid login to a child profile (15 minutes).
create table if not exists public.kid_links (
  token_hash text primary key,
  kid_id     text        not null,
  parent_id  text        not null,
  email      text        not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz,
  used_by    uuid
);
create index if not exists kid_links_parent_idx on public.kid_links (parent_id, created_at);
create index if not exists kid_links_used_by_idx on public.kid_links (used_by);
alter table public.kid_links enable row level security;
revoke all on public.kid_links from anon, authenticated;

-- Is this sign-in a kid login? (a kid profile, or an account that once claimed a kid link)
create or replace function public._is_kid_login(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_uid is not null and (
    exists (select 1 from public.docs u where u.coll = 'users' and u.id = p_uid::text and not u.deleted and u.data ->> 'role' = 'kid')
    or exists (select 1 from public.kid_links l where l.used_by = p_uid))
$$;

-- The child a kid login belongs to. No row = login switched off, removed or not linked.
create or replace function public._kid_ctx(p_uid text)
returns table (kid_id text, parent_id text, perms jsonb, kid_name text)
language sql stable security definer set search_path = public as $$
  select k.id, k.data ->> 'parentId', case when jsonb_typeof(k.data -> 'perms') = 'object' then k.data -> 'perms' else '{}'::jsonb end, k.data ->> 'name'
  from public.docs u
  join public.docs k on k.coll = 'kids' and k.id = u.data ->> 'kidId' and not k.deleted
  where u.coll = 'users' and u.id = p_uid and not u.deleted and u.data ->> 'role' = 'kid'
    and coalesce(u.data ->> 'suspended', 'false') <> 'true'
    and coalesce(u.data ->> 'banned', 'false') <> 'true'
    and coalesce(u.data ->> 'unlinked', 'false') <> 'true'
    and k.data ->> 'parentId' = u.data ->> 'parentId'
    and k.data ->> 'accountId' = p_uid
  limit 1
$$;

-- A permission switch with its default (track, ready, theme, faceid, alerts on; chat, absent off).
create or replace function public._kid_perm(p_perms jsonb, p_key text, p_default boolean) returns boolean
language sql immutable as $$
  select case when jsonb_typeof(p_perms -> p_key) = 'boolean' then (p_perms ->> p_key)::boolean else p_default end
$$;

-- Does this driver have an active ride with this child?
create or replace function public._kid_driver(p_kid text, p_driver text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(p_driver, '') <> '' and exists (select 1 from public.docs b where b.coll = 'bookings' and not b.deleted
    and b.data ->> 'kidId' = p_kid and b.data ->> 'driverId' = p_driver and b.data ->> 'status' in ('active','trip'))
$$;

-- People connected to a document (they may read it). Kid chats also include that kid's parent.
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
  if p_coll = 'messages' then
    foreach k in array array['from','to'] loop
      if jsonb_typeof(p_data -> k) = 'string' then
        pid := null;
        select d.data ->> 'parentId' into pid from public.docs d
          where d.coll = 'users' and d.id = p_data ->> k and not d.deleted and d.data ->> 'role' = 'kid';
        if pid is not null and not (pid = any (r)) then r := r || pid; end if;
      end if;
    end loop;
  end if;
  return r;
end $$;

-- Read everything the caller is allowed to see. p_since = only changes after that time.
create or replace function public.fetch_docs(p_since timestamptz default null)
returns table (coll text, id text, data jsonb, deleted boolean, updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me text := auth.uid()::text; adm boolean := public.is_admin();
  v_kid text; v_parent text; v_perms jsonb; v_track boolean;
begin
  if auth.uid() is null then return; end if;

  -- ---------- kid logins: only their own child's rides ----------
  if not adm and public._is_kid_login(auth.uid()) then
    select c.kid_id, c.parent_id, c.perms into v_kid, v_parent, v_perms from public._kid_ctx(me) c;
    if v_kid is null then
      -- switched off or removed: only their own profile, so the app can sign them out
      return query select d.coll, d.id, d.data, d.deleted, d.updated_at from public.docs d
        where d.coll = 'users' and d.id = me and (p_since is null or d.updated_at > p_since);
      return;
    end if;
    v_track := public._kid_perm(v_perms, 'track', true);
    return query
    select d.coll, d.id,
      case
        when d.deleted then d.data
        when d.owner = auth.uid() then d.data
        when d.coll = 'users' then public._public_user(d.data)
             || case when d.id = v_parent and jsonb_typeof(d.data -> 'phone') = 'string' then jsonb_build_object('phone', d.data -> 'phone') else '{}'::jsonb end
        when d.coll = 'kids' then d.data - 'handoverHash' - 'handoverSalt' - 'consent'
        when d.coll = 'bookings' then d.data - 'price' - 'sponsoredMonths' - 'fromRequest' - 'fee' - 'amount' - 'paid' - 'paidMonths' - 'discount' - 'credit'
        when d.coll = 'routes' then
          case when v_track and exists (select 1 from public.docs b where b.coll = 'bookings' and not b.deleted
                     and b.data ->> 'kidId' = v_kid and b.data ->> 'routeId' = d.id and b.data ->> 'status' in ('active','trip'))
               then d.data - 'price' else d.data - 'price' - 'live' end
        else d.data
      end,
      d.deleted, d.updated_at
    from public.docs d
    where (p_since is null or d.updated_at > p_since)
      and (p_since is not null or not d.deleted)
      and (
        d.owner = auth.uid()
        or (d.coll = 'users' and (d.deleted or d.id = v_parent or d.data ->> 'role' = 'driver'))
        or (d.coll = 'kids' and d.id = v_kid)
        or (d.coll = 'bookings' and d.data ->> 'kidId' = v_kid)
        or (d.coll = 'events' and d.data ->> 'kidId' = v_kid and coalesce(d.data ->> 'type', '') <> 'report'
            and (d.owner::text = v_parent
                 or exists (select 1 from public.admins a where a.user_id = d.owner)
                 or exists (select 1 from public.docs b where b.coll = 'bookings' and b.data ->> 'kidId' = v_kid and b.data ->> 'driverId' = d.owner::text)))
        or d.coll in ('routes','vehicles','checks','settings')
        or (d.coll in ('messages','notifications') and me = any (d.parties))
      );
    return;
  end if;

  -- ---------- everyone else (unchanged rules, plus: kid profiles stay private) ----------
  return query
  select d.coll, d.id,
    case
      when adm or d.owner = auth.uid() then d.data
      when d.coll = 'users' then public._public_user(d.data)
           || case when d.data ->> 'role' = 'kid' then jsonb_strip_nulls(jsonb_build_object('kidId', d.data -> 'kidId', 'parentId', d.data -> 'parentId', 'unlinked', d.data -> 'unlinked')) else '{}'::jsonb end
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
      or (d.coll in ('users','routes','vehicles','ratings','settings','requests','checks')
          and not (d.coll = 'users' and d.data ->> 'role' = 'kid'))
      or (d.coll = 'users' and d.data ->> 'role' = 'kid' and public._kid_driver(d.data ->> 'kidId', me))
      or (d.coll = 'kids' and exists (
            select 1 from public.docs b
            where b.coll = 'bookings' and not b.deleted
              and b.data ->> 'kidId' = d.id and b.data ->> 'driverId' = me
              and b.data ->> 'status' in ('active','trip')))
    );
end $$;

-- Writes by a kid login: their own profile (limited), chat (if allowed), alerts to their
-- parent/driver/admin, and their own ride events. Nothing else.
create or replace function public._kid_put(p_coll text, p_id text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; cur public.docs%rowtype; d jsonb := p_data; k text; t text;
  v_kid text; v_parent text; v_perms jsonb;
begin
  select c.kid_id, c.parent_id, c.perms into v_kid, v_parent, v_perms from public._kid_ctx(me) c;
  select * into cur from public.docs where coll = p_coll and id = p_id;

  if p_coll = 'users' then
    if p_id <> me or not found or cur.deleted then raise exception 'You cannot change this'; end if;
    if v_kid is null then raise exception 'This kid login is switched off. Ask your parent.'; end if;
    foreach k in array array['id','role','parentId','kidId','email','name','suspended','unlinked','unlinkedAt','banned','banReason',
        'bannedAt','referredBy','credit','verification','idStatus','idNote','idNumber','idPhoto','idVerifiedAt','phone','phoneVerified',
        'termsAccepted','createdAt','refCode','screen','docsMeta','pushPlan','journey','guardians','offDays','offNote'] loop
      if cur.data ? k then d := jsonb_set(d, array[k], cur.data -> k); else d := d - k; end if;
    end loop;
    if not public._kid_perm(v_perms, 'theme', true) then
      if cur.data ? 'theme' then d := jsonb_set(d, '{theme}', cur.data -> 'theme'); else d := d - 'theme'; end if; end if;
    if not public._kid_perm(v_perms, 'faceid', true) then
      if cur.data ? 'passkeys' then d := jsonb_set(d, '{passkeys}', cur.data -> 'passkeys'); else d := d - 'passkeys'; end if; end if;
    if not public._kid_perm(v_perms, 'alerts', true) then
      if cur.data ? 'pushSubs' then d := jsonb_set(d, '{pushSubs}', cur.data -> 'pushSubs'); else d := d - 'pushSubs'; end if; end if;
    update public.docs set data = d, parties = public._parties('users', d), updated_at = now() where coll = 'users' and id = me;
    return;
  end if;

  if v_kid is null then raise exception 'This kid login is switched off. Ask your parent.'; end if;

  if p_coll = 'messages' then
    if found and not cur.deleted then
      if cur.data ->> 'to' = me then
        d := cur.data || jsonb_build_object('read', coalesce(d -> 'read', 'false'::jsonb));
        update public.docs set data = d, updated_at = now() where coll = p_coll and id = p_id;
        return;
      end if;
      raise exception 'Messages cannot be changed';
    end if;
    if found and cur.owner <> auth.uid() then raise exception 'You cannot change this'; end if;
    if not public._kid_perm(v_perms, 'chat', false) then raise exception 'Chat is switched off. Ask your parent.'; end if;
    if coalesce(d ->> 'from', '') <> me then raise exception 'You cannot create this'; end if;
    t := coalesce(d ->> 'to', '');
    if not (t = v_parent or public._kid_driver(v_kid, t)) then raise exception 'You can only message your driver or your parent'; end if;
    d := d - 'userId' - 'parentId' - 'driverId' - 'by';
  elsif p_coll = 'notifications' then
    if found and not cur.deleted and cur.owner <> auth.uid() then
      if cur.data ->> 'userId' = me then
        d := cur.data || jsonb_build_object('read', coalesce(d -> 'read', 'false'::jsonb), 'answered', coalesce(d -> 'answered', cur.data -> 'answered', 'false'::jsonb));
        update public.docs set data = d, updated_at = now() where coll = p_coll and id = p_id;
        return;
      end if;
      raise exception 'You cannot change this';
    end if;
    if found and cur.deleted and cur.owner <> auth.uid() then raise exception 'You cannot change this'; end if;
    t := coalesce(d ->> 'userId', '');
    if not (t = v_parent or t = 'admin' or public._kid_driver(v_kid, t)) then raise exception 'You cannot send this'; end if;
    d := d - 'parentId' - 'driverId' - 'from' - 'to' - 'by';
  elsif p_coll = 'events' then
    if found and cur.owner <> auth.uid() then raise exception 'You cannot change this'; end if;
    if coalesce(d ->> 'type', '') not in ('kid-ready','kid-late','kid-sos','ride-check','kid-absent-ask') then raise exception 'You cannot create this'; end if;
    if coalesce(d ->> 'by', '') <> me or coalesce(d ->> 'kidId', '') <> v_kid then raise exception 'You cannot create this'; end if;
    d := (d - 'userId' - 'from' - 'to') || jsonb_build_object('parentId', v_parent);
    -- an SOS never goes to the driver: the driver could be the danger
    if d ->> 'type' = 'kid-sos' then d := d - 'driverId';
    elsif jsonb_typeof(d -> 'driverId') = 'string' and not public._kid_driver(v_kid, d ->> 'driverId') then d := d - 'driverId'; end if;
    if jsonb_typeof(d -> 'bookingId') = 'string' and not exists (select 1 from public.docs b where b.coll = 'bookings' and b.id = d ->> 'bookingId' and b.data ->> 'kidId' = v_kid) then
      d := d - 'bookingId'; end if;
  else
    raise exception 'Kid logins cannot change this';
  end if;

  insert into public.docs (coll, id, data, owner, parties, deleted, updated_at)
  values (p_coll, p_id, d, auth.uid(), public._parties(p_coll, d), false, now())
  on conflict (coll, id) do update
    set data = excluded.data, owner = excluded.owner, parties = excluded.parties, deleted = false, updated_at = now();
end $$;

-- Create or replace one document, with per-collection rules.
create or replace function public.put_doc(p_coll text, p_id text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; adm boolean := public.is_admin(); cur public.docs%rowtype; d jsonb := p_data;
  tk text; tkid text; tparent text; tperms jsonb;
begin
  if auth.uid() is null then raise exception 'Please sign in again'; end if;
  if p_coll not in ('users','kids','vehicles','routes','bookings','requests','offers','messages','events','transactions','notifications','ratings','settings','expenses','waitlist','checks','audit') then
    raise exception 'Unknown collection %', p_coll; end if;
  if octet_length(p_data::text) > 3000000 then raise exception 'That is too large to save (photos too big?)'; end if;
  if p_coll = 'settings' and not adm then raise exception 'Only the admin can change settings'; end if;
  if p_coll = 'audit' and not adm then raise exception 'Only the admin can write the audit log'; end if;
  if p_id !~ '^[A-Za-z0-9_-]{1,64}$' then raise exception 'Invalid id'; end if;
  -- in-app links must be a plain screen name
  if p_coll = 'notifications' and jsonb_typeof(d -> 'link') = 'string' and (d ->> 'link') !~ '^[a-z0-9-]{1,30}$' then
    d := d - 'link'; end if;
  -- photos and documents must be real image data
  if not public._images_ok(p_coll, d) then raise exception 'Photos must be image files'; end if;

  -- kid logins have their own, much smaller set of rules
  if not adm and public._is_kid_login(auth.uid()) then
    perform public._kid_put(p_coll, p_id, d);
    return;
  end if;

  -- only the parent (or the server) may contact a child's own login; their driver only with "chat" on
  if not adm and p_coll in ('messages','notifications') then
    tk := case when p_coll = 'messages' then d ->> 'to' else d ->> 'userId' end;
    if tk is not null and exists (select 1 from public.docs u where u.coll = 'users' and u.id = tk and not u.deleted and u.data ->> 'role' = 'kid') then
      select u.data ->> 'parentId' into tparent from public.docs u where u.coll = 'users' and u.id = tk;
      select c.kid_id, c.perms into tkid, tperms from public._kid_ctx(tk) c;
      if not exists (select 1 from public.docs x where x.coll = p_coll and x.id = p_id and not x.deleted)
         and not (me = tparent
                  or (tkid is not null and public._kid_driver(tkid, me)
                      and (p_coll = 'notifications' or public._kid_perm(tperms, 'chat', false)))) then
        raise exception 'Only a parent or their driver can contact this child';
      end if;
    end if;
  end if;

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
    -- a child's login link is only changed by kid_link_claim / kid_unlink
    if p_coll = 'kids' then
      d := (d - 'accountId' - 'accountEmail')
           || jsonb_strip_nulls(jsonb_build_object('accountId', cur.data -> 'accountId', 'accountEmail', cur.data -> 'accountEmail'));
    end if;
    perform public._check_unique_and_capacity(p_coll, p_id, d);
    update public.docs set data = d, parties = public._parties(p_coll, d), updated_at = now()
    where coll = p_coll and id = p_id;
    -- keep the child's own login in step with the profile and the parent's switches
    if p_coll = 'kids' and jsonb_typeof(cur.data -> 'accountId') = 'string' then
      update public.docs u set data = u.data
          || case when jsonb_typeof(d -> 'name') = 'string' then jsonb_build_object('name', d -> 'name') else '{}'::jsonb end
          || case when not public._kid_perm(case when jsonb_typeof(d -> 'perms') = 'object' then d -> 'perms' else '{}'::jsonb end, 'faceid', true) then '{"passkeys":[]}'::jsonb else '{}'::jsonb end
          || case when not public._kid_perm(case when jsonb_typeof(d -> 'perms') = 'object' then d -> 'perms' else '{}'::jsonb end, 'alerts', true) then '{"pushSubs":[]}'::jsonb else '{}'::jsonb end,
        updated_at = now()
      where u.coll = 'users' and u.id = cur.data ->> 'accountId' and not u.deleted and u.data ->> 'role' = 'kid'
        and u.data ->> 'kidId' = p_id
        and (u.data -> 'name' is distinct from d -> 'name'
             or (jsonb_typeof(u.data -> 'passkeys') = 'array' and jsonb_array_length(u.data -> 'passkeys') > 0)
             or (jsonb_typeof(u.data -> 'pushSubs') = 'array' and jsonb_array_length(u.data -> 'pushSubs') > 0));
    end if;
  else
    -- create a new document
    if found and cur.deleted and not (adm or cur.owner = auth.uid()) then raise exception 'You cannot change this'; end if;
    if not adm then
      if p_coll = 'users' then
        if p_id <> me then raise exception 'You can only create your own profile'; end if;
        if coalesce(d ->> 'role','') not in ('parent','driver') then raise exception 'Choose parent or driver'; end if;
        d := (d - 'banned' - 'suspended' - 'referredBy') || jsonb_build_object('credit', 0, 'verification', jsonb_build_object('status','none'));
      elsif p_coll in ('kids','requests','ratings','bookings','waitlist') and coalesce(d ->> 'parentId','') <> me then raise exception 'You cannot create this';
      elsif p_coll in ('expenses','checks') and coalesce(d ->> 'driverId','') <> me then raise exception 'You cannot create this';
      elsif p_coll in ('vehicles','routes','offers') and coalesce(d ->> 'driverId','') <> me then raise exception 'You cannot create this';
      elsif p_coll = 'messages' and coalesce(d ->> 'from','') <> me then raise exception 'You cannot create this';
      elsif p_coll = 'transactions' and coalesce(d ->> 'from','') <> me then raise exception 'You cannot create this';
      elsif p_coll = 'events' and not (coalesce(d ->> 'driverId','') = me or coalesce(d ->> 'by','') = me or coalesce(d ->> 'parentId','') = me) then raise exception 'You cannot create this';
      elsif p_coll = 'events' and jsonb_typeof(d -> 'by') = 'string' and d ->> 'by' <> me then raise exception 'You cannot create this';
      end if;
    end if;
    if p_coll = 'kids' then d := d - 'accountId' - 'accountEmail'; end if;
    perform public._check_unique_and_capacity(p_coll, p_id, d);
    insert into public.docs (coll, id, data, owner, parties, deleted, updated_at)
    values (p_coll, p_id, d, auth.uid(), public._parties(p_coll, d), false, now())
    on conflict (coll, id) do update
      set data = excluded.data, owner = excluded.owner, parties = excluded.parties, deleted = false, updated_at = now();
  end if;
end $$;

-- Parent: get a one-time code (15 min) to join a new kid login to this child.
create or replace function public.kid_link_create(p_kid text, p_email text) returns text
language plpgsql security definer set search_path = public, auth as $$
declare me text := auth.uid()::text; k public.docs%rowtype; em text := lower(trim(coalesce(p_email, ''))); tok text; n int; x record;
begin
  if auth.uid() is null then raise exception 'Please sign in again'; end if;
  if public._is_kid_login(auth.uid()) then raise exception 'Kid logins cannot do this'; end if;
  if exists (select 1 from public.docs u where u.coll = 'users' and u.id = me and (u.data ->> 'banned' = 'true' or u.data ->> 'suspended' = 'true')) then
    raise exception 'This account cannot add kid logins'; end if;
  select * into k from public.docs where coll = 'kids' and id = p_kid and not deleted;
  if not found or k.data ->> 'parentId' <> me then raise exception 'Only this child''s parent can do this'; end if;
  if em !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then raise exception 'Enter a real email address'; end if;
  if jsonb_typeof(k.data -> 'accountId') = 'string' and exists (select 1 from public._kid_ctx(k.data ->> 'accountId')) then
    raise exception '% already has a login', coalesce(k.data ->> 'name', 'This child'); end if;
  -- the email must be new, or an old switched-off login of this parent's child
  for x in select d.id, d.data from public.docs d where d.coll = 'users' and not d.deleted and lower(d.data ->> 'email') = em loop
    if not (x.data ->> 'role' = 'kid' and x.data ->> 'parentId' = me and not exists (select 1 from public._kid_ctx(x.id))) then
      raise exception 'That email already has an Enivel account'; end if;
  end loop;
  if exists (select 1 from auth.users au join public.docs d on d.coll = 'users' and d.id = au.id::text and not d.deleted
             where lower(au.email) = em
               and not (d.data ->> 'role' = 'kid' and d.data ->> 'parentId' = me and not exists (select 1 from public._kid_ctx(d.id)))) then
    raise exception 'That email already has an Enivel account'; end if;
  select count(*) into n from public.kid_links where parent_id = me and created_at > now() - interval '1 hour';
  if n >= 10 then raise exception 'Too many tries. Wait an hour and try again.'; end if;
  delete from public.kid_links where expires_at < now() - interval '2 days' and used_by is null;
  tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.kid_links (token_hash, kid_id, parent_id, email, expires_at)
  values (encode(sha256(convert_to(tok, 'UTF8')), 'hex'), p_kid, me, em, now() + interval '15 minutes');
  return tok;
end $$;

-- New kid login: use the code to join this login to the child profile.
create or replace function public.kid_link_claim(p_token text) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare me text := auth.uid()::text; l public.kid_links%rowtype; em text; k public.docs%rowtype; cur public.docs%rowtype; u jsonb;
  nowms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if auth.uid() is null then raise exception 'Please sign in again'; end if;
  select * into l from public.kid_links where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex') for update;
  if not found then raise exception 'This kid login code is not valid'; end if;
  if l.used_at is not null then raise exception 'This kid login code was already used'; end if;
  if l.expires_at < now() then raise exception 'This kid login code has expired. Ask your parent to try again.'; end if;
  select lower(au.email) into em from auth.users au where au.id = auth.uid();
  if em is null or em <> l.email then raise exception 'This code is for a different email'; end if;
  select * into k from public.docs where coll = 'kids' and id = l.kid_id and not deleted;
  if not found or k.data ->> 'parentId' <> l.parent_id then raise exception 'This child profile was removed'; end if;
  if jsonb_typeof(k.data -> 'accountId') = 'string' and k.data ->> 'accountId' <> me and exists (select 1 from public._kid_ctx(k.data ->> 'accountId')) then
    raise exception 'This child already has a login'; end if;
  select * into cur from public.docs where coll = 'users' and id = me;
  if found and not cur.deleted then
    if not (cur.data ->> 'role' = 'kid' and cur.data ->> 'parentId' = l.parent_id) then raise exception 'This email already has an Enivel account'; end if;
    if exists (select 1 from public._kid_ctx(me)) and cur.data ->> 'kidId' <> l.kid_id then raise exception 'This login already belongs to another child'; end if;
    u := (cur.data - 'unlinkedAt') || jsonb_build_object('kidId', l.kid_id, 'name', k.data -> 'name', 'suspended', false, 'unlinked', false, 'relinkedAt', nowms);
    update public.docs set data = u, parties = public._parties('users', u), updated_at = now() where coll = 'users' and id = me;
  else
    u := jsonb_build_object('id', me, 'name', k.data -> 'name', 'email', em, 'role', 'kid', 'parentId', l.parent_id, 'kidId', l.kid_id,
      'createdAt', nowms, 'verification', jsonb_build_object('status', 'none'), 'credit', 0, 'referredBy', 'kid-login', 'suspended', false);
    insert into public.docs (coll, id, data, owner, parties, deleted, updated_at)
    values ('users', me, u, auth.uid(), public._parties('users', u), false, now())
    on conflict (coll, id) do update set data = excluded.data, owner = excluded.owner, parties = excluded.parties, deleted = false, updated_at = now();
  end if;
  update public.docs set data = data - 'accountId' - 'accountEmail', updated_at = now()
    where coll = 'kids' and id <> l.kid_id and data ->> 'accountId' = me;
  update public.docs set data = data || jsonb_build_object('accountId', me, 'accountEmail', em), updated_at = now()
    where coll = 'kids' and id = l.kid_id;
  update public.kid_links set used_at = now(), used_by = auth.uid() where token_hash = l.token_hash;
  update public.kid_links set used_at = now() where kid_id = l.kid_id and used_at is null;
  insert into public.docs (coll, id, data, owner, parties)
  values ('notifications', 'kl' || replace(gen_random_uuid()::text, '-', ''),
    jsonb_build_object('userId', l.parent_id, 'type', 'info', 'link', 'p-kids', 'read', false, 'ts', nowms,
      'text', coalesce(k.data ->> 'name', 'Your child') || '''s own login is ready (' || em || ').'),
    l.parent_id::uuid, array[l.parent_id]);
  return jsonb_build_object('kidId', l.kid_id, 'parentId', l.parent_id, 'name', k.data ->> 'name');
end $$;

-- Parent: switch off a child's own login (they are signed out). It can be set up again later.
create or replace function public.kid_unlink(p_kid text) returns boolean
language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; k public.docs%rowtype; nowms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if auth.uid() is null then raise exception 'Please sign in again'; end if;
  select * into k from public.docs where coll = 'kids' and id = p_kid and not deleted;
  if not found then raise exception 'Child not found'; end if;
  if not (public.is_admin() or k.data ->> 'parentId' = me) then raise exception 'Only this child''s parent can do this'; end if;
  update public.docs set data = data || jsonb_build_object('suspended', true, 'unlinked', true, 'unlinkedAt', nowms, 'passkeys', '[]'::jsonb, 'pushSubs', '[]'::jsonb),
    updated_at = now()
  where coll = 'users' and not deleted and data ->> 'role' = 'kid' and data ->> 'kidId' = p_kid and data ->> 'parentId' = k.data ->> 'parentId';
  update public.docs set data = data - 'accountId' - 'accountEmail', updated_at = now() where coll = 'kids' and id = p_kid;
  update public.kid_links set used_at = now() where kid_id = p_kid and used_at is null;
  return true;
end $$;

-- Kid: "I'm not riding" for today or a day in the next two weeks (only if the parent allows it).
create or replace function public.kid_absent(p_day text) returns boolean
language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; v_kid text; v_parent text; v_perms jsonb; v_name text; dd date; lbl text; drv text;
  today date := (now() at time zone 'Africa/Johannesburg')::date; nowms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if auth.uid() is null then raise exception 'Please sign in again'; end if;
  select c.kid_id, c.parent_id, c.perms, c.kid_name into v_kid, v_parent, v_perms, v_name from public._kid_ctx(me) c;
  if v_kid is null then raise exception 'Only a kid login can do this'; end if;
  if not public._kid_perm(v_perms, 'absent', false) then raise exception 'Ask your parent to switch this on'; end if;
  if coalesce(p_day, '') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Pick a day'; end if;
  begin dd := p_day::date; exception when others then raise exception 'Pick a real day'; end;
  if dd < today or dd > today + 14 then raise exception 'Pick today or a day in the next two weeks'; end if;
  if exists (select 1 from public.docs where coll = 'kids' and id = v_kid and coalesce(data -> 'absences', '[]'::jsonb) ? p_day) then return true; end if;
  update public.docs set data = jsonb_set(data, '{absences}',
      case when jsonb_typeof(data -> 'absences') = 'array' then data -> 'absences' else '[]'::jsonb end || to_jsonb(p_day)), updated_at = now()
    where coll = 'kids' and id = v_kid;
  lbl := case when dd = today then 'today' else 'on ' || to_char(dd, 'Dy DD Mon') end;
  insert into public.docs (coll, id, data, owner, parties)
  values ('notifications', 'ka' || replace(gen_random_uuid()::text, '-', ''),
    jsonb_build_object('userId', v_parent, 'type', 'info', 'link', 'p-home', 'read', false, 'ts', nowms,
      'text', coalesce(v_name, 'Your child') || ' says they are not riding ' || lbl || '.'),
    auth.uid(), array[v_parent]);
  for drv in select distinct b.data ->> 'driverId' from public.docs b where b.coll = 'bookings' and not b.deleted
               and b.data ->> 'kidId' = v_kid and b.data ->> 'status' in ('active','trip') and b.data ->> 'driverId' is not null loop
    insert into public.docs (coll, id, data, owner, parties)
    values ('notifications', 'ka' || replace(gen_random_uuid()::text, '-', ''),
      jsonb_build_object('userId', drv, 'type', 'info', 'link', 'd-trip', 'read', false, 'ts', nowms,
        'text', coalesce(v_name, 'A child') || ' is not riding ' || lbl || '.'),
      auth.uid(), array[drv]);
  end loop;
  return true;
end $$;

revoke execute on function public._is_kid_login(uuid), public._kid_ctx(text), public._kid_perm(jsonb, text, boolean),
  public._kid_driver(text, text), public._kid_put(text, text, jsonb), public._parties(text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.put_doc(text, text, jsonb), public.fetch_docs(timestamptz),
  public.kid_link_create(text, text), public.kid_link_claim(text), public.kid_unlink(text), public.kid_absent(text) from public, anon;
grant execute on function public.put_doc(text, text, jsonb), public.fetch_docs(timestamptz),
  public.kid_link_create(text, text), public.kid_link_claim(text), public.kid_unlink(text), public.kid_absent(text) to authenticated;

select 'Enivel kid logins ready' as status;

-- r10:docs
-- =====================================================================
-- Round 10 · driver documents
--   verify_driver(token)  public live check behind the roadblock-card QR
--                         (anyone with the link, no sign-in needed)
--   docs_held_drivers()   drivers whose PrDP or driver's licence has
--                         expired; their routes are hidden from Find
-- Runs after setup.sql. Safe to run again.
-- Dates are 'YYYY-MM-DD' (South African calendar day). 'none' = no expiry.
-- Same rules as docStatus() in the app: soon = 30 days or less.
-- =====================================================================

-- 'YYYY-MM-DD' text to a date, or null when it is not a real date.
create or replace function public._docs_date(p text) returns date
language plpgsql immutable as $$
begin
  if p is null or p !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return p::date;
exception when others then return null;
end $$;

-- One document's state: none | missing | expired | soon | ok
create or replace function public._docs_state(p_until text, p_label text, p_key text) returns jsonb
language plpgsql stable as $$
declare today date := (now() at time zone 'Africa/Johannesburg')::date; d date; n int;
begin
  if p_until = 'none' then
    return jsonb_build_object('key', p_key, 'label', p_label, 'state', 'none', 'until', 'none'); end if;
  d := public._docs_date(p_until);
  if d is null then return jsonb_build_object('key', p_key, 'label', p_label, 'state', 'missing'); end if;
  n := d - today;
  return jsonb_build_object('key', p_key, 'label', p_label, 'until', to_char(d, 'YYYY-MM-DD'), 'days', n,
    'state', case when n < 0 then 'expired' when n <= 30 then 'soon' else 'ok' end);
end $$;

-- Public live check. Returns null for a short, unknown or reset token.
-- Never returns the ID number, phone, document numbers or any image.
create or replace function public.verify_driver(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u public.docs%rowtype; dv jsonb; vs jsonb; docs jsonb; pol date; pol_until date;
begin
  if p_token is null or length(p_token) < 24 or length(p_token) > 128 or p_token !~ '^[A-Za-z0-9_-]+$' then return null; end if;
  select * into u from public.docs
   where coll = 'users' and not deleted and data ->> 'verifyToken' = p_token limit 1;
  if not found then return null; end if;
  dv := case when jsonb_typeof(u.data -> 'docValid') = 'object' then u.data -> 'docValid' else '{}'::jsonb end;
  pol := public._docs_date(coalesce(nullif(dv #>> '{police,issued}', ''), u.data ->> 'policeDate'));
  if pol is not null then pol_until := (pol + interval '12 months')::date; end if;
  docs := jsonb_build_array(
    jsonb_build_object('key', 'id', 'label', 'SA ID / passport', 'until', 'none',
      'state', case when coalesce(u.data ->> 'idNumber', '') <> '' or jsonb_typeof(u.data #> '{verification,docs,id}') = 'string'
                    then 'none' else 'missing' end),
    public._docs_state(nullif(dv #>> '{licence,until}', ''), 'Driver''s licence', 'licence'),
    public._docs_state(coalesce(nullif(dv #>> '{prdp,until}', ''), nullif(u.data ->> 'prdpExpiry', '')), 'PrDP', 'prdp'),
    case when pol is null then jsonb_build_object('key', 'police', 'label', 'Police clearance', 'state', 'missing')
         else public._docs_state(to_char(pol_until, 'YYYY-MM-DD'), 'Police clearance', 'police')
              || jsonb_build_object('issued', to_char(pol, 'YYYY-MM-DD')) end,
    public._docs_state(nullif(dv #>> '{opLicence,until}', ''), 'Operating licence', 'opLicence'),
    public._docs_state(nullif(dv #>> '{insurance,until}', ''), 'Passenger insurance', 'insurance'));
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id, 'make', v.data -> 'make', 'model', v.data -> 'model', 'color', v.data -> 'color',
           'plate', v.data -> 'plate', 'seats', v.data -> 'seats',
           'disc', public._docs_state(nullif(v.data #>> '{docValid,disc,until}', ''), 'Licence disc', 'disc'),
           'rwc', public._docs_state(nullif(v.data #>> '{docValid,rwc,until}', ''), 'Roadworthy', 'rwc'))
         order by case when v.data ->> 'createdAt' ~ '^\d{1,15}$' then (v.data ->> 'createdAt')::bigint end nulls last, v.id), '[]'::jsonb)
    into vs from public.docs v
   where v.coll = 'vehicles' and not v.deleted and v.data ->> 'driverId' = u.id;
  return jsonb_build_object(
    'name', u.data ->> 'name',
    'status', coalesce(u.data #>> '{verification,status}', 'none'),
    'active', not (coalesce(u.data ->> 'banned', '') = 'true' or coalesce(u.data ->> 'suspended', '') = 'true'),
    'vehicles', vs, 'docs', docs,
    'checkedAt', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
end $$;

-- Drivers whose PrDP or driver's licence has expired (ids only).
-- The app hides their routes from Find until the date is updated.
create or replace function public.docs_held_drivers() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(d.id order by d.id), '[]'::jsonb) from public.docs d
  where auth.uid() is not null and d.coll = 'users' and not d.deleted
    and coalesce(d.data ->> 'role', '') in ('driver', 'admin')
    and ((public._docs_state(coalesce(nullif(d.data #>> '{docValid,prdp,until}', ''), nullif(d.data ->> 'prdpExpiry', '')), '', '') ->> 'state') = 'expired'
      or (public._docs_state(nullif(d.data #>> '{docValid,licence,until}', ''), '', '') ->> 'state') = 'expired')
$$;

revoke execute on function public._docs_date(text), public._docs_state(text, text, text) from public, anon, authenticated;
revoke execute on function public.verify_driver(text), public.docs_held_drivers() from public, anon, authenticated;
grant execute on function public.verify_driver(text) to anon, authenticated;
grant execute on function public.docs_held_drivers() to authenticated;

select 'Enivel driver documents ready' as status;

-- r10:trip
-- =====================================================================
-- Round 10 · trip: phone pop-ups for parents and kids.
-- "Driver nearby", picked up, dropped off, driver outside, running late,
-- emergency alerts ... reach the phone even when Enivel is closed.
-- The Enivel Worker calls notif_push (right after the app saves a
-- notification) and notif_push_due (every minute) with the secret key.
-- Nothing here can be called from the app. Safe to run again.
-- Run after setup.sql (needs public.docs, public.admins, public.push_log).
-- =====================================================================

-- notification types that deserve a phone pop-up
create or replace function public._tp_push_types() returns text[]
language sql immutable as $$
  select array['approach','pickup','dropoff','arrived','hoot','late','ontime',
               'kid-sos','sos','emergency','ride-check','handover']
$$;

-- Is the sender really connected to the person receiving the pop-up?
-- (stops a stranger from sending lock-screen pop-ups to anyone)
create or replace function public._tp_linked(p_sender uuid, p_to text, p_type text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare s text := p_sender::text;
begin
  if p_sender is null or coalesce(p_to, '') = '' then return false; end if;
  if s = p_to then return true; end if;
  if exists (select 1 from public.admins a where a.user_id = p_sender) then return true; end if;
  if p_to = 'admin' then return p_type in ('sos', 'kid-sos', 'emergency'); end if;
  -- parent <-> driver of a booking
  if exists (select 1 from public.docs b
             where b.coll = 'bookings' and not b.deleted
               and b.data ->> 'status' in ('active', 'trip', 'done')
               and ((b.data ->> 'parentId' = s and b.data ->> 'driverId' = p_to)
                 or (b.data ->> 'driverId' = s and b.data ->> 'parentId' = p_to))) then return true; end if;
  -- a child's own login (kids.accountId) <-> its parent or its driver.
  -- The login must not be a parent or driver account.
  if exists (select 1 from public.docs k
             where k.coll = 'kids' and not k.deleted
               and jsonb_typeof(k.data -> 'accountId') = 'string'
               and k.data ->> 'accountId' in (s, p_to)
               and exists (select 1 from public.docs ku where ku.coll = 'users' and not ku.deleted
                           and ku.id = k.data ->> 'accountId'
                           and coalesce(ku.data ->> 'role', '') not in ('parent', 'driver'))
               and (
                 (k.data ->> 'accountId' = p_to and (k.data ->> 'parentId' = s or exists (
                    select 1 from public.docs b where b.coll = 'bookings' and not b.deleted
                      and b.data ->> 'kidId' = k.id and b.data ->> 'driverId' = s
                      and b.data ->> 'status' in ('active', 'trip', 'done'))))
                 or
                 (k.data ->> 'accountId' = s and (k.data ->> 'parentId' = p_to or exists (
                    select 1 from public.docs b where b.coll = 'bookings' and not b.deleted
                      and b.data ->> 'kidId' = k.id and b.data ->> 'driverId' = p_to
                      and b.data ->> 'status' in ('active', 'trip', 'done'))))
               )) then return true; end if;
  return false;
end $$;

-- The pop-ups for one notification: one row per phone of the person it is for.
-- Only fresh (saved in the last 5 minutes), unread, pop-up-worthy notifications,
-- and each one only once (push_log 'n:<id>').
create or replace function public._tp_notif_rows(p_id text)
returns table (endpoint text, p256dh text, auth text, title text, body text, tag text, url text)
language plpgsql security definer set search_path = public as $$
declare
  n record; ty text; tos text[]; sub jsonb; ins int;
  nowms numeric := extract(epoch from now()) * 1000;
begin
  if p_id is null or p_id !~ '^[A-Za-z0-9_-]{1,64}$' then return; end if;
  select d.id, d.data, d.owner, d.updated_at into n
    from public.docs d where d.coll = 'notifications' and d.id = p_id and not d.deleted;
  if not found then return; end if;
  ty := coalesce(n.data ->> 'type', 'info');
  if not (ty = any (public._tp_push_types())) then return; end if;
  if coalesce(n.data ->> 'read', 'false') = 'true' or coalesce(n.data ->> 'answered', 'false') = 'true' then return; end if;
  if n.updated_at < now() - interval '5 minutes' then return; end if;
  if jsonb_typeof(n.data -> 'ts') = 'number'
     and ((n.data ->> 'ts')::numeric < nowms - 900000 or (n.data ->> 'ts')::numeric > nowms + 900000) then return; end if;
  if coalesce(jsonb_typeof(n.data -> 'userId'), '') <> 'string' then return; end if;
  if not public._tp_linked(n.owner, n.data ->> 'userId', ty) then return; end if;
  insert into public.push_log (ptag) values ('n:' || n.id) on conflict do nothing;
  get diagnostics ins = row_count;
  if ins = 0 then return; end if;   -- already sent
  if n.data ->> 'userId' = 'admin' then
    select coalesce(array_agg(a.user_id::text), '{}') into tos from public.admins a;
  else
    tos := array[n.data ->> 'userId'];
  end if;
  title := case ty
    when 'approach' then 'Driver nearby'
    when 'pickup' then 'Picked up'
    when 'dropoff' then 'Dropped off'
    when 'arrived' then 'Driver outside'
    when 'hoot' then 'Driver outside'
    when 'late' then 'Running late'
    when 'ontime' then 'Back on time'
    when 'kid-sos' then '🚨 Emergency'
    when 'sos' then '🚨 Emergency'
    when 'emergency' then '🚨 Emergency'
    when 'ride-check' then 'Ride check'
    when 'handover' then 'Handover check'
    else 'Enivel' end;
  body := left(coalesce(n.data ->> 'text', ''), 240);
  tag := 'n-' || n.id;
  url := case when coalesce(n.data ->> 'link', '') ~ '^[a-z0-9-]{1,30}$' then n.data ->> 'link' else '' end;
  for sub in select s.value from public.docs u
             cross join lateral jsonb_array_elements(case when jsonb_typeof(u.data -> 'pushSubs') = 'array' then u.data -> 'pushSubs' else '[]'::jsonb end) s
             where u.coll = 'users' and not u.deleted and u.id = any (tos) loop
    endpoint := sub ->> 'endpoint'; p256dh := sub #>> '{keys,p256dh}'; auth := sub #>> '{keys,auth}';
    if endpoint is null or endpoint !~ '^https://' or p256dh is null or auth is null then continue; end if;
    return next;
  end loop;
end $$;

-- Worker: right after the app saved notification p_id.
create or replace function public.notif_push(p_id text)
returns table (endpoint text, p256dh text, auth text, title text, body text, tag text, url text)
language plpgsql security definer set search_path = public as $$
begin
  return query select * from public._tp_notif_rows(p_id);
end $$;

-- Worker cron (every minute): anything fresh that was not sent yet.
create or replace function public.notif_push_due()
returns table (endpoint text, p256dh text, auth text, title text, body text, tag text, url text)
language plpgsql security definer set search_path = public as $$
declare nid text;
begin
  for nid in select d.id from public.docs d
             where d.coll = 'notifications' and not d.deleted
               and d.updated_at > now() - interval '5 minutes'
               and coalesce(d.data ->> 'type', '') = any (public._tp_push_types())
               and coalesce(d.data ->> 'read', 'false') <> 'true'
               and not exists (select 1 from public.push_log l where l.ptag = 'n:' || d.id)
             order by d.updated_at limit 500 loop
    return query select * from public._tp_notif_rows(nid);
  end loop;
end $$;

revoke execute on function public._tp_push_types(), public._tp_linked(uuid, text, text), public._tp_notif_rows(text),
  public.notif_push(text), public.notif_push_due() from public, anon, authenticated;
grant execute on function public.notif_push(text), public.notif_push_due() to service_role;

select 'Enivel parent pop-ups ready' as status;

-- r10:ops
-- Round 10 · ops: rules for driver pre-trip vehicle checks (collection 'checks').
-- Runs after setup.sql. Safe to run more than once.
-- put_doc already makes sure a NEW check names the caller as driverId. This trigger also covers edits and the
-- details: a check always belongs to the account that owns the row, that account must be a driver checking one
-- of their own vehicles, 'day' is a date, 'items' is an object, a photo is a small real image, and allOk is
-- worked out here (true only when every item is true), so nobody can fake a green tick for parents.
create or replace function public._ops_checks_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int; bad int;
begin
  if new.coll <> 'checks' or new.deleted then return new; end if;
  if public.is_admin() then return new; end if;
  if coalesce(new.data ->> 'driverId', '') <> coalesce(new.owner::text, '-') then
    raise exception 'You cannot create this'; end if;
  if tg_op = 'INSERT' or old.deleted or (old.data ->> 'vehicleId') is distinct from (new.data ->> 'vehicleId') then
    if not exists (select 1 from public.docs u where u.coll = 'users' and u.id = new.owner::text and not u.deleted and u.data ->> 'role' = 'driver') then
      raise exception 'Only drivers can log vehicle checks'; end if;
    if not exists (select 1 from public.docs v where v.coll = 'vehicles' and v.id = new.data ->> 'vehicleId' and not v.deleted and v.data ->> 'driverId' = new.owner::text) then
      raise exception 'You can only check your own vehicle'; end if;
  end if;
  if coalesce(new.data ->> 'day', '') !~ '^\d{4}-\d{2}-\d{2}$' or jsonb_typeof(new.data -> 'items') is distinct from 'object' then
    raise exception 'Invalid vehicle check'; end if;
  if jsonb_typeof(new.data -> 'photo') = 'string'
     and ((new.data ->> 'photo') !~ '^data:image/(jpeg|jpg|png|webp)[;,]' or octet_length(new.data ->> 'photo') > 400000) then
    raise exception 'Photos must be small image files'; end if;
  select count(*), count(*) filter (where value <> 'true'::jsonb) into n, bad from jsonb_each(new.data -> 'items');
  new.data := jsonb_set(new.data, '{allOk}', to_jsonb(n >= 8 and bad = 0));
  if not (n >= 8 and bad = 0) then new.data := jsonb_set(new.data, '{okAt}', 'null'::jsonb); end if;
  if length(coalesce(new.data ->> 'notes', '')) > 200 then
    new.data := jsonb_set(new.data, '{notes}', to_jsonb(left(new.data ->> 'notes', 200))); end if;
  return new;
end $$;
revoke execute on function public._ops_checks_guard() from public, anon, authenticated;

drop trigger if exists ops_checks_guard on public.docs;
create trigger ops_checks_guard before insert or update on public.docs
  for each row when (new.coll = 'checks') execute function public._ops_checks_guard();

-- r10:admin
-- =====================================================================
-- Round 10 · admin: System status probe (admin only, read only).
-- The admin's System status page sends the list of database functions the
-- app calls; this answers which ones exist, so the page can say
-- "run the setup script again" when something is missing. Changes nothing.
-- =====================================================================
create or replace function public.admin_sys_check(p_names jsonb default '[]'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fns jsonb := '{}'::jsonb; n text; src text; k int := 0;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Admin only'; end if;
  if jsonb_typeof(p_names) = 'array' then
    for n in select jsonb_array_elements_text(p_names) loop
      k := k + 1; exit when k > 200;
      if n ~ '^[a-z_][a-z0-9_]{0,62}$' then
        fns := fns || jsonb_build_object(n, exists (
          select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
          where s.nspname = 'public' and p.proname = n));
      end if;
    end loop;
  end if;
  select p.prosrc into src from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = 'public' and p.proname = 'put_doc' limit 1;
  return jsonb_build_object(
    'fns', fns,
    'audit', coalesce(position('''audit''' in src) > 0, false),
    'checks', coalesce(position('''checks''' in src) > 0, false),
    'docs', (select count(*) from public.docs where not deleted),
    'now', (extract(epoch from now()) * 1000)::bigint);
end $$;
revoke execute on function public.admin_sys_check(jsonb) from public, anon;
grant execute on function public.admin_sys_check(jsonb) to authenticated;

select 'Enivel admin status check ready' as status;

-- r10:pays
-- =====================================================================
-- Enivel Pays (round 10, layer "pays"). Run after setup.sql. Safe to run again.
--  1. Pay for parents: the admin picks families and pays their month by card
--     on PayFast's own page (the Enivel Worker signs the form and confirms
--     PayFast's notice), or records a payment made another way (EFT / other).
--  2. Enivel Pays: a random monthly draw of one family, a certificate for the
--     parent, and a public counter "Enivel paid for X kids this month".
-- Amounts are always worked out here from bookings, routes and offers,
-- never taken from the app. Card details never reach Enivel.
-- =====================================================================
do $$ begin if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role; end if; end $$;

create table if not exists public.pay_intents (
  id            text primary key,
  kind          text not null default 'admin',     -- 'admin' (picked by the admin) | 'draw' (Enivel Pays draw)
  method        text not null default 'card',      -- 'card' (PayFast) | 'manual' (EFT / other, recorded by the admin)
  admin_id      uuid not null,
  month         text not null,                     -- 'YYYY-MM'
  items         jsonb not null default '[]'::jsonb, -- [{parentId,name,bookingIds,kidIds,kidNames,amount,lines:[{bookingId,kidId,kidName,driverId,price,fee}]}]
  amount        numeric(12,2) not null,
  status        text not null default 'pending',   -- 'pending' | 'paid' | 'cancelled'
  pf_payment_id text,
  note          text,
  applied       jsonb,
  created_at    timestamptz not null default now(),
  paid_at       timestamptz
);
alter table public.pay_intents enable row level security;
revoke all on public.pay_intents from anon, authenticated;

create table if not exists public.pays_draws (
  id         text primary key,
  month      text not null,
  winner_id  text not null,
  eligible   int  not null,
  admin_id   uuid not null,
  created_at timestamptz not null default now()
);
alter table public.pays_draws enable row level security;
revoke all on public.pays_draws from anon, authenticated;

-- ---------- helpers (not callable from the app) ----------
create or replace function public._pays_num(t text) returns numeric
language plpgsql immutable as $$
begin return t::numeric; exception when others then return null; end $$;

create or replace function public._pays_month_ok(p text) returns boolean
language sql immutable as $$ select coalesce(p ~ '^\d{4}-(0[1-9]|1[0-2])$', false) $$;

create or replace function public._pays_now_month() returns text
language sql stable as $$ select to_char(now() at time zone 'Africa/Johannesburg', 'YYYY-MM') $$;

create or replace function public._pays_next_month() returns text
language sql stable as $$ select to_char((now() at time zone 'Africa/Johannesburg') + interval '1 month', 'YYYY-MM') $$;

create or replace function public._pays_month_label(p text) returns text
language sql stable as $$ select trim(to_char(to_date(p || '-01', 'YYYY-MM-DD'), 'FMMonth YYYY')) $$;

-- "Naledi Mokoena" -> "Naledi M." (public wall shows no more than this)
create or replace function public._pays_wall_name(n text) returns text
language sql immutable as $$
  select case when position(' ' in btrim(coalesce(n,''))) > 0
    then split_part(btrim(n), ' ', 1) || ' ' || upper(left(regexp_replace(btrim(n), '^.*\s', ''), 1)) || '.'
    else btrim(coalesce(n,'')) end
$$;

-- paid by the parent, or already covered by Enivel, for that month
create or replace function public._pays_booking_paid(p_id text, p_data jsonb, p_month text) returns boolean
language sql stable security definer set search_path = public as $$
  select (jsonb_typeof(p_data -> 'sponsoredMonths') = 'array' and (p_data -> 'sponsoredMonths') ? p_month)
      or exists (select 1 from public.docs t where t.coll = 'transactions' and not t.deleted
                 and t.data ->> 'bookingId' = p_id and t.data ->> 'month' = p_month
                 and t.data ->> 'type' in ('subscription','sponsorship'))
$$;

-- monthly transport price of a booking. Never more than the route's (or accepted offer's) price,
-- so an edited booking can't make Enivel pay more than the real price.
create or replace function public._pays_price(b jsonb) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare p numeric := public._pays_num(b ->> 'price'); ref numeric;
begin
  if p is null or p <= 0 or p > 100000 then return null; end if;
  if jsonb_typeof(b -> 'fromRequest') = 'string' then
    select public._pays_num(o.data ->> 'price') into ref
    from public.docs rq join public.docs o on o.coll = 'offers' and o.id = rq.data ->> 'acceptedOffer' and not o.deleted
    where rq.coll = 'requests' and rq.id = b ->> 'fromRequest';
  else
    select public._pays_num(r.data ->> 'price') into ref from public.docs r where r.coll = 'routes' and r.id = b ->> 'routeId' and not r.deleted;
  end if;
  if ref is not null and ref > 0 and ref < p then p := ref; end if;
  return round(p, 2);
end $$;

-- what one family owes for a month: active monthly bookings not yet paid or covered (transport + 2% fee each)
create or replace function public._pays_family(p_parent text, p_month text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u jsonb; b record; pr numeric; fee numeric; kid text; lines jsonb := '[]'::jsonb; tot numeric := 0; names text[] := '{}'; kids text[] := '{}'; bids text[] := '{}';
begin
  select data into u from public.docs where coll = 'users' and id = p_parent and not deleted;
  if u is null or coalesce(u ->> 'role','') <> 'parent' then return null; end if;
  if coalesce(u ->> 'banned','false') = 'true' or coalesce(u ->> 'suspended','false') = 'true' then return null; end if;
  for b in select d.id, d.data from public.docs d
           where d.coll = 'bookings' and not d.deleted and d.data ->> 'parentId' = p_parent
             and d.data ->> 'status' = 'active' and coalesce(d.data ->> 'once','false') <> 'true'
           order by d.id loop
    if public._pays_booking_paid(b.id, b.data, p_month) then continue; end if;
    pr := public._pays_price(b.data); if pr is null then continue; end if;
    fee := round(pr * 0.02, 2);
    select data ->> 'name' into kid from public.docs where coll = 'kids' and id = b.data ->> 'kidId' and not deleted;
    lines := lines || jsonb_build_object('bookingId', b.id, 'kidId', b.data ->> 'kidId', 'kidName', coalesce(kid, 'Child'),
                                         'driverId', b.data ->> 'driverId', 'price', pr, 'fee', fee);
    tot := tot + pr + fee; bids := bids || b.id;
    if not (coalesce(b.data ->> 'kidId','') = any (kids)) then kids := kids || coalesce(b.data ->> 'kidId',''); names := names || coalesce(kid, 'Child'); end if;
  end loop;
  if cardinality(bids) = 0 then return null; end if;
  return jsonb_build_object('parentId', p_parent, 'name', u ->> 'name', 'bookingIds', to_jsonb(bids), 'kidIds', to_jsonb(kids),
                            'kidNames', to_jsonb(names), 'amount', tot, 'lines', lines);
end $$;

create or replace function public._pays_items(p_parents jsonb, p_month text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare items jsonb := '[]'::jsonb; f jsonb; pid text; seen text[] := '{}'; tot numeric := 0;
begin
  if p_parents is null or jsonb_typeof(p_parents) <> 'array' or jsonb_array_length(p_parents) = 0 then raise exception 'Pick at least one family'; end if;
  if jsonb_array_length(p_parents) > 300 then raise exception 'Too many families at once (300 max)'; end if;
  for pid in select value from jsonb_array_elements_text(p_parents) loop
    if pid is null or pid = any (seen) then continue; end if; seen := seen || pid;
    f := public._pays_family(pid, p_month);
    if f is not null then items := items || f; tot := tot + (f ->> 'amount')::numeric; end if;
  end loop;
  if jsonb_array_length(items) = 0 then raise exception 'Nothing to pay: already paid for %', public._pays_month_label(p_month); end if;
  return jsonb_build_object('items', items, 'amount', tot);
end $$;

create or replace function public._pays_check_month(p_month text) returns void
language plpgsql stable as $$
begin
  if not public._pays_month_ok(p_month) or p_month not in (public._pays_now_month(), public._pays_next_month()) then
    raise exception 'Pick this month or next month'; end if;
end $$;

-- parents who can win the draw: monthly booking still unpaid that month, not banned or suspended
create or replace function public._pays_eligible(p_month text) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct d.data ->> 'parentId'), '{}')
  from public.docs d join public.docs u on u.coll = 'users' and u.id = d.data ->> 'parentId' and not u.deleted
  where d.coll = 'bookings' and not d.deleted and d.data ->> 'status' = 'active' and coalesce(d.data ->> 'once','false') <> 'true'
    and u.data ->> 'role' = 'parent' and coalesce(u.data ->> 'banned','false') <> 'true' and coalesce(u.data ->> 'suspended','false') <> 'true'
    and public._pays_price(d.data) is not null and not public._pays_booking_paid(d.id, d.data, p_month)
$$;

-- apply a payment: covers each booking (same shapes as the app's sponsor(): bookings.sponsoredMonths and
-- 'sponsorship' transactions), adds a certificate, and tells each parent and driver. Caller holds the row lock.
create or replace function public._pays_apply(p_id text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare i public.pay_intents%rowtype; it jsonb; l jsonb; b record; d jsonb; label text; cert text; names text[];
  nowms bigint := (extract(epoch from now()) * 1000)::bigint; fams int := 0; done int := 0; skipped int := 0; adm text; tail text;
begin
  select * into i from public.pay_intents where id = p_id;
  label := public._pays_month_label(i.month); adm := i.admin_id::text;
  tail := case when i.month = public._pays_now_month() then 'Nothing to pay this month.' else 'Nothing to pay for ' || label || '.' end;
  for it in select value from jsonb_array_elements(i.items) loop
    names := '{}';
    cert := 'EP-' || replace(i.month, '-', '') || '-' || upper(substr(md5(i.id || ':' || (it ->> 'parentId')), 1, 6));
    for l in select value from jsonb_array_elements(it -> 'lines') loop
      select x.id, x.data into b from public.docs x where x.coll = 'bookings' and x.id = l ->> 'bookingId' and not x.deleted for update;
      if not found or b.data ->> 'status' <> 'active' or public._pays_booking_paid(b.id, b.data, i.month) then skipped := skipped + 1; continue; end if;
      update public.docs set
        data = jsonb_set(jsonb_set(data, '{sponsoredMonths}',
                 case when jsonb_typeof(data -> 'sponsoredMonths') = 'array' then (data -> 'sponsoredMonths') || to_jsonb(i.month) else jsonb_build_array(i.month) end),
               '{paysCerts}',
                 coalesce(case when jsonb_typeof(data -> 'paysCerts') = 'object' then data -> 'paysCerts' end, '{}'::jsonb)
                 || jsonb_build_object(i.month, jsonb_build_object('no', cert, 'at', nowms, 'kind', i.kind, 'method', i.method))),
        updated_at = now()
      where coll = 'bookings' and id = b.id;
      d := jsonb_build_object('type', 'sponsorship', 'amount', (l ->> 'price')::numeric, 'from', 'enivel', 'to', b.data ->> 'driverId',
             'bookingId', b.id, 'kidId', b.data ->> 'kidId', 'parentId', it ->> 'parentId', 'month', i.month, 'ts', nowms,
             'note', 'Transport for ' || label || ' paid by Enivel admin', 'paidBy', 'admin', 'method', i.method, 'intentId', i.id);
      d := d || jsonb_build_object('id', 'tx' || replace(gen_random_uuid()::text, '-', ''));
      insert into public.docs (coll, id, data, owner, parties) values ('transactions', d ->> 'id', d, i.admin_id, public._parties('transactions', d));
      d := jsonb_build_object('type', 'platform_fee', 'amount', (l ->> 'fee')::numeric, 'from', adm, 'to', 'enivel',
             'bookingId', b.id, 'parentId', it ->> 'parentId', 'month', i.month, 'ts', nowms,
             'note', '2% fee for ' || label || ', paid by Enivel admin', 'paidBy', 'admin', 'method', i.method, 'intentId', i.id);
      d := d || jsonb_build_object('id', 'tx' || replace(gen_random_uuid()::text, '-', ''));
      insert into public.docs (coll, id, data, owner, parties) values ('transactions', d ->> 'id', d, i.admin_id, public._parties('transactions', d));
      d := jsonb_build_object('userId', b.data ->> 'driverId', 'type', 'pay', 'link', 'd-billing', 'read', false, 'ts', nowms,
             'text', '💸 Enivel paid ' || coalesce(l ->> 'kidName', 'a child') || '''s transport for ' || label || '. You receive the full price.');
      d := d || jsonb_build_object('id', 'nt' || replace(gen_random_uuid()::text, '-', ''));
      insert into public.docs (coll, id, data, owner, parties) values ('notifications', d ->> 'id', d, i.admin_id, public._parties('notifications', d));
      done := done + 1;
      if not (coalesce(l ->> 'kidName', 'Child') = any (names)) then names := names || coalesce(l ->> 'kidName', 'Child'); end if;
    end loop;
    if cardinality(names) > 0 then
      fams := fams + 1;
      d := jsonb_build_object('userId', it ->> 'parentId', 'type', 'pay', 'link', 'p-cert', 'read', false, 'ts', nowms,
             'text', case when i.kind = 'draw' then '🎉 Enivel Pays picked your family! ' else '' end
                     || '🎁 Your transport fee for ' || label || ' (' || array_to_string(names, ', ') || ') has been paid by Enivel admin. ' || tail);
      d := d || jsonb_build_object('id', 'nt' || replace(gen_random_uuid()::text, '-', ''));
      insert into public.docs (coll, id, data, owner, parties) values ('notifications', d ->> 'id', d, i.admin_id, public._parties('notifications', d));
    end if;
  end loop;
  if skipped > 0 and i.method = 'card' then
    d := jsonb_build_object('userId', 'admin', 'type', 'pay', 'link', 'a-pays', 'read', false, 'ts', nowms,
           'text', '⚠️ Card payment ' || i.id || ': ' || skipped || ' booking(s) were already paid or ended before PayFast confirmed. Refund that part in PayFast if needed.');
    d := d || jsonb_build_object('id', 'nt' || replace(gen_random_uuid()::text, '-', ''));
    insert into public.docs (coll, id, data, owner, parties) values ('notifications', d ->> 'id', d, i.admin_id, public._parties('notifications', d));
  end if;
  update public.pay_intents set status = 'paid', paid_at = now(),
    applied = jsonb_build_object('families', fams, 'bookings', done, 'skipped', skipped) where id = p_id;
  return jsonb_build_object('families', fams, 'bookings', done, 'skipped', skipped);
end $$;

-- ---------- admin (signed in, checked with is_admin) ----------
-- start a card payment. Amounts are worked out here; the app only says which families.
create or replace function public.pay_intent_create(p_parents jsonb, p_month text, p_kind text default 'admin') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r jsonb; iid text; busy text;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Only the admin can do this'; end if;
  perform public._pays_check_month(p_month);
  if coalesce(p_kind, 'admin') not in ('admin','draw') then raise exception 'Unknown payment kind'; end if;
  r := public._pays_items(p_parents, p_month);
  -- a card payment for the same booking started in the last 30 minutes may still be confirming
  select x.id into busy from public.pay_intents x
  where x.status = 'pending' and x.method = 'card' and x.month = p_month and x.created_at > now() - interval '30 minutes'
    and exists (select 1 from jsonb_array_elements(x.items) a, jsonb_array_elements_text(a -> 'bookingIds') bid
                where bid in (select jsonb_array_elements_text(e -> 'bookingIds') from jsonb_array_elements(r -> 'items') e))
  limit 1;
  if busy is not null then raise exception 'A card payment for one of these families was started a few minutes ago. Wait for PayFast to confirm it, or cancel it under Recent payments.'; end if;
  iid := 'pi' || replace(gen_random_uuid()::text, '-', '');
  insert into public.pay_intents (id, kind, method, admin_id, month, items, amount)
  values (iid, coalesce(p_kind, 'admin'), 'card', auth.uid(), p_month, r -> 'items', (r ->> 'amount')::numeric);
  return jsonb_build_object('id', iid, 'amount', (r ->> 'amount')::numeric, 'month', p_month, 'items', r -> 'items', 'status', 'pending');
end $$;

create or replace function public.pay_intent_status(p_id text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Only the admin can do this'; end if;
  select jsonb_build_object('id', id, 'kind', kind, 'method', method, 'month', month, 'amount', amount, 'status', status,
           'items', items, 'applied', applied, 'note', note, 'createdAt', (extract(epoch from created_at) * 1000)::bigint,
           'paidAt', (extract(epoch from paid_at) * 1000)::bigint)
    into r from public.pay_intents where id = p_id;
  return r;
end $$;

create or replace function public.pay_intents_list(p_limit numeric default 20) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Only the admin can do this'; end if;
  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) into r from (
    select id, kind, method, month, amount, status, created_at, (extract(epoch from created_at) * 1000)::bigint as "createdAt",
           (extract(epoch from paid_at) * 1000)::bigint as "paidAt", applied, note,
           (select coalesce(jsonb_agg(e ->> 'name'), '[]'::jsonb) from jsonb_array_elements(items) e) as names
    from public.pay_intents order by created_at desc limit least(greatest(coalesce(p_limit, 20), 1), 100)::int) x;
  return r;
end $$;

create or replace function public.pay_intent_cancel(p_id text) returns text
language plpgsql volatile security definer set search_path = public as $$
declare s text;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Only the admin can do this'; end if;
  update public.pay_intents set status = 'cancelled' where id = p_id and status = 'pending' returning status into s;
  if s is null then select status into s from public.pay_intents where id = p_id; end if;
  return s;
end $$;

-- paid another way (EFT, cash at the office...): same effect, marked manual
create or replace function public.pay_record_manual(p_parents jsonb, p_month text, p_note text default null, p_kind text default 'admin') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r jsonb; iid text; a jsonb;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Only the admin can do this'; end if;
  perform public._pays_check_month(p_month);
  if coalesce(p_kind, 'admin') not in ('admin','draw') then raise exception 'Unknown payment kind'; end if;
  r := public._pays_items(p_parents, p_month);
  iid := 'pi' || replace(gen_random_uuid()::text, '-', '');
  insert into public.pay_intents (id, kind, method, admin_id, month, items, amount, note)
  values (iid, coalesce(p_kind, 'admin'), 'manual', auth.uid(), p_month, r -> 'items', (r ->> 'amount')::numeric, left(nullif(btrim(coalesce(p_note,'')), ''), 200));
  perform 1 from public.pay_intents where id = iid for update;
  a := public._pays_apply(iid);
  return jsonb_build_object('id', iid, 'amount', (r ->> 'amount')::numeric, 'month', p_month, 'items', r -> 'items', 'status', 'paid', 'applied', a);
end $$;

-- Enivel Pays draw: the app picks with crypto.getRandomValues; the server checks the winner was eligible and keeps a record
create or replace function public.pays_draw_record(p_month text, p_winner text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare pool text[]; did text;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Only the admin can do this'; end if;
  perform public._pays_check_month(p_month);
  pool := public._pays_eligible(p_month);
  if not (p_winner = any (pool)) then raise exception 'That family is not eligible for this draw'; end if;
  did := 'dr' || replace(gen_random_uuid()::text, '-', '');
  insert into public.pays_draws (id, month, winner_id, eligible, admin_id) values (did, p_month, p_winner, cardinality(pool), auth.uid());
  return jsonb_build_object('id', did, 'month', p_month, 'winnerId', p_winner, 'eligible', cardinality(pool));
end $$;

create or replace function public.pays_draws_list(p_limit numeric default 12) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Only the admin can do this'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'month', month, 'winnerId', winner_id, 'eligible', eligible,
           'at', (extract(epoch from created_at) * 1000)::bigint) order by created_at desc), '[]'::jsonb)
    into r from (select * from public.pays_draws order by created_at desc limit least(greatest(coalesce(p_limit, 12), 1), 60)::int) x;
  return r;
end $$;

-- ---------- Enivel Worker only (service role) ----------
create or replace function public.pay_intent_get(p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'amount', amount, 'status', status, 'month', month, 'kind', kind, 'method', method,
           'families', jsonb_array_length(items),
           'kids', (select count(*) from jsonb_array_elements(items) e, jsonb_array_elements(e -> 'kidIds') k))
  from public.pay_intents where id = p_id
$$;

-- PayFast confirmed the payment (signature, PayFast validate and amount already checked by the Worker).
-- Runs once: a second notice for the same payment changes nothing.
create or replace function public.pay_intent_complete(p_id text, p_pf_payment_id text, p_amount numeric) returns text
language plpgsql volatile security definer set search_path = public as $$
declare i public.pay_intents%rowtype;
begin
  select * into i from public.pay_intents where id = p_id for update;
  if not found then raise exception 'Unknown payment'; end if;
  if i.status = 'paid' then return 'already'; end if;
  if i.method <> 'card' then raise exception 'Not a card payment'; end if;
  if p_amount is null or abs(p_amount - i.amount) > 0.009 then raise exception 'Amount does not match this payment'; end if;
  update public.pay_intents set pf_payment_id = left(p_pf_payment_id, 64) where id = p_id;
  perform public._pays_apply(p_id);
  return 'paid';
end $$;

-- ---------- public (no sign-in): the Enivel Pays wall ----------
-- only totals, plus first name + surname initial of parents who switched on users.paysWall
create or replace function public.enivel_pays_public(p_month text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m text := coalesce(nullif(btrim(coalesce(p_month,'')), ''), public._pays_now_month()); r jsonb;
begin
  if not public._pays_month_ok(m) then raise exception 'Use a month like 2026-11'; end if;
  with b as (
    select d.data ->> 'kidId' kid, d.data ->> 'parentId' pid from public.docs d
    where d.coll = 'bookings' and not d.deleted and jsonb_typeof(d.data -> 'sponsoredMonths') = 'array' and (d.data -> 'sponsoredMonths') ? m),
  w as (
    select distinct u.id, public._pays_wall_name(u.data ->> 'name') nm from b join public.docs u on u.coll = 'users' and u.id = b.pid and not u.deleted
    where coalesce(u.data ->> 'paysWall','false') = 'true')
  select jsonb_build_object('month', m, 'label', public._pays_month_label(m),
    'kids', (select count(distinct kid) from b),
    'families', (select count(distinct pid) from b),
    'total', coalesce((select round(sum(coalesce(public._pays_num(t.data ->> 'amount'), 0)), 2) from public.docs t
                       where t.coll = 'transactions' and not t.deleted and t.data ->> 'type' = 'sponsorship' and t.data ->> 'month' = m), 0),
    'wall', coalesce((select jsonb_agg(nm order by nm) from (select nm from w where nm <> '' order by nm limit 200) z), '[]'::jsonb))
  into r;
  return r;
end $$;

revoke execute on function public._pays_num(text), public._pays_month_ok(text), public._pays_now_month(), public._pays_next_month(),
  public._pays_month_label(text), public._pays_wall_name(text), public._pays_booking_paid(text, jsonb, text), public._pays_price(jsonb),
  public._pays_family(text, text), public._pays_items(jsonb, text), public._pays_check_month(text), public._pays_eligible(text),
  public._pays_apply(text) from public, anon, authenticated;
revoke execute on function public.pay_intent_create(jsonb, text, text), public.pay_intent_status(text), public.pay_intents_list(numeric),
  public.pay_intent_cancel(text), public.pay_record_manual(jsonb, text, text, text), public.pays_draw_record(text, text),
  public.pays_draws_list(numeric) from public, anon;
grant execute on function public.pay_intent_create(jsonb, text, text), public.pay_intent_status(text), public.pay_intents_list(numeric),
  public.pay_intent_cancel(text), public.pay_record_manual(jsonb, text, text, text), public.pays_draw_record(text, text),
  public.pays_draws_list(numeric) to authenticated;
revoke execute on function public.pay_intent_get(text), public.pay_intent_complete(text, text, numeric) from public, anon, authenticated;
grant execute on function public.pay_intent_get(text), public.pay_intent_complete(text, text, numeric) to service_role;
grant execute on function public.enivel_pays_public(text) to anon, authenticated;

select 'Enivel Pays ready' as status;

-- r10:grow
-- =====================================================================
-- Enivel round 10: growth (public route page + referral stats).
-- Runs after setup.sql. Safe to run again.
-- =====================================================================

-- Public route card for share links (#route=<id>). Anyone may call it, even
-- without signing in, so it returns ONLY public details: no plate, phone,
-- GPS, children, parents or ids. Returns null when the route is paused or
-- deleted, or the driver is banned, suspended or not approved.
create or replace function public.public_route(p_id text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  r jsonb; d jsonb; v jsonb; did text;
  seats int; used int := 0; held int := 0;
  ravg numeric; rcnt int := 0; trips int := 0;
  price jsonb;
begin
  if p_id is null or p_id !~ '^[A-Za-z0-9_-]{1,64}$' then return null; end if;
  select data into r from public.docs where coll = 'routes' and id = p_id and not deleted;
  if r is null then return null; end if;
  if coalesce(r ->> 'active', 'false') <> 'true' then return null; end if;
  did := r ->> 'driverId';
  if did is null then return null; end if;
  select data into d from public.docs where coll = 'users' and id = did and not deleted;
  if d is null then return null; end if;
  if coalesce(d ->> 'banned', 'false') = 'true' or coalesce(d ->> 'suspended', 'false') = 'true'
     or coalesce(d #>> '{verification,status}', 'none') <> 'approved' then return null; end if;

  if coalesce(r ->> 'seats', '') ~ '^\d{1,4}$' then seats := (r ->> 'seats')::int; end if;
  select count(*)::int into used from public.docs
    where coll = 'bookings' and not deleted and data ->> 'routeId' = p_id
      and data ->> 'status' = 'active' and coalesce(data ->> 'once', 'false') <> 'true';
  select count(*)::int into held from public.docs
    where coll = 'waitlist' and not deleted and data ->> 'routeId' = p_id and data ->> 'status' = 'offered'
      and coalesce(data ->> 'offeredAt', '') ~ '^\d{1,15}$'
      and (data ->> 'offeredAt')::bigint > (extract(epoch from now()) * 1000)::bigint - 86400000;
  select round(avg((data ->> 'stars')::numeric), 1), count(*)::int into ravg, rcnt from public.docs
    where coll = 'ratings' and not deleted and data ->> 'driverId' = did
      and coalesce(data ->> 'stars', '') ~ '^[0-5](\.\d+)?$';
  select count(*)::int into trips from public.docs
    where coll = 'events' and not deleted and data ->> 'driverId' = did and data ->> 'type' = 'dropoff';
  if coalesce(r ->> 'vehicleId', '') <> '' then
    select data into v from public.docs where coll = 'vehicles' and id = r ->> 'vehicleId' and not deleted;
  end if;
  price := case when jsonb_typeof(r -> 'price') = 'number' then r -> 'price'
                when coalesce(r ->> 'price', '') ~ '^\d{1,7}(\.\d{1,2})?$' then to_jsonb((r ->> 'price')::numeric) end;

  return jsonb_strip_nulls(jsonb_build_object(
    'id', p_id,
    'title', left(r ->> 'name', 120),
    'type', case when r ->> 'type' = 'private' then 'private' else 'shared' end,
    'schools', left(r ->> 'schools', 240),
    'areas', left(concat_ws(', ', nullif(r ->> 'area', ''), nullif(r ->> 'suburbs', '')), 240),
    'pickupTime', left(r ->> 'pickupTime', 12),
    'dropoffTime', left(r ->> 'dropoffTime', 12),
    'afternoon', case when r ->> 'afternoon' = 'true' then true end,
    'price', price,
    'seats', seats,
    'free', case when seats is null then null else greatest(0, seats - used - held) end,
    'driverFirst', left(split_part(trim(coalesce(d ->> 'name', '')), ' ', 1), 40),
    'verified', true,
    'rating', ravg,
    'ratingCount', rcnt,
    'trips', trips,
    'vehicle', case when v is null then null else jsonb_strip_nulls(jsonb_build_object(
        'make', left(v ->> 'make', 40), 'model', left(v ->> 'model', 40),
        'seats', case when coalesce(v ->> 'seats', '') ~ '^\d{1,3}$' then (v ->> 'seats')::int end)) end));
end $$;
revoke execute on function public.public_route(text) from public;
grant execute on function public.public_route(text) to anon, authenticated;

-- How many people joined with my referral code (R50 credit each, see award_referral).
-- First names only. Signed-in people only see their own count.
create or replace function public.grow_referrals() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare n int; names jsonb;
begin
  if auth.uid() is null then return null; end if;
  select count(*)::int into n from public.docs
   where coll = 'users' and not deleted and data ->> 'referredBy' = auth.uid()::text;
  select coalesce(jsonb_agg(x.nm), '[]'::jsonb) into names from (
    select left(split_part(trim(coalesce(data ->> 'name', '')), ' ', 1), 40) nm from public.docs
     where coll = 'users' and not deleted and data ->> 'referredBy' = auth.uid()::text
     order by updated_at desc limit 30) x;
  return jsonb_build_object('count', n, 'earned', n * 50, 'names', names);
end $$;
revoke execute on function public.grow_referrals() from public, anon;
grant execute on function public.grow_referrals() to authenticated;

select 'Enivel growth ready' as status;

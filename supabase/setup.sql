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

-- Create or replace one document, with per-collection rules.
create or replace function public.put_doc(p_coll text, p_id text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; adm boolean := public.is_admin(); cur public.docs%rowtype; d jsonb := p_data;
begin
  if auth.uid() is null then raise exception 'Please sign in again'; end if;
  if p_coll not in ('users','kids','vehicles','routes','bookings','requests','offers','messages','events','transactions','notifications','ratings','settings') then
    raise exception 'Unknown collection %', p_coll; end if;
  if octet_length(p_data::text) > 3000000 then raise exception 'That is too large to save (photos too big?)'; end if;
  if p_coll = 'settings' and not adm then raise exception 'Only the admin can change settings'; end if;

  select * into cur from public.docs where coll = p_coll and id = p_id;

  if found and not cur.deleted then
    -- update an existing document
    if not (adm or cur.owner = auth.uid()
            or (me = any (cur.parties) and p_coll in ('bookings','notifications','messages'))) then
      raise exception 'You cannot change this'; end if;
    if p_coll = 'transactions' and not adm then raise exception 'Payments cannot be changed'; end if;
    if not adm and cur.owner <> auth.uid() then
      -- connected people may only change one field each
      if p_coll = 'notifications' then d := cur.data || jsonb_build_object('read', coalesce(d -> 'read', 'false'::jsonb));
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
      elsif p_coll in ('kids','requests','ratings','bookings') and coalesce(d ->> 'parentId','') <> me then raise exception 'You cannot create this';
      elsif p_coll in ('vehicles','routes','offers') and coalesce(d ->> 'driverId','') <> me then raise exception 'You cannot create this';
      elsif p_coll = 'messages' and coalesce(d ->> 'from','') <> me then raise exception 'You cannot create this';
      elsif p_coll = 'transactions' and coalesce(d ->> 'from','') <> me then raise exception 'You cannot create this';
      elsif p_coll = 'events' and not (coalesce(d ->> 'driverId','') = me or coalesce(d ->> 'by','') = me or coalesce(d ->> 'parentId','') = me) then raise exception 'You cannot create this';
      end if;
    end if;
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
grant execute on function public.phone_taken(text) to anon, authenticated;

select 'Enivel backend ready' as status;

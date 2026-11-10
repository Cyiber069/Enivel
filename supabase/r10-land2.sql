-- =====================================================================
-- 10 Nov: public growth features (callable without signing in).
--  coverage_public()       schools and areas that have verified drivers + school endorsements
--  school_routes(p_school) public route cards for one school (same public fields as public_route)
--  school_waitlist_join()  parents with no driver yet leave name, phone and school
--  school_waitlist_admin() admin: waiting parents grouped by school
--  check_driver(p_q)       anyone checks a driver by full name or number plate: verified status and
--                          document expiry dates only (no numbers, no plate, no phone). Drivers can opt out.
-- Safe to run again.
-- =====================================================================
create or replace function public._school_key(t text) returns text language sql immutable as $$
  select trim(regexp_replace(regexp_replace(lower(coalesce(t,'')),
    '\m(primary|secondary|high|school|schools|laerskool|hoerskool|hoërskool|skool|the|of|and|comprehensive|combined|college|academy)\M', ' ', 'g'),
    '[^a-z0-9]+', ' ', 'g'))
$$;
create or replace function public._driver_ok(d jsonb) returns boolean language sql immutable as $$
  select d is not null and coalesce(d ->> 'banned','false') <> 'true' and coalesce(d ->> 'suspended','false') <> 'true'
     and coalesce(d #>> '{verification,status}','none') = 'approved'
$$;

create or replace function public.coverage_public() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare out jsonb; endorse jsonb;
begin
  with rts as (
    select r.id, r.data from public.docs r join public.docs u on u.coll = 'users' and u.id = r.data ->> 'driverId' and not u.deleted
    where r.coll = 'routes' and not r.deleted and coalesce(r.data ->> 'active','false') = 'true' and public._driver_ok(u.data)),
  sch as (
    select trim(s) as school, rts.id, rts.data from rts,
      lateral regexp_split_to_table(coalesce(rts.data ->> 'schools',''), '\s*[,;/&]\s*|\s+and\s+') s
    where length(trim(s)) >= 3),
  agg as (
    select min(school) as school, public._school_key(school) as k, count(distinct id)::int as routes,
      string_agg(distinct nullif(trim(data ->> 'area'),''), ', ') as areas
    from sch group by public._school_key(school))
  select coalesce(jsonb_agg(jsonb_build_object('school', left(school,120), 'key', k, 'routes', routes, 'areas', left(coalesce(areas,''),200)) order by routes desc, school), '[]'::jsonb)
    into out from (select * from agg where k <> '' order by routes desc limit 400) a;
  select coalesce(data -> 'items', '[]'::jsonb) into endorse from public.docs where coll = 'settings' and id = 'endorse' and not deleted;
  return jsonb_build_object('schools', out, 'endorsements', coalesce(endorse, '[]'::jsonb));
end $$;
revoke execute on function public.coverage_public() from public;
grant execute on function public.coverage_public() to anon, authenticated;

create or replace function public.school_routes(p_school text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare k text := public._school_key(p_school); out jsonb := '[]'::jsonb; r record; c jsonb;
begin
  if k is null or length(k) < 3 then return out; end if;
  for r in select d.id from public.docs d where d.coll = 'routes' and not d.deleted and coalesce(d.data ->> 'active','false') = 'true'
           and exists (select 1 from regexp_split_to_table(coalesce(d.data ->> 'schools',''), '\s*[,;/&]\s*|\s+and\s+') s
                       where public._school_key(s) = k or (length(k) >= 6 and public._school_key(s) like '%' || k || '%'))
           limit 20 loop
    c := public.public_route(r.id);
    if c is not null then out := out || jsonb_build_array(c); end if;
  end loop;
  return out;
end $$;
revoke execute on function public.school_routes(text) from public;
grant execute on function public.school_routes(text) to anon, authenticated;

create table if not exists public.school_waitlist (
  id bigserial primary key, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  name text not null, phone text not null, school text not null, school_key text not null, area text, kids int not null default 1,
  lang text, contacted boolean not null default false);
create index if not exists school_waitlist_key on public.school_waitlist (school_key);
create unique index if not exists school_waitlist_phone_school on public.school_waitlist (phone, school_key);
alter table public.school_waitlist enable row level security;
revoke all on public.school_waitlist from anon, authenticated;

create or replace function public.school_waitlist_join(p_name text, p_phone text, p_school text, p_area text, p_kids numeric, p_lang text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ph text := regexp_replace(coalesce(p_phone,''), '[^0-9+]', '', 'g'); k text := public._school_key(p_school); n int;
begin
  if ph ~ '^\+27[0-9]{9}$' then ph := '0' || substr(ph, 4); end if;
  if ph !~ '^0[6-8][0-9]{8}$' then return jsonb_build_object('ok', false, 'error', 'phone'); end if;
  if length(trim(coalesce(p_name,''))) < 2 or length(p_name) > 60 then return jsonb_build_object('ok', false, 'error', 'name'); end if;
  if k is null or length(k) < 3 or length(p_school) > 120 then return jsonb_build_object('ok', false, 'error', 'school'); end if;
  if (select count(*) from public.school_waitlist where phone = ph and created_at > now() - interval '1 day') >= 5 then return jsonb_build_object('ok', false, 'error', 'limit'); end if;
  if (select count(*) from public.school_waitlist where created_at > now() - interval '1 hour') >= 1500 then return jsonb_build_object('ok', false, 'error', 'busy'); end if;
  insert into public.school_waitlist (name, phone, school, school_key, area, kids, lang)
  values (left(trim(p_name),60), ph, left(trim(p_school),120), k, left(trim(coalesce(p_area,'')),80), greatest(1, least(coalesce(round(p_kids)::int,1), 9)), left(coalesce(p_lang,''),5))
  on conflict (phone, school_key) do update set name = excluded.name, area = excluded.area, kids = excluded.kids, updated_at = now();
  select count(*)::int into n from public.school_waitlist where school_key = k;
  return jsonb_build_object('ok', true, 'waiting', n);
end $$;
revoke execute on function public.school_waitlist_join(text,text,text,text,numeric,text) from public;
grant execute on function public.school_waitlist_join(text,text,text,text,numeric,text) to anon, authenticated;

create or replace function public.school_waitlist_admin() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'bySchool', coalesce((select jsonb_agg(x order by (x ->> 'n')::int desc) from (
        select jsonb_build_object('school', min(school), 'n', count(*), 'kids', sum(kids), 'latest', max(updated_at)) x
        from public.school_waitlist group by school_key) s), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'phone', phone, 'school', school, 'area', area, 'kids', kids, 'at', updated_at, 'contacted', contacted) order by updated_at desc)
        from (select * from public.school_waitlist order by updated_at desc limit 500) w), '[]'::jsonb));
end $$;
revoke execute on function public.school_waitlist_admin() from public, anon;
grant execute on function public.school_waitlist_admin() to authenticated;

create or replace function public.school_waitlist_mark(p_id bigint, p_contacted boolean, p_delete boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if coalesce(p_delete,false) then delete from public.school_waitlist where id = p_id;
  else update public.school_waitlist set contacted = coalesce(p_contacted,true), updated_at = now() where id = p_id; end if;
end $$;
revoke execute on function public.school_waitlist_mark(bigint, boolean, boolean) from public, anon;
grant execute on function public.school_waitlist_mark(bigint, boolean, boolean) to authenticated;

-- ---- public "Check a driver" ----
create or replace function public._doc_until(dv jsonb, k text) returns text language sql immutable as $$
  select case when coalesce(dv #>> array[k,'until'],'') ~ '^\d{4}-\d{2}-\d{2}' then left(dv #>> array[k,'until'],10) end
$$;
create or replace function public.check_driver(p_q text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := lower(trim(coalesce(p_q,''))); qn text := regexp_replace(upper(coalesce(p_q,'')), '[^A-Z0-9]', '', 'g');
  words text[]; ids text[] := '{}'; out jsonb := '[]'::jsonb; d record; dv jsonb; pol text; vs jsonb; ravg numeric; rcnt int; via text := 'name';
begin
  if length(q) < 3 or length(q) > 60 then return jsonb_build_object('results', out, 'error', 'short'); end if;
  if length(qn) between 5 and 10 and qn ~ '[0-9]' then
    select array_agg(distinct v.data ->> 'driverId') into ids from public.docs v
      where v.coll = 'vehicles' and not v.deleted and regexp_replace(upper(coalesce(v.data ->> 'plate','')), '[^A-Z0-9]', '', 'g') = qn;
    if ids is not null and array_length(ids,1) > 0 then via := 'plate'; end if;
  end if;
  if via = 'name' then
    words := array(select w from regexp_split_to_table(regexp_replace(q, '[^a-z\s''-]', ' ', 'g'), '\s+') w where length(w) >= 2);
    if coalesce(array_length(words,1),0) < 2 then return jsonb_build_object('results', out, 'error', 'fullname'); end if;
    select array_agg(u.id) into ids from (
      select u.id from public.docs u where u.coll = 'users' and not u.deleted and u.data ->> 'role' = 'driver'
        and not exists (select 1 from unnest(words) w where not (' ' || lower(coalesce(u.data ->> 'name','')) || ' ') like '% ' || w || ' %')
      limit 5) u;
  end if;
  for d in select u.id, u.data from public.docs u where u.coll = 'users' and not u.deleted and u.id = any(coalesce(ids,'{}'))
           and u.data ->> 'role' = 'driver' and coalesce(u.data ->> 'publicCheck','true') <> 'false' and not coalesce(u.data ->> 'anonymised','false') = 'true' loop
    dv := coalesce(d.data -> 'docValid', '{}'::jsonb);
    pol := case when coalesce(dv #>> '{police,issued}', d.data ->> 'policeDate', '') ~ '^\d{4}-\d{2}-\d{2}'
                then to_char((left(coalesce(dv #>> '{police,issued}', d.data ->> 'policeDate'),10)::date + interval '12 months')::date, 'YYYY-MM-DD') end;
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('vehicle', left(concat_ws(' ', v.data ->> 'color', v.data ->> 'make', v.data ->> 'model'),80),
        'plateMatch', case when via = 'plate' and regexp_replace(upper(coalesce(v.data ->> 'plate','')), '[^A-Z0-9]', '', 'g') = qn then true end,
        'disc', public._doc_until(coalesce(v.data -> 'docValid','{}'::jsonb), 'disc'), 'roadworthy', public._doc_until(coalesce(v.data -> 'docValid','{}'::jsonb), 'rwc')))), '[]'::jsonb)
      into vs from public.docs v where v.coll = 'vehicles' and not v.deleted and v.data ->> 'driverId' = d.id;
    select round(avg((data ->> 'stars')::numeric),1), count(*)::int into ravg, rcnt from public.docs
      where coll = 'ratings' and not deleted and data ->> 'driverId' = d.id and coalesce(data ->> 'stars','') ~ '^[0-5](\.\d+)?$';
    out := out || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'name', left(trim(split_part(trim(d.data ->> 'name'),' ',1) || ' ' || left(split_part(trim(d.data ->> 'name'),' ',array_length(regexp_split_to_array(trim(d.data ->> 'name'),'\s+'),1)),1) || '.'),50),
      'status', case when coalesce(d.data ->> 'banned','false') = 'true' or coalesce(d.data ->> 'suspended','false') = 'true' then 'inactive'
                     when coalesce(d.data #>> '{verification,status}','none') = 'approved' then 'verified' else 'pending' end,
      'since', case when coalesce(d.data ->> 'createdAt','') ~ '^\d{10,15}$' then to_char(to_timestamp((d.data ->> 'createdAt')::bigint / 1000), 'YYYY-MM') end,
      'licence', public._doc_until(dv,'licence'), 'prdp', coalesce(public._doc_until(dv,'prdp'), case when coalesce(d.data ->> 'prdpExpiry','') ~ '^\d{4}-\d{2}-\d{2}' then left(d.data ->> 'prdpExpiry',10) end),
      'police', pol, 'insurance', public._doc_until(dv,'insurance'), 'opLicence', public._doc_until(dv,'opLicence'),
      'rating', ravg, 'ratings', rcnt, 'vehicles', vs, 'via', via)));
  end loop;
  return jsonb_build_object('results', out, 'via', via);
end $$;
revoke execute on function public.check_driver(text) from public;
grant execute on function public.check_driver(text) to anon, authenticated;
select 'Enivel coverage, waitlist and Check a driver ready' as status;
-- an earlier draft took the number of children as int; keep only the numeric version
drop function if exists public.school_waitlist_join(text,text,text,text,int,text);

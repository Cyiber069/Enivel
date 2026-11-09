-- =====================================================================
-- 10 Nov: "how many people are on Enivel right now" for the admin (like Shopify's Live view).
-- Each open app (signed in or not) sends a tiny ping every 30 s with an anonymous device id and
-- the page it is on. Nothing else is stored, and rows older than 2 days are deleted.
-- Only the admin can read the counts.
-- =====================================================================
create table if not exists public.presence (
  sid text primary key, uid uuid, role text not null default 'visitor', page text, device text,
  first_seen timestamptz not null default now(), last_seen timestamptz not null default now());
create index if not exists presence_last_seen on public.presence (last_seen);
alter table public.presence enable row level security;
revoke all on public.presence from anon, authenticated;

create or replace function public.presence_ping(p_sid text, p_page text, p_device text) returns void
language plpgsql security definer set search_path = public as $$
declare r text := 'visitor';
begin
  if p_sid is null or length(p_sid) < 8 or length(p_sid) > 64 or p_sid !~ '^[A-Za-z0-9_-]+$' then return; end if;
  if auth.uid() is not null then
    if public.is_admin() then r := 'admin';
    else select coalesce(data ->> 'role', 'user') into r from public.docs where coll = 'users' and id = auth.uid()::text and not deleted;
         r := coalesce(r, 'user'); end if;
  end if;
  if r not in ('visitor','parent','driver','kid','admin','user') then r := 'user'; end if;
  -- safety cap so a flood of fake ids can't grow the table without limit
  if not exists (select 1 from public.presence where sid = p_sid)
     and (select count(*) from public.presence where last_seen > now() - interval '10 minutes') > 50000 then return; end if;
  insert into public.presence (sid, uid, role, page, device) values (p_sid, auth.uid(), r, left(coalesce(p_page,''), 40), left(coalesce(p_device,''), 12))
  on conflict (sid) do update set uid = excluded.uid, role = excluded.role, page = excluded.page, device = excluded.device, last_seen = now();
  if random() < 0.02 then delete from public.presence where last_seen < now() - interval '2 days'; end if;
end $$;
revoke execute on function public.presence_ping(text, text, text) from public;
grant execute on function public.presence_ping(text, text, text) to anon, authenticated;

create or replace function public.presence_live() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare day0 timestamptz := date_trunc('day', now() at time zone 'Africa/Johannesburg') at time zone 'Africa/Johannesburg';
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'now', (select count(*) from public.presence where last_seen > now() - interval '90 seconds' and role <> 'admin'),
    'byRole', coalesce((select jsonb_object_agg(role, n) from (select role, count(*) n from public.presence
                 where last_seen > now() - interval '90 seconds' and role <> 'admin' group by role) x), '{}'::jsonb),
    'pages', coalesce((select jsonb_agg(jsonb_build_object('page', page, 'n', n) order by n desc) from (select page, count(*) n from public.presence
                 where last_seen > now() - interval '90 seconds' and role <> 'admin' group by page order by count(*) desc limit 8) p), '[]'::jsonb),
    'devices', coalesce((select jsonb_object_agg(device, n) from (select coalesce(nullif(device,''),'other') device, count(*) n from public.presence
                 where last_seen > now() - interval '90 seconds' and role <> 'admin' group by 1) d), '{}'::jsonb),
    'today', (select count(*) from public.presence where last_seen >= day0 and role <> 'admin'),
    'todaySignedIn', (select count(distinct uid) from public.presence where last_seen >= day0 and role <> 'admin' and uid is not null),
    'admins', (select count(*) from public.presence where last_seen > now() - interval '90 seconds' and role = 'admin'),
    'at', (extract(epoch from now()) * 1000)::bigint);
end $$;
revoke execute on function public.presence_live() from public, anon;
grant execute on function public.presence_live() to authenticated;
select 'Enivel live visitors ready' as status;

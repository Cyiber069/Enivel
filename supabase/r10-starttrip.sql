-- =====================================================================
-- 09 Nov: start-trip reminders. Same pop-ups as before, now worded "start your trip",
-- plus a third one at pickup time if the trip still hasn't started.
-- =====================================================================
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
        title := case when coalesce((it ->> 'mins')::int, 0) <= 0 then 'Pickup time · trip not started' else 'Pickup in ' || (it ->> 'mins') || ' min · start your trip' end;
        body := array_to_string(names, ', ') || ' · ' || coalesce(it ->> 'label', 'Pickup') || ' at ' || coalesce(it ->> 'time', '') || '. Tap Start trip so parents can follow you.';
        tag := it ->> 'key'; url := coalesce(it ->> 'routeId', '');
        return next;
      end loop;
    end loop;
  end loop;
end $$;

revoke execute on function public.due_push() from public, anon, authenticated;
grant execute on function public.due_push() to service_role;
select 'Enivel start-trip reminders ready' as status;

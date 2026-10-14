-- Menu na dziś, poprawki po uwagach Michała 14.10:
-- 1) „Ustalone z góry”: Michał mówi Claude „jutro rano jajecznica, obiad udka z ryżem” → menu_ustal zapisuje ten posiłek
--    jako już wybrany (jedna opcja, src 'ustalone', ustalone = true). Automat o 5:00 dokłada opcje tylko do reszty.
-- 2) „Jadłem coś innego” przez Claude: menu_zjedzone wpisuje posiłek do meals i zamyka posiłek w menu (eaten, inne).
-- 3) menu_save: ustalony posiłek nie blokuje ułożenia dnia i nie jest nadpisywany (dostaje tylko godzinę z automatu).
-- Wszystkie trzy jako SECURITY DEFINER dla właściciela (coach_owner), wołane przez select – konektor nie pyta wtedy o zgodę.

create or replace function public.menu_save(p_date date, p_slots jsonb, p_stale jsonb, p_kupic jsonb default '[]', p_note text default '')
returns text language plpgsql security definer set search_path = public as $$
declare u uuid := public.coach_owner(); s jsonb; merged jsonb := p_slots;
begin
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then
    return 'błąd: puste slots';
  end if;
  select slots into s from public.menu where user_id = u and date = p_date;
  -- Michał coś zjadł albo sam wybrał (nie ustalone z góry) → dnia nie ruszamy.
  if s is not null and exists (
    select 1 from jsonb_array_elements(s) e
    where coalesce((e->>'eaten')::boolean, false)
       or (jsonb_typeof(e->'chosen') = 'number' and not coalesce((e->>'ustalone')::boolean, false))) then
    return 'pominięto ' || p_date || ' – Michał już wybrał';
  end if;
  if s is not null then
    -- Ustalony posiłek zostaje (z godziną z automatu); ustalone spoza nowej listy dochodzą na koniec.
    select coalesce(jsonb_agg(coalesce(
             (select e || jsonb_build_object('time', coalesce(n->'time', e->'time')) from jsonb_array_elements(s) e
               where e->>'slot' = n->>'slot' and coalesce((e->>'ustalone')::boolean, false) limit 1), n) order by ord), '[]')
      into merged from jsonb_array_elements(p_slots) with ordinality t(n, ord);
    merged := merged || coalesce((select jsonb_agg(e) from jsonb_array_elements(s) e
      where coalesce((e->>'ustalone')::boolean, false)
        and not exists (select 1 from jsonb_array_elements(p_slots) n where n->>'slot' = e->>'slot')), '[]');
  end if;
  insert into public.menu (user_id, date, slots, stale, kupic, note)
  values (u, p_date, merged, coalesce(p_stale, '[]'), coalesce(p_kupic, '[]'), coalesce(p_note, ''))
  on conflict (user_id, date) do update
    set slots = excluded.slots, stale = excluded.stale, kupic = excluded.kupic, note = excluded.note, updated_at = now();
  return 'ok menu ' || p_date;
end $$;

-- Ustal posiłek z góry: slot 'sniadanie' | 'obiad' | 'kolacja'. Nadpisuje wcześniejsze opcje tego posiłku, chyba że już zjedzony.
create or replace function public.menu_ustal(p_date date, p_slot text, p_name text, p_kcal int, p_protein int, p_detail text default '', p_time text default null)
returns text language plpgsql security definer set search_path = public as $$
declare u uuid := public.coach_owner(); s jsonb; old jsonb; ns jsonb;
begin
  if p_slot not in ('sniadanie', 'obiad', 'kolacja') then return 'błąd: slot musi być sniadanie, obiad albo kolacja'; end if;
  if coalesce(trim(p_name), '') = '' then return 'błąd: pusta nazwa'; end if;
  select slots into s from public.menu where user_id = u and date = p_date for update;
  select e into old from jsonb_array_elements(coalesce(s, '[]')) e where e->>'slot' = p_slot limit 1;
  if coalesce((old->>'eaten')::boolean, false) then return 'pominięto: ' || p_slot || ' ' || p_date || ' już zjedzone'; end if;
  ns := jsonb_build_object('slot', p_slot,
    'label', case p_slot when 'sniadanie' then 'Śniadanie' when 'obiad' then 'Obiad' else 'Kolacja' end,
    'time', coalesce(p_time, old->>'time', case p_slot when 'sniadanie' then '9:30' when 'obiad' then '14:00' else '19:30' end),
    'options', jsonb_build_array(jsonb_build_object('name', trim(p_name), 'detail', coalesce(p_detail, ''), 'kcal', p_kcal, 'protein', p_protein, 'src', 'ustalone')),
    'chosen', 0, 'eaten', false, 'ustalone', true);
  if s is null then
    insert into public.menu (user_id, date, slots) values (u, p_date, jsonb_build_array(ns))
    on conflict (user_id, date) do update set slots = excluded.slots, updated_at = now();
  else
    -- podmiana albo dopisanie; kolejność: śniadanie, obiad, kolacja
    select jsonb_agg(x order by array_position(array['sniadanie', 'obiad', 'kolacja'], x->>'slot'))
      into s from (select e as x from jsonb_array_elements(s) e where e->>'slot' <> p_slot union all select ns) t;
    update public.menu set slots = s, updated_at = now() where user_id = u and date = p_date;
  end if;
  return 'ok ustalone ' || p_slot || ' ' || p_date || ': ' || trim(p_name);
end $$;

-- „Jadłem coś innego” (przez Claude): wpis do meals + posiłek w menu zamknięty (eaten, inne, meal_id). Bez menu – sam wpis do meals.
create or replace function public.menu_zjedzone(p_date date, p_slot text, p_name text, p_kcal int, p_protein int)
returns text language plpgsql security definer set search_path = public as $$
declare u uuid := public.coach_owner(); s jsonb; old jsonb; mid uuid;
  tm text := case when p_date = (now() at time zone 'Europe/Warsaw')::date then to_char(now() at time zone 'Europe/Warsaw', 'HH24:MI') end;
begin
  if coalesce(trim(p_name), '') = '' then return 'błąd: pusta nazwa'; end if;
  select slots into s from public.menu where user_id = u and date = p_date for update;
  select e into old from jsonb_array_elements(coalesce(s, '[]')) e where e->>'slot' = p_slot limit 1;
  if coalesce((old->>'eaten')::boolean, false) then return 'pominięto: ' || p_slot || ' ' || p_date || ' już zjedzone – nic nie zapisano'; end if;
  insert into public.meals (user_id, date, time, name, kcal, protein) values (u, p_date, tm, trim(p_name), p_kcal, p_protein) returning id into mid;
  if old is null then return 'ok posiłek zapisany (w menu nie ma posiłku ' || coalesce(p_slot, '–') || ')'; end if;
  select jsonb_agg(case when e->>'slot' = p_slot
           then e || jsonb_build_object('eaten', true, 'meal_id', mid, 'inne', jsonb_build_object('name', trim(p_name), 'kcal', p_kcal, 'protein', p_protein))
           else e end order by ord)
    into s from jsonb_array_elements(s) with ordinality t(e, ord);
  update public.menu set slots = s, updated_at = now() where user_id = u and date = p_date;
  return 'ok ' || p_slot || ' ' || p_date || ': ' || trim(p_name);
end $$;

revoke all on function public.menu_save(date, jsonb, jsonb, jsonb, text) from public, anon, authenticated;
revoke all on function public.menu_ustal(date, text, text, int, int, text, text) from public, anon, authenticated;
revoke all on function public.menu_zjedzone(date, text, text, int, int) from public, anon, authenticated;

-- Kuźnia B3, poprawka Michała (14.10.2026): o 21:30 już śpi, więc „seria zagrożona” przychodzi w ciągu dnia.
--  seria   (domyślnie 15:00) – „seria zagrożona”, tylko gdy dzień jeszcze niezaliczony (zero zrobionych aktywnych zadań);
--  zostalo (domyślnie 18:00) – co zostało z zadań dnia (jak dotąd); o tej porze też ewentualne wygaszanie.
--  21:30 – usunięte.
-- Godziny na konto w settings.kuznia_przypomnienia_godziny {"seria":"HH:MM","zostalo":"HH:MM"} (panel ☰ – czat B1).
-- pg_cron (UTC) co 15 min przez całą dobę; funkcja sama liczy czas warszawski i okno 30 min od godziny z ustawień,
-- a dziennik (kuznia_przypomnienia) pilnuje jednej wysyłki na typ i dzień.

alter table public.settings add column if not exists kuznia_przypomnienia_godziny jsonb not null
  default '{"seria":"15:00","zostalo":"18:00"}'::jsonb;

-- „HH:MM” → minuty od północy; zły format → p_dom.
create or replace function public.kuznia__minuty(p text, p_dom int) returns int language sql immutable as $$
  select case when p ~ '^\d{1,2}:\d{2}$' and split_part(p, ':', 1)::int < 24 and split_part(p, ':', 2)::int < 60
              then split_part(p, ':', 1)::int * 60 + split_part(p, ':', 2)::int else p_dom end
$$;

-- Treść przypomnienia: {"tytul","tresc"} albo null, gdy nie ma czego przypominać. Typy: 'zostalo', 'seria', 'wygaszenie'.
drop function if exists public.kuznia__przypomnienie(uuid, text, timestamptz);
create function public.kuznia__przypomnienie(p_user uuid, p_typ text, p_teraz timestamptz)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  dzis date := (p_teraz at time zone 'Europe/Warsaw')::date;
  d jsonb; z jsonb; lista text[] := '{}'; poz text; n int; i int;
  h text := kuznia__do_polnocy(p_teraz);
  seria int; dni text; t text[]; b text[];
begin
  if p_typ = 'wygaszenie' then
    return jsonb_build_object('tytul', '[ KUŹNIA ] Kuźnia wygasza ogień', 'tresc', 'Wróć, kiedy będziesz gotów.');
  end if;

  d := kuznia__dzien(dzis, p_user, true);
  i := (dzis - date '2026-01-01');   -- rotacja tekstów: inny wariant każdego dnia

  if p_typ = 'zostalo' then
    for z in select * from jsonb_array_elements(d->'zadania') loop
      continue when not (z->>'aktywne')::boolean or (z->>'zrobione')::boolean;
      poz := split_part(z->>'nazwa', ' – ', 1);
      if z->>'jedn' = 'h' then
        poz := poz || ' ' || kuznia__hm((z->>'postep')::numeric) || ' / ' || kuznia__hm((z->>'cel')::numeric);
      elsif z->>'zrodlo' = 'kalorie' then
        poz := poz || ' ' || (z->>'kcal') || ' / ' || (z->>'kcal_cel') || ' kcal';
      elsif z->>'zrodlo' = 'sen' then
        poz := 'Sen ' || replace(round((z->>'postep')::numeric, 1)::text, '.', ',') || ' / ' || (z->>'cel') || ' h';
      elsif z->>'zrodlo' = 'plan' then
        poz := poz || ' ' || (z->>'postep') || ' / ' || (z->>'cel');
      end if;
      lista := lista || poz;
    end loop;
    n := coalesce(array_length(lista, 1), 0);
    if n = 0 then return null; end if;   -- wszystko zrobione (albo nic aktywnego)
    poz := array_to_string(lista[1:4], ', ') || case when n > 4 then ' (+' || (n - 4) || ')' else '' end;
    t := array['Ogień jeszcze się pali', 'Żar czeka na Kowala', 'Stal jeszcze miękka', 'Młot leży bezczynnie', 'Wieczór w kuźni'];
    b := array[
      poz || '. Do północy ' || h || '.',
      'Na kowadle leży: ' || poz || '. Zostało ' || h || '.',
      poz || '. ' || h || ' do północy – ostatnie uderzenia decydują.',
      'Niedokute: ' || poz || '. Wygoda kusi, a ogień nie będzie czekał wiecznie.',
      'Do zrobienia: ' || poz || '. Masz ' || h || '. Kowal nie odkłada młota w połowie.'];
    return jsonb_build_object('tytul', '[ KUŹNIA ] ' || t[1 + i % 5], 'tresc', b[1 + i % 5]);
  end if;

  if p_typ = 'seria' then
    if (d->>'zaliczony')::boolean then return null; end if;
    select coalesce(st.seria, 0) into seria from kuznia_stan st where st.user_id = p_user;
    seria := coalesce(seria, 0);
    dni := case when seria = 1 then 'dnia' else 'dni' end;
    if seria > 0 then
      t := array['Seria ' || seria || ' ' || dni || ' stygnie', 'Ogień przygasa', 'Kowal wybrał wygodę?', 'Stal pęka'];
      b := array[
        'Jedno zadanie i stal zostaje twarda.',
        'Seria ' || seria || ' ' || dni || ' wisi na jednym uderzeniu. Dziś jeszcze zero.',
        'Dziś jeszcze nic na kowadle, a seria ' || seria || ' ' || dni || ' stygnie. Jedno zadanie wystarczy.',
        'Seria ' || seria || ' ' || dni || ' w ogniu – a dziś zero. Wróć do kuźni, zanim ostygnie.'];
    else
      t := array['Kuźnia dziś zimna', 'Kowadło puste', 'Zimny piec', 'Kowal wybrał wygodę?'];
      b := array[
        'Jedno zadanie rozpala serię. Dzień ma jeszcze ' || h || '.',
        'Dziś jeszcze ani jednego uderzenia. Jedno zadanie i ogień wraca.',
        'Seria zaczyna się od jednego dnia. Ten dzień ma jeszcze ' || h || '.',
        'Ogień czeka. Jedno zadanie i stal znów się hartuje.'];
    end if;
    return jsonb_build_object('tytul', '[ KUŹNIA ] ' || t[1 + i % 4], 'tresc', b[1 + i % 4]);
  end if;

  raise exception 'nieznany typ przypomnienia: %', p_typ;
end $$;
revoke all on function public.kuznia__przypomnienie(uuid, text, timestamptz) from public, anon, authenticated;

-- Tyknięcie przypomnień (pg_cron co 15 min). p_teraz i p_user – tylko do testów (w transakcji z rollback).
create or replace function public.kuznia_przypomnienia_tick(p_teraz timestamptz default now(), p_user uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  lok timestamp := p_teraz at time zone 'Europe/Warsaw';
  dzis date := lok::date;
  v_min int := extract(hour from lok)::int * 60 + extract(minute from lok)::int;
  v_typ text; u record; akt timestamptz; p jsonb; wyn jsonb := '[]'::jsonb; m_seria int; m_zost int;
begin
  for u in select distinct ps.user_id, s.kuznia_przypomnienia_godziny g from push_subscriptions ps
           left join settings s on s.user_id = ps.user_id
           where coalesce(s.kuznia_przypomnienia, true) and (p_user is null or ps.user_id = p_user) loop
    m_seria := kuznia__minuty(u.g->>'seria', 15 * 60);
    m_zost  := kuznia__minuty(u.g->>'zostalo', 18 * 60);
    v_typ := case when v_min >= m_zost and v_min < m_zost + 30 then 'zostalo'
                  when v_min >= m_seria and v_min < m_seria + 30 then 'seria' end;
    continue when v_typ is null;

    akt := kuznia__aktywnosc(u.user_id);
    if akt is null or akt < p_teraz - interval '5 days' then
      -- wygaszanie: jeden komunikat po ostatniej aktywności (o godzinie „zostalo”), potem cisza
      continue when v_typ <> 'zostalo' or exists (select 1 from kuznia_przypomnienia k where k.user_id = u.user_id
                     and k.typ = 'wygaszenie' and k.wyslano_at > coalesce(akt, '-infinity'));
      v_typ := 'wygaszenie';
      p := kuznia__przypomnienie(u.user_id, v_typ, p_teraz);
    else
      p := kuznia__przypomnienie(u.user_id, v_typ, p_teraz);
      continue when p is null;
    end if;

    insert into kuznia_przypomnienia (user_id, date, typ, tytul, tresc, wyslano_at)
      values (u.user_id, dzis, v_typ, p->>'tytul', p->>'tresc', p_teraz) on conflict do nothing;
    if found then
      update kuznia_przypomnienia
         set request_id = push_send_tag(u.user_id, p->>'tytul', p->>'tresc', 'kuznia', case when v_typ = 'wygaszenie' then 21600 else 7200 end)
       where user_id = u.user_id and date = dzis and typ = v_typ;
      wyn := wyn || jsonb_build_object('user', u.user_id, 'typ', v_typ);
    end if;
  end loop;
  return jsonb_build_object('lokalnie', lok, 'wyslane', wyn);
end $$;
revoke all on function public.kuznia_przypomnienia_tick(timestamptz, uuid) from public, anon, authenticated;

-- Harmonogram: co 15 min (godziny są w ustawieniach konta, czas letni/zimowy liczy funkcja).
select cron.unschedule('kuznia-przypomnienia');
select cron.schedule('kuznia-przypomnienia', '*/15 * * * *', $$select public.kuznia_przypomnienia_tick()$$);

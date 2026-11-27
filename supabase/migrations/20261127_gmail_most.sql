-- Most Gmail dla automatów (tor B, 27.11.2026).
-- Apps Script w koncie frycz.wideo@gmail.com co minutę woła edge function `gmail-most`,
-- a ta (service_role) woła funkcje poniżej. Tablice automaty_* należą do toru A –
-- tu tylko z nich korzystamy (plpgsql sprawdza je dopiero przy wykonaniu).
-- Projekt: docs/superpowers/specs/2026-11-27-automaty-design.md (repo CEO), sekcja „Most Gmail”.

-- 1) Stan mostu: jeden wiersz (ostatni kontakt, przypięty klient OAuth skryptu, tryb próbny wysyłki).
create table if not exists public.gmail_most_stan (
  id                   int primary key default 1 check (id = 1),
  ostatni_kontakt      timestamptz,
  ostatnie_nowe        int,
  aud                  text,      -- client id skryptu Apps Script; przypinany przy pierwszym wywołaniu
  wysylka_dozwolona_do text[] default array['mfryczu@gmail.com'],  -- null = bez ograniczeń
  alarm_wyslany        timestamptz,
  ostatni_blad         text,
  zaktualizowano       timestamptz default now()
);
alter table public.gmail_most_stan enable row level security;  -- bez polityk: tylko service_role
insert into public.gmail_most_stan (id) values (1) on conflict (id) do nothing;

-- 2) Nowe maile → zdarzenia mail_przyszedl (bez duplikatów po gmail_id). Zwraca liczbę nowych.
create or replace function public.gmail_most_maile(p_maile jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare
  m jsonb; n int := 0; v_od text;
begin
  for m in select value from jsonb_array_elements(coalesce(p_maile, '[]'::jsonb)) loop
    continue when coalesce(m->>'gmail_id', '') = '';
    perform pg_advisory_xact_lock(hashtext('gmail_most:' || (m->>'gmail_id')));
    continue when exists (select 1 from automaty_zdarzenia
                           where typ = 'mail_przyszedl' and dane->>'gmail_id' = m->>'gmail_id');
    v_od := lower(coalesce(m->>'od', ''));
    insert into automaty_zdarzenia (typ, zrodlo, dane) values ('mail_przyszedl', 'gmail', jsonb_build_object(
      'gmail_id',  m->>'gmail_id',
      'watek_id',  m->>'watek_id',
      'od',        v_od,
      'od_nazwa',  m->>'od_nazwa',
      'od_domena', nullif(split_part(v_od, '@', 2), ''),
      'do',        m->>'do',
      'temat',     m->>'temat',
      'tresc',     left(coalesce(m->>'tresc', ''), 20000),
      'data',      m->>'data',
      'etykiety',  coalesce(m->'etykiety', '[]'::jsonb)));
    n := n + 1;
  end loop;
  update gmail_most_stan set ostatni_kontakt = now(), ostatnie_nowe = n, alarm_wyslany = null,
         zaktualizowano = now() where id = 1;
  return n;
end $$;

-- 3) Akcje do wykonania: bierze 'czeka' → 'w_toku' (atomowo) i oddaje mostowi.
--    Wysyłka poza listą dozwolonych adresów (tryb próbny) od razu kończy się błędem, nie trafia do Gmaila.
--    Zawieszone 'w_toku': archiwizacja wraca do kolejki po 15 min; wysyłka po 60 min dostaje błąd
--    (nie ponawiamy – lepiej brak maila niż dwa).
create or replace function public.gmail_most_akcje(p_limit int default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a record; v_dozw text[]; v_out jsonb := '[]'::jsonb;
begin
  for a in select id from automaty_akcje
            where typ = 'gmail_archiwizuj' and stan = 'w_toku'
              and (wynik->>'most_pobral')::timestamptz < now() - interval '15 minutes'
            for update skip locked loop
    update automaty_akcje set stan = 'czeka' where id = a.id;
  end loop;
  for a in select id from automaty_akcje
            where typ = 'gmail_wyslij' and stan = 'w_toku'
              and (wynik->>'most_pobral')::timestamptz < now() - interval '60 minutes'
            for update skip locked loop
    perform automaty_akcja_wynik(a.id, false, jsonb_build_object(
      'blad', 'Most nie potwierdził wysyłki w 60 min – sprawdź „Wysłane” w Gmailu frycz.wideo; nie ponawiam.'));
  end loop;

  select wysylka_dozwolona_do into v_dozw from gmail_most_stan where id = 1;

  for a in select id, typ, dane from automaty_akcje
            where stan = 'czeka' and typ in ('gmail_wyslij', 'gmail_archiwizuj')
            order by id limit greatest(1, least(p_limit, 50))
            for update skip locked loop
    if a.typ = 'gmail_wyslij' and v_dozw is not null
       and not (lower(trim(coalesce(a.dane->>'do', ''))) = any (v_dozw)) then
      update automaty_akcje set stan = 'w_toku' where id = a.id;
      perform automaty_akcja_wynik(a.id, false, jsonb_build_object(
        'blad', 'Most w trybie próbnym: wysyłka tylko do ' || array_to_string(v_dozw, ', ')
                || '. Wyłączenie: update gmail_most_stan set wysylka_dozwolona_do = null.'));
      continue;
    end if;
    update automaty_akcje
       set stan = 'w_toku', wynik = coalesce(wynik, '{}'::jsonb) || jsonb_build_object('most_pobral', now())
     where id = a.id;
    v_out := v_out || jsonb_build_object('id', a.id, 'typ', a.typ, 'dane', a.dane);
  end loop;
  return v_out;
end $$;

-- 4) Wynik akcji z mostu. Liczy się tylko dla akcji 'w_toku' (spóźniony wynik nie nadpisuje).
--    Po udanej wysyłce z wiadomosc_id: automaty_wiadomosc_wyslana (funkcja toru A).
create or replace function public.gmail_most_wynik(p_akcja_id bigint, p_ok boolean, p_wynik jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select id, typ, dane, stan into a from automaty_akcje where id = p_akcja_id for update;
  if not found or a.stan <> 'w_toku' then return false; end if;
  perform automaty_akcja_wynik(p_akcja_id, p_ok, coalesce(p_wynik, '{}'::jsonb));
  if p_ok and a.typ = 'gmail_wyslij' and coalesce(a.dane->>'wiadomosc_id', '') <> '' then
    perform automaty_wiadomosc_wyslana((a.dane->>'wiadomosc_id')::bigint);
  end if;
  return true;
end $$;

-- 5) Przypięcie klienta OAuth skryptu (pierwsze wywołanie) i zapis błędu.
create or replace function public.gmail_most_aud(p_aud text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v text;
begin
  update gmail_most_stan set aud = coalesce(aud, p_aud) where id = 1 returning aud into v;
  return v = p_aud;
end $$;

create or replace function public.gmail_most_blad(p_blad text)
returns void language sql security definer set search_path = public as $$
  update gmail_most_stan set ostatni_blad = left(p_blad, 2000), zaktualizowano = now() where id = 1;
$$;

-- 6) Strażnik: most milczy > 30 min → jeden push do Michała (do następnego kontaktu).
create or replace function public.gmail_most_straznik()
returns void language plpgsql security definer set search_path = public as $$
declare s record; v_user uuid;
begin
  select * into s from gmail_most_stan where id = 1;
  if s.ostatni_kontakt is null or s.ostatni_kontakt > now() - interval '30 minutes'
     or s.alarm_wyslany is not null then return; end if;
  select id into v_user from auth.users where email = 'mfryczu@gmail.com';
  perform push_send(v_user, 'Most Gmail stoi',
    'Automaty nie widzą maili frycz.wideo od ' || to_char(s.ostatni_kontakt at time zone 'Europe/Warsaw', 'HH24:MI')
    || '. Otwórz script.google.com (konto frycz.wideo) → projekt „Most automatów” → Wykonania.');
  update gmail_most_stan set alarm_wyslany = now() where id = 1;
end $$;

revoke all on function public.gmail_most_maile(jsonb), public.gmail_most_akcje(int),
  public.gmail_most_wynik(bigint, boolean, jsonb), public.gmail_most_aud(text),
  public.gmail_most_blad(text), public.gmail_most_straznik() from public, anon, authenticated;
grant execute on function public.gmail_most_maile(jsonb), public.gmail_most_akcje(int),
  public.gmail_most_wynik(bigint, boolean, jsonb), public.gmail_most_aud(text),
  public.gmail_most_blad(text) to service_role;

select cron.unschedule('gmail-most-straznik') where exists (select 1 from cron.job where jobname = 'gmail-most-straznik');
select cron.schedule('gmail-most-straznik', '*/10 * * * *', 'select public.gmail_most_straznik()');

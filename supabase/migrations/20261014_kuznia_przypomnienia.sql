-- Kuźnia B3 (14.10.2026): przypomnienia na telefon w głosie Kuźni.
-- Plan: docs/superpowers/plans/2026-10-14-kuznia.md (Task B3), spec: docs/superpowers/specs/2026-10-14-kuznia-design.md (repo CEO).
--  18:00 (Europe/Warsaw) – co zostało z aktywnych zadań dnia; nic, gdy wszystko zrobione.
--  21:30 – „seria zagrożona”, tylko gdy dzień jeszcze niezaliczony.
--  Po 5 dniach bez otwarcia apki – jeden komunikat „Kuźnia wygasza ogień” i cisza, aż Kowal wróci.
-- Sygnał „otworzył apkę”: odświeżenie sesji logowania (auth.sessions – apka odświeża token tylko, gdy jest otwarta)
-- albo start stopera (praca). Wpisy rutyn i Claude (rola serwisowa) się nie liczą – nie dotykają sesji.
-- Wysyłka przez push-wyslij z tagiem 'kuznia' (nie zastępuje alarmu stopera, który ma tag 'praca').
-- pg_cron działa w UTC: zadanie co 30 min w godz. 16–20 UTC, a funkcja sama sprawdza czas warszawski
-- (lato: 18:00 = 16:00 UTC, 21:30 = 19:30 UTC; zima od 25.10: 17:00 i 20:30 UTC). Dziennik chroni przed podwójną wysyłką.

-- Wyłącznik na konto (domyślnie włączone).
alter table public.settings add column if not exists kuznia_przypomnienia boolean not null default true;

-- Dziennik wysłanych przypomnień: jeden wiersz na konto, dzień i typ ('18', '2130', 'wygaszenie', 'test').
create table if not exists public.kuznia_przypomnienia (
  user_id uuid not null references auth.users(id) on delete cascade,
  date date not null,
  typ text not null,
  tytul text not null,
  tresc text not null,
  request_id bigint,                       -- id żądania pg_net (odpowiedź: net._http_response)
  wyslano_at timestamptz not null default now(),
  primary key (user_id, date, typ)
);
alter table public.kuznia_przypomnienia enable row level security;
create policy wlasne_odczyt on public.kuznia_przypomnienia for select to authenticated using (user_id = (select auth.uid()));

-- Wysyłka z tagiem i czasem życia (push_send z 3 argumentami zostaje bez zmian – używa go praca_tick).
create or replace function public.push_send_tag(p_user uuid, p_title text, p_body text, p_tag text, p_ttl int)
returns bigint language plpgsql security definer set search_path = '' as $$
begin
  return net.http_post(
    url := 'https://ywoqfvlnteejtzhqdpdd.supabase.co/functions/v1/push-wyslij',
    body := jsonb_build_object('user_id', p_user, 'title', p_title, 'body', p_body, 'tag', p_tag, 'ttl', p_ttl),
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-push-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_secret')),
    timeout_milliseconds := 15000);
end $$;
revoke all on function public.push_send_tag(uuid, text, text, text, int) from public, anon, authenticated;

-- Ostatnie otwarcie apki (patrz nagłówek).
create or replace function public.kuznia__aktywnosc(p_user uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select greatest(
    (select max(greatest(s.created_at, s.updated_at, s.refreshed_at)) from auth.sessions s where s.user_id = p_user),
    (select max(started_at) from public.praca where user_id = p_user),
    (select created_at from public.push_subscriptions where user_id = p_user order by created_at desc limit 1))
$$;

-- Godziny → „2:10”.
create or replace function public.kuznia__hm(h numeric) returns text language sql immutable as $$
  select (m / 60) || ':' || lpad((m % 60)::text, 2, '0') from (select round(coalesce(h, 0) * 60)::int as m) x
$$;

-- Czas do północy → „6 h” / „2 h 30 min”.
create or replace function public.kuznia__do_polnocy(p_teraz timestamptz) returns text language sql stable as $$
  with m as (select greatest(0, floor(extract(epoch from
      (((p_teraz at time zone 'Europe/Warsaw')::date + 1)::timestamp - (p_teraz at time zone 'Europe/Warsaw'))) / 60))::int as min)
  select case when min % 60 = 0 then (min / 60) || ' h' else (min / 60) || ' h ' || (min % 60) || ' min' end from m
$$;

-- Treść przypomnienia: {"tytul","tresc"} albo null, gdy nie ma czego przypominać.
create or replace function public.kuznia__przypomnienie(p_user uuid, p_typ text, p_teraz timestamptz)
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

  if p_typ = '18' then
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

  if p_typ = '2130' then
    if (d->>'zaliczony')::boolean then return null; end if;
    select coalesce(st.seria, 0) into seria from kuznia_stan st where st.user_id = p_user;
    seria := coalesce(seria, 0);
    dni := case when seria = 1 then 'dnia' else 'dni' end;
    if seria > 0 then
      t := array['Seria ' || seria || ' ' || dni || ' stygnie', 'Ogień gaśnie', 'Kowal wybrał wygodę?', 'Stal pęka'];
      b := array[
        'Jedno zadanie i stal zostaje twarda.',
        'Seria ' || seria || ' ' || dni || ' wisi na jednym uderzeniu. Do północy ' || h || '.',
        'Dziś jeszcze nic na kowadle, a seria ' || seria || ' ' || dni || ' stygnie. Jedno zadanie wystarczy.',
        'Seria ' || seria || ' ' || dni || ' w ogniu – a dziś zero. Wróć do kuźni przed północą.'];
    else
      t := array['Kuźnia dziś zimna', 'Kowadło puste', 'Zimny piec', 'Kowal wybrał wygodę?'];
      b := array[
        'Jedno zadanie rozpala serię. Do północy ' || h || '.',
        'Dziś jeszcze ani jednego uderzenia. Jedno zadanie i ogień wraca.',
        'Seria zaczyna się od jednego dnia. Ten dzień ma jeszcze ' || h || '.',
        'Ogień czeka. Jedno zadanie przed północą i stal znów się hartuje.'];
    end if;
    return jsonb_build_object('tytul', '[ KUŹNIA ] ' || t[1 + i % 4], 'tresc', b[1 + i % 4]);
  end if;

  raise exception 'nieznany typ przypomnienia: %', p_typ;
end $$;

-- Tyknięcie przypomnień (pg_cron). p_teraz i p_user – tylko do testów (w transakcji z rollback).
create or replace function public.kuznia_przypomnienia_tick(p_teraz timestamptz default now(), p_user uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  lok timestamp := p_teraz at time zone 'Europe/Warsaw';
  dzis date := lok::date;
  v_min int := extract(hour from lok)::int * 60 + extract(minute from lok)::int;
  v_typ text; u record; akt timestamptz; p jsonb; wyn jsonb := '[]'::jsonb;
begin
  v_typ := case when v_min between 18 * 60 and 18 * 60 + 29 then '18'
              when v_min between 21 * 60 + 30 and 21 * 60 + 59 then '2130' end;
  if v_typ is null then return jsonb_build_object('typ', null::text, 'lokalnie', lok); end if;

  for u in select distinct ps.user_id from push_subscriptions ps
           left join settings s on s.user_id = ps.user_id
           where coalesce(s.kuznia_przypomnienia, true) and (p_user is null or ps.user_id = p_user) loop
    akt := kuznia__aktywnosc(u.user_id);
    if akt is null or akt < p_teraz - interval '5 days' then
      -- wygaszanie: jeden komunikat po ostatniej aktywności, potem cisza
      continue when v_typ <> '18' or exists (select 1 from kuznia_przypomnienia k where k.user_id = u.user_id
                     and k.typ = 'wygaszenie' and k.wyslano_at > coalesce(akt, '-infinity'));
      p := kuznia__przypomnienie(u.user_id, 'wygaszenie', p_teraz);
      insert into kuznia_przypomnienia (user_id, date, typ, tytul, tresc, wyslano_at)
        values (u.user_id, dzis, 'wygaszenie', p->>'tytul', p->>'tresc', p_teraz) on conflict do nothing;
      if found then
        update kuznia_przypomnienia set request_id = push_send_tag(u.user_id, p->>'tytul', p->>'tresc', 'kuznia', 21600)
         where user_id = u.user_id and date = dzis and typ = 'wygaszenie';
        wyn := wyn || jsonb_build_object('user', u.user_id, 'typ', 'wygaszenie');
      end if;
      continue;
    end if;

    p := kuznia__przypomnienie(u.user_id, v_typ, p_teraz);
    continue when p is null;
    insert into kuznia_przypomnienia (user_id, date, typ, tytul, tresc, wyslano_at)
      values (u.user_id, dzis, v_typ, p->>'tytul', p->>'tresc', p_teraz) on conflict do nothing;
    if found then
      update kuznia_przypomnienia set request_id = push_send_tag(u.user_id, p->>'tytul', p->>'tresc', 'kuznia', 7200)
       where user_id = u.user_id and date = dzis and typ = v_typ;
      wyn := wyn || jsonb_build_object('user', u.user_id, 'typ', v_typ);
    end if;
  end loop;
  return jsonb_build_object('typ', v_typ, 'lokalnie', lok, 'wyslane', wyn);
end $$;

revoke all on function public.kuznia__aktywnosc(uuid) from public, anon, authenticated;
revoke all on function public.kuznia__przypomnienie(uuid, text, timestamptz) from public, anon, authenticated;
revoke all on function public.kuznia_przypomnienia_tick(timestamptz, uuid) from public, anon, authenticated;

-- Harmonogram (UTC): co 30 min w 16:00–20:30 – obejmuje 18:00 i 21:30 czasu warszawskiego latem i zimą.
select cron.schedule('kuznia-przypomnienia', '0,30 16-20 * * *', $$select public.kuznia_przypomnienia_tick()$$);

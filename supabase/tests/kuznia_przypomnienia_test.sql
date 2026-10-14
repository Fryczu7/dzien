-- Testy przypomnień Kuźni (B3). Uruchamiać w całości jednym wywołaniem (execute_sql) – kończą się rollback,
-- więc nic nie zostaje w bazie, a żądania pg_net (wysyłka) nie wychodzą. Dane testowe: daty z 2030 roku, konto Michała.
-- Godziny domyślne: seria 15:00, zostalo 18:00 (settings.kuznia_przypomnienia_godziny).
-- Sukces = brak błędu. Błąd asercji podaje, który test nie przeszedł.
begin;

create function pg_temp.reset(u uuid) returns void language sql as $$
  delete from public.kuznia_przypomnienia where user_id = u;
  delete from public.kuznia_dni where user_id = u;
  update public.settings set kuznia_zadania = null, kuznia_przypomnienia = true,
    kuznia_przypomnienia_godziny = '{"seria":"15:00","zostalo":"18:00"}' where user_id = u;
  insert into public.kuznia_stan (user_id, seria) values (u, 12) on conflict (user_id) do update set seria = 12;
$$;
create function pg_temp.log(u uuid, d date, t text) returns public.kuznia_przypomnienia language sql as $$
  select * from public.kuznia_przypomnienia where user_id = u and date = d and typ = t
$$;
create function pg_temp.typ(r jsonb) returns text language sql as $$ select r->'wyslane'->0->>'typ' $$;

-- Pomocnicze formaty
do $$ begin
  assert kuznia__hm(2 + 10 / 60.0) = '2:10', 'hm: 2:10';
  assert kuznia__hm(0) = '0:00', 'hm: 0:00';
  assert kuznia__hm(2.999) = '3:00', 'hm: zaokrąglenie do 3:00';
  assert kuznia__do_polnocy('2030-01-08 18:00+01') = '6 h', 'do północy zimą: 6 h';
  assert kuznia__do_polnocy('2030-01-08 21:30+01') = '2 h 30 min', 'do północy: 2 h 30 min';
  assert kuznia__do_polnocy('2030-07-09 18:00+02') = '6 h', 'do północy latem: 6 h';
  assert kuznia__minuty('15:00', 0) = 900 and kuznia__minuty('7:05', 0) = 425, 'minuty';
  assert kuznia__minuty('25:00', 900) = 900 and kuznia__minuty(null, 900) = 900 and kuznia__minuty('abc', 1) = 1, 'minuty: zły format';
end $$;

-- 18:00 zimą (17:00 UTC): lista tego, co zostało; raz na dzień
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; l public.kuznia_przypomnienia; begin
  perform pg_temp.reset(u);
  insert into praca(user_id,date,kind,started_at,ended_at) values (u,'2030-01-08','getmed','2030-01-08 08:00+01','2030-01-08 10:10+01');
  r := kuznia_przypomnienia_tick('2030-01-08 16:00+00', u);
  assert pg_temp.typ(r) is null, '17:00 lokalnie: nic';
  r := kuznia_przypomnienia_tick('2030-01-08 17:00+00', u);
  assert pg_temp.typ(r) = 'zostalo', '18:00 zimą: wysłane ' || r::text;
  l := pg_temp.log(u, '2030-01-08', 'zostalo');
  assert l.tytul like '[ KUŹNIA ] %', '18: prefiks';
  assert l.tresc like '%GetMed 2:10 / 4:00%' and l.tresc like '%Złap Termin 0:00 / 1:00%', '18: postęp pracy: ' || l.tresc;
  assert l.tytul || l.tresc not like '%System%' and l.tytul || l.tresc not like '%Gracz%', '18: bez System/Gracz';
  r := kuznia_przypomnienia_tick('2030-01-08 17:15+00', u);
  assert pg_temp.typ(r) is null, '18: drugi raz nic';
  r := kuznia_przypomnienia_tick('2030-01-08 20:30+00', u);
  assert pg_temp.typ(r) is null, '21:30: już nic (usunięte)';
end $$;

-- 15:00 zimą (14:00 UTC): seria zagrożona, tylko gdy dzień niezaliczony
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; l public.kuznia_przypomnienia; begin
  -- 2030-01-08 ma już 2:10 GetMed, ale cel 4 h – zero zrobionych zadań → niezaliczony
  r := kuznia_przypomnienia_tick('2030-01-08 14:00+00', u);
  assert pg_temp.typ(r) = 'seria', '15:00: wysłane ' || r::text;
  l := pg_temp.log(u, '2030-01-08', 'seria');
  assert l.tytul || ' ' || l.tresc like '%12 dni%', '15:00: długość serii: ' || l.tytul || ' ' || l.tresc;
  r := kuznia_przypomnienia_tick('2030-01-08 14:15+00', u);
  assert pg_temp.typ(r) is null, '15:00: drugi raz nic';
  -- dzień zaliczony (modlitwa) → bez „seria zagrożona”
  insert into days(user_id,date,morning) values (u,'2030-01-09','{"modlitwa":true}');
  r := kuznia_przypomnienia_tick('2030-01-09 14:00+00', u);
  assert pg_temp.typ(r) is null, '15:00: zaliczony = nic';
  update kuznia_stan set seria = 1 where user_id = u;
  assert (select (p->>'tytul') || (p->>'tresc') from (select kuznia__przypomnienie(u, 'seria', '2030-01-10 14:00+00') p) x) like '%1 dnia%', 'seria 1 dnia';
  update kuznia_stan set seria = 0 where user_id = u;
  assert kuznia__przypomnienie(u, 'seria', '2030-01-10 14:00+00') is not null, 'seria 0: inny tekst, ale jest';
end $$;

-- Własne godziny z ustawień
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; begin
  update settings set kuznia_przypomnienia_godziny = '{"seria":"12:15","zostalo":"19:45"}' where user_id = u;
  r := kuznia_przypomnienia_tick('2030-01-10 14:00+00', u);
  assert pg_temp.typ(r) is null, 'własne: 15:00 już nie';
  r := kuznia_przypomnienia_tick('2030-01-10 11:30+00', u);
  assert pg_temp.typ(r) = 'seria', 'własne: seria 12:30 (okno od 12:15) ' || r::text;
  r := kuznia_przypomnienia_tick('2030-01-10 18:45+00', u);
  assert pg_temp.typ(r) = 'zostalo', 'własne: zostalo 19:45';
  update settings set kuznia_przypomnienia_godziny = '{"seria":"15:00","zostalo":"18:00"}' where user_id = u;
end $$;

-- Wszystko zrobione → bez przypomnienia o 18:00; wyłącznik w ustawieniach
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; begin
  update settings set kuznia_zadania = '[{"k":"x","nazwa":"Próba","zrodlo":"reczne","xp":10}]' where user_id = u;
  insert into kuznia_dni(user_id,date,reczne) values (u,'2030-01-11','{"x":true}');
  r := kuznia_przypomnienia_tick('2030-01-11 17:00+00', u);
  assert pg_temp.typ(r) is null, '18: wszystko zrobione = nic';
  update settings set kuznia_zadania = null, kuznia_przypomnienia = false where user_id = u;
  r := kuznia_przypomnienia_tick('2030-01-12 17:00+00', u);
  assert pg_temp.typ(r) is null, 'wyłącznik: nic';
  update settings set kuznia_przypomnienia = true where user_id = u;
end $$;

-- Wygaszanie: 5 dni bez apki → jeden komunikat (o 18:00) i cisza; powrót → znów przypomnienia
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; l public.kuznia_przypomnienia; begin
  -- ostatnia aktywność: praca 2030-01-08 08:00 → 2030-01-14 to już ponad 5 dni
  r := kuznia_przypomnienia_tick('2030-01-14 14:00+00', u);
  assert pg_temp.typ(r) is null, 'wygaszanie tylko o godzinie „zostalo”';
  r := kuznia_przypomnienia_tick('2030-01-14 17:00+00', u);
  assert pg_temp.typ(r) = 'wygaszenie', 'wygaszanie: wysłane ' || r::text;
  l := pg_temp.log(u, '2030-01-14', 'wygaszenie');
  assert l.tytul = '[ KUŹNIA ] Kuźnia wygasza ogień' and l.tresc = 'Wróć, kiedy będziesz gotów.', 'wygaszanie: tekst';
  r := kuznia_przypomnienia_tick('2030-01-15 14:00+00', u);
  assert pg_temp.typ(r) is null, 'po wygaszeniu: cisza o 15:00';
  r := kuznia_przypomnienia_tick('2030-01-15 17:00+00', u);
  assert pg_temp.typ(r) is null, 'po wygaszeniu: cisza o 18:00';
  insert into praca(user_id,date,kind,started_at,ended_at) values (u,'2030-01-16','zlap','2030-01-16 08:00+01','2030-01-16 08:30+01');
  r := kuznia_przypomnienia_tick('2030-01-16 17:00+00', u);
  assert pg_temp.typ(r) = 'zostalo', 'powrót: przypomnienia wracają ' || r::text;
end $$;

-- Czas letni: 15:00 = 13:00 UTC, 18:00 = 16:00 UTC
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; begin
  insert into praca(user_id,date,kind,started_at,ended_at) values (u,'2030-07-09','getmed','2030-07-09 08:00+02','2030-07-09 09:00+02');
  r := kuznia_przypomnienia_tick('2030-07-09 13:00+00', u);
  assert pg_temp.typ(r) = 'seria', 'lato: 15:00 = 13:00 UTC';
  r := kuznia_przypomnienia_tick('2030-07-09 16:00+00', u);
  assert pg_temp.typ(r) = 'zostalo', 'lato: 18:00 = 16:00 UTC';
  r := kuznia_przypomnienia_tick('2030-07-09 17:00+00', u);
  assert pg_temp.typ(r) is null, 'lato: 19:00 lokalnie = nic';
end $$;

-- Uprawnienia i harmonogram
do $$ begin
  assert not has_function_privilege('authenticated', 'public.kuznia_przypomnienia_tick(timestamptz, uuid)', 'execute'), 'tick niedostępny z apki';
  assert not has_function_privilege('anon', 'public.push_send_tag(uuid, text, text, text, int)', 'execute'), 'push_send_tag niedostępny';
  assert not has_function_privilege('authenticated', 'public.kuznia__przypomnienie(uuid, text, timestamptz)', 'execute'), 'teksty niedostępne z apki';
  assert (select schedule from cron.job where jobname = 'kuznia-przypomnienia') = '*/15 * * * *', 'cron co 15 min';
end $$;

rollback;

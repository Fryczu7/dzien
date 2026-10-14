-- Testy przypomnień Kuźni (B3). Uruchamiać w całości jednym wywołaniem (execute_sql) – kończą się rollback,
-- więc nic nie zostaje w bazie, a żądania pg_net (wysyłka) nie wychodzą. Dane testowe: daty z 2030 roku, konto Michała.
-- Sukces = brak błędu. Błąd asercji podaje, który test nie przeszedł.
begin;

create function pg_temp.reset(u uuid) returns void language sql as $$
  delete from public.kuznia_przypomnienia where user_id = u;
  delete from public.kuznia_dni where user_id = u;
  update public.settings set kuznia_zadania = null, kuznia_przypomnienia = true where user_id = u;
  insert into public.kuznia_stan (user_id, seria) values (u, 12) on conflict (user_id) do update set seria = 12;
$$;
create function pg_temp.log(u uuid, d date, t text) returns public.kuznia_przypomnienia language sql as $$
  select * from public.kuznia_przypomnienia where user_id = u and date = d and typ = t
$$;

-- Pomocnicze formaty
do $$ begin
  assert kuznia__hm(2 + 10 / 60.0) = '2:10', 'hm: 2:10';
  assert kuznia__hm(0) = '0:00', 'hm: 0:00';
  assert kuznia__hm(2.999) = '3:00', 'hm: zaokrąglenie do 3:00';
  assert kuznia__do_polnocy('2030-01-08 18:00+01') = '6 h', 'do północy zimą: 6 h';
  assert kuznia__do_polnocy('2030-01-08 21:30+01') = '2 h 30 min', 'do północy: 2 h 30 min';
  assert kuznia__do_polnocy('2030-07-09 18:00+02') = '6 h', 'do północy latem: 6 h';
end $$;

-- 18:00 zimą (17:00 UTC): lista tego, co zostało; raz na dzień
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; l public.kuznia_przypomnienia; begin
  perform pg_temp.reset(u);
  insert into praca(user_id,date,kind,started_at,ended_at) values (u,'2030-01-08','getmed','2030-01-08 08:00+01','2030-01-08 10:10+01');
  r := kuznia_przypomnienia_tick('2030-01-08 16:00+00', u);
  assert r->>'typ' is null, '17:00 lokalnie: nic';
  r := kuznia_przypomnienia_tick('2030-01-08 17:00+00', u);
  assert r->>'typ' = '18' and jsonb_array_length(r->'wyslane') = 1, '18:00 zimą: wysłane';
  l := pg_temp.log(u, '2030-01-08', '18');
  assert l.tytul like '[ KUŹNIA ] %', '18: prefiks';
  assert l.tresc like '%GetMed 2:10 / 4:00%' and l.tresc like '%Złap Termin 0:00 / 1:00%', '18: postęp pracy: ' || l.tresc;
  assert l.tytul || l.tresc not like '%System%' and l.tytul || l.tresc not like '%Gracz%', '18: bez System/Gracz';
  r := kuznia_przypomnienia_tick('2030-01-08 17:15+00', u);
  assert jsonb_array_length(r->'wyslane') = 0, '18: drugi raz nic';
end $$;

-- 21:30 zimą (20:30 UTC): dzień niezaliczony → seria zagrożona
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; l public.kuznia_przypomnienia; begin
  r := kuznia_przypomnienia_tick('2030-01-08 20:30+00', u);
  assert r->>'typ' = '2130' and jsonb_array_length(r->'wyslane') = 1, '21:30: wysłane';
  l := pg_temp.log(u, '2030-01-08', '2130');
  assert l.tytul || ' ' || l.tresc like '%12 dni%', '21:30: długość serii: ' || l.tytul || ' ' || l.tresc;
  -- dzień zaliczony (modlitwa) → bez przypomnienia o 21:30
  insert into days(user_id,date,morning) values (u,'2030-01-09','{"modlitwa":true}');
  r := kuznia_przypomnienia_tick('2030-01-09 20:30+00', u);
  assert jsonb_array_length(r->'wyslane') = 0, '21:30: zaliczony = nic';
  -- seria 1 → „1 dnia”
  update kuznia_stan set seria = 1 where user_id = u;
  assert (select (p->>'tytul') || (p->>'tresc') from (select kuznia__przypomnienie(u, '2130', '2030-01-10 20:30+00') p) x) like '%1 dnia%', 'seria 1 dnia';
  update kuznia_stan set seria = 0 where user_id = u;
  assert kuznia__przypomnienie(u, '2130', '2030-01-10 20:30+00') is not null, 'seria 0: inny tekst, ale jest';
end $$;

-- Wszystko zrobione → bez przypomnienia o 18:00; wyłącznik w ustawieniach
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; begin
  update settings set kuznia_zadania = '[{"k":"x","nazwa":"Próba","zrodlo":"reczne","xp":10}]' where user_id = u;
  insert into kuznia_dni(user_id,date,reczne) values (u,'2030-01-10','{"x":true}');
  r := kuznia_przypomnienia_tick('2030-01-10 17:00+00', u);
  assert jsonb_array_length(r->'wyslane') = 0, '18: wszystko zrobione = nic';
  update settings set kuznia_zadania = null, kuznia_przypomnienia = false where user_id = u;
  r := kuznia_przypomnienia_tick('2030-01-11 17:00+00', u);
  assert jsonb_array_length(r->'wyslane') = 0, 'wyłącznik: nic';
  update settings set kuznia_przypomnienia = true where user_id = u;
end $$;

-- Wygaszanie: 5 dni bez apki → jeden komunikat i cisza; powrót → znów przypomnienia
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; l public.kuznia_przypomnienia; begin
  -- ostatnia aktywność: praca 2030-01-08 08:00 → 2030-01-14 to już ponad 5 dni
  r := kuznia_przypomnienia_tick('2030-01-14 20:30+00', u);
  assert jsonb_array_length(r->'wyslane') = 0, 'wygaszanie tylko o 18:00';
  r := kuznia_przypomnienia_tick('2030-01-14 17:00+00', u);
  assert r->'wyslane'->0->>'typ' = 'wygaszenie', 'wygaszanie: wysłane';
  l := pg_temp.log(u, '2030-01-14', 'wygaszenie');
  assert l.tytul = '[ KUŹNIA ] Kuźnia wygasza ogień' and l.tresc = 'Wróć, kiedy będziesz gotów.', 'wygaszanie: tekst';
  r := kuznia_przypomnienia_tick('2030-01-15 17:00+00', u);
  assert jsonb_array_length(r->'wyslane') = 0, 'po wygaszeniu: cisza';
  r := kuznia_przypomnienia_tick('2030-01-15 20:30+00', u);
  assert jsonb_array_length(r->'wyslane') = 0, 'po wygaszeniu: cisza o 21:30';
  insert into praca(user_id,date,kind,started_at,ended_at) values (u,'2030-01-16','zlap','2030-01-16 08:00+01','2030-01-16 08:30+01');
  r := kuznia_przypomnienia_tick('2030-01-16 17:00+00', u);
  assert r->'wyslane'->0->>'typ' = '18', 'powrót: przypomnienia wracają';
end $$;

-- Czas letni: 18:00 = 16:00 UTC, 21:30 = 19:30 UTC
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; begin
  insert into praca(user_id,date,kind,started_at,ended_at) values (u,'2030-07-09','getmed','2030-07-09 08:00+02','2030-07-09 09:00+02');
  r := kuznia_przypomnienia_tick('2030-07-09 16:00+00', u);
  assert r->>'typ' = '18', 'lato: 18:00 = 16:00 UTC';
  r := kuznia_przypomnienia_tick('2030-07-09 19:30+00', u);
  assert r->>'typ' = '2130', 'lato: 21:30 = 19:30 UTC';
  r := kuznia_przypomnienia_tick('2030-07-09 20:30+00', u);
  assert r->>'typ' is null, 'lato: 22:30 lokalnie = nic';
end $$;

-- Uprawnienia
do $$ begin
  assert not has_function_privilege('authenticated', 'public.kuznia_przypomnienia_tick(timestamptz, uuid)', 'execute'), 'tick niedostępny z apki';
  assert not has_function_privilege('anon', 'public.push_send_tag(uuid, text, text, text, int)', 'execute'), 'push_send_tag niedostępny';
  assert not has_function_privilege('authenticated', 'public.kuznia__przypomnienie(uuid, text, timestamptz)', 'execute'), 'teksty niedostępne z apki';
end $$;

rollback;

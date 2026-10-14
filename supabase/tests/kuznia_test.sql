-- Testy Kuźni (Faza A). Uruchamiać w całości jednym wywołaniem (execute_sql) – kończą się rollback,
-- więc nic nie zostaje w bazie. Dane testowe tylko na daty z 2030 roku na koncie Michała.
-- Sukces = brak błędu. Błąd asercji podaje, który test nie przeszedł.
begin;

-- Pomocnik: czysty stan gry Michała na czas testu (rollback i tak wszystko cofa).
create function pg_temp.reset(u uuid, tryb text default 'normal') returns void language sql as $$
  delete from public.kuznia_dni where user_id = u;
  delete from public.kuznia_stan where user_id = u;
  update public.settings set kuznia_tryb = tryb, kuznia_zadania = null,
    boss = '{"nazwa":"Strażnik 20 godzin","zrodlo":"praca:getmed","cel":20}'::jsonb where user_id = u;
$$;
create function pg_temp.z(r jsonb, k text) returns jsonb language sql as $$
  select z from jsonb_array_elements(r->'zadania') z where z->>'k' = k
$$;

-- ===== A2: zadania dnia na żywo =====
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; begin
  perform pg_temp.reset(u);
  -- wtorek 2030-01-08
  insert into praca(user_id,date,kind,started_at,ended_at) values (u,'2030-01-08','getmed','2030-01-08 08:00+01','2030-01-08 12:30+01');
  insert into days(user_id,date,sleep_h,morning,plan) values (u,'2030-01-08',7.5,'{"modlitwa":true}','[{"text":"Skrypt","done":true}]');
  r := kuznia_dzien_na_zywo('2030-01-08', u);
  assert (pg_temp.z(r,'getmed')->>'zrobione')::bool, 'A2: getmed 4,5 h = zrobione';
  assert (pg_temp.z(r,'getmed')->>'postep')::numeric = 4.5, 'A2: getmed postęp 4,5 h';
  assert (pg_temp.z(r,'getmed')->>'xp')::int = 45, 'A2: getmed 45 XP';
  assert (pg_temp.z(r,'zlap')->>'zrobione')::bool = false, 'A2: zlap 0 h';
  assert (pg_temp.z(r,'plan')->>'zrobione')::bool and (pg_temp.z(r,'plan')->>'xp')::int = 20, 'A2: plan 1/1 = 20 XP';
  assert (r->>'czysty')::bool = false and (r->>'zaliczony')::bool, 'A2: zaliczony, nieczysty';
  -- XP: getmed 45 + sen 15 + modlitwa 10 + plan 20 = 90
  assert (r->>'xp')::int = 90, 'A2: suma XP wtorku = 90, jest ' || (r->>'xp');
  assert (r->'boss'->>'cel')::numeric = 20 and (r->'boss'->>'hp')::numeric = 15.5, 'A2: boss na żywo 20 - 4,5 = 15,5';

  -- trening wspinaczka → Zwinność; plan z rehabem – rehab się nie liczy
  insert into workouts(user_id,date,name,kind,status) values (u,'2030-01-08','test','wspinaczka','zrobiony');
  r := kuznia_dzien_na_zywo('2030-01-08', u);
  assert (pg_temp.z(r,'trening')->>'zrobione')::bool and pg_temp.z(r,'trening')->>'stat' = 'Zwinność', 'A2: wspinaczka = Zwinność';
  insert into days(user_id,date,plan) values (u,'2030-01-10','[{"text":"Rehab kolano","done":false},{"text":"A","done":true}]');
  r := kuznia_dzien_na_zywo('2030-01-10', u);
  assert (pg_temp.z(r,'plan')->>'zrobione')::bool, 'A2: rehab nie jest pozycją planu';
  -- pusty plan = zadanie nieaktywne
  r := kuznia_dzien_na_zywo('2030-01-09', u);
  assert (pg_temp.z(r,'plan')->>'aktywne')::bool = false, 'A2: pusty plan nieaktywny';
  assert (r->>'zaliczony')::bool = false and (r->>'xp')::int = 0, 'A2: dzień bez danych = 0 XP, niezaliczony';

  -- Review Focus 3: sobota 2030-01-12 – praca i trening nieaktywne; modlitwa + sen + kalorie = czysty
  insert into days(user_id,date,morning,sleep_h) values (u,'2030-01-12','{"modlitwa":true}',8);
  insert into meals(user_id,date,name,kcal) values (u,'2030-01-12','test',3300);
  r := kuznia_dzien_na_zywo('2030-01-12', u);
  assert (pg_temp.z(r,'getmed')->>'aktywne')::bool = false and (pg_temp.z(r,'trening')->>'aktywne')::bool = false, 'A2: sobota bez pracy i treningu';
  assert (r->>'czysty')::bool, 'A2: sobota: modlitwa+sen+kalorie = czysty';
  assert (r->>'xp')::int = 15 + 15 + 10 + 25, 'A2: sobota XP = 65 (z +25 za czysty)';

  -- ręczne odhaczenie modlitwy w kuznia_dni
  insert into kuznia_dni(user_id,date,reczne) values (u,'2030-01-13','{"modlitwa":true}');
  r := kuznia_dzien_na_zywo('2030-01-13', u);
  assert (pg_temp.z(r,'modlitwa')->>'zrobione')::bool, 'A2: modlitwa z ręcznego odhaczenia';

  -- własne zadania konta: ręczne zadanie i limit 100 XP pracy
  update settings set kuznia_zadania = '[{"k":"a","nazwa":"Praca A","zrodlo":"praca:getmed","cel":4,"jedn":"h","xp_jedn":10,"stat":"Pracowitość"},
     {"k":"b","nazwa":"Praca B","zrodlo":"praca:zlap","cel":1,"jedn":"h","xp_jedn":10,"stat":"Pracowitość"},
     {"k":"czyt","nazwa":"Czytanie","zrodlo":"reczne","cel":1,"xp":20,"stat":"Wiedza"}]' where user_id = u;
  insert into praca(user_id,date,kind,started_at,ended_at) values
    (u,'2030-01-14','getmed','2030-01-14 06:00+01','2030-01-14 14:00+01'),
    (u,'2030-01-14','zlap','2030-01-14 15:00+01','2030-01-14 18:00+01');
  insert into kuznia_dni(user_id,date,reczne) values (u,'2030-01-14','{"czyt":true}');
  r := kuznia_dzien_na_zywo('2030-01-14', u);
  assert jsonb_array_length(r->'zadania') = 3, 'A2: własna lista zadań konta';
  assert (pg_temp.z(r,'a')->>'xp')::int + (pg_temp.z(r,'b')->>'xp')::int = 100, 'A2: praca łącznie maks. 100 XP';
  assert (r->>'czysty')::bool and (r->>'xp')::int = 100 + 20 + 25, 'A2: czysty dzień z ręcznym zadaniem = 145 XP';
  update settings set kuznia_zadania = null where user_id = u;

  -- Review Focus 4: nowe konto bez ustawień Kuźni → domyślne zadania, bez błędu
  r := kuznia_dzien_na_zywo('2030-01-08', (select id from auth.users where email='realhuntrix@gmail.com'));
  assert jsonb_array_length(r->'zadania') >= 6, 'A2: domyślne zadania dla nowego konta';
  assert r->'boss' = 'null'::jsonb, 'A2: nowe konto bez bossa';
  r := kuznia_stan_teraz((select id from auth.users where email='realhuntrix@gmail.com'));
  assert (r->>'poziom')::int = 1 and r->>'ranga' = 'Ruda' and (r->>'seria')::int = 0, 'A2: stan nowego konta';
  assert jsonb_typeof(r->'statystyki') = 'object' and (r->'statystyki'->>'Dyscyplina')::int = 50, 'A2: statystyki nowego konta';
  assert jsonb_array_length(kuznia_domyslne_zadania()) = 7, 'A2: 7 domyślnych zadań';
end $$;

-- ===== Review Focus 5: stoper niezatrzymany – podgląd do „teraz”, zamknięcie do końca dnia =====
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; begin
  perform pg_temp.reset(u);
  -- jeśli stoper Michała właśnie chodzi, zatrzymaj go na czas testu (rollback przywraca)
  update praca set ended_at = now() where user_id = u and ended_at is null;
  insert into praca(user_id,date,kind,started_at) values (u,'2030-01-16','getmed','2030-01-16 22:00+01');
  r := kuznia_dzien_na_zywo('2030-01-16', u);
  -- „teraz” jest przed 2030, więc otwarty odcinek w podglądzie daje 0 h (nie liczy z góry do końca dnia)
  assert (pg_temp.z(r,'getmed')->>'postep')::numeric = 0, 'RF5: podgląd liczy otwarty odcinek do teraz';
  r := kuznia_zamknij_dzien('2030-01-16', u);
  assert (select (z->>'postep')::numeric from kuznia_dni d, jsonb_array_elements(d.zadania) z
          where d.user_id = u and d.date = '2030-01-16' and z->>'k' = 'getmed') = 2, 'RF5: zamknięcie liczy 22:00–24:00 = 2 h';
end $$;

-- ===== A3: zamknięcie dnia =====
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; r2 jsonb; x int; d date; begin
  perform pg_temp.reset(u);
  -- (a) 3 dni zaliczone (pn–śr 2030-02-04..06: tylko modlitwa)
  insert into days(user_id,date,morning) values (u,'2030-02-04','{"modlitwa":true}'),(u,'2030-02-05','{"modlitwa":true}'),(u,'2030-02-06','{"modlitwa":true}');
  r := kuznia_zamknij_dzien('2030-02-04', u);
  assert (r->>'zaliczony')::bool and (r->>'seria')::int = 1, '(a) dzień 1';
  -- Normal: 6 aktywnych, 1 zrobione → kara 25
  assert (r->>'kara_dyscyplina')::int = 25, '(a) kara za 5 niezrobionych = 25, jest ' || (r->>'kara_dyscyplina');
  perform kuznia_zamknij_dzien('2030-02-05', u);
  r := kuznia_zamknij_dzien('2030-02-06', u);
  assert (r->>'seria')::int = 3 and (r->>'tarcze')::int = 1, '(a) seria 3, tarcza 1';
  assert r->>'komunikat' like '[ KUŹNIA ]%', '(a) komunikat Kuźni';
  -- (b) Review Focus 1: pusty dzień przy tarczy → tarcza zużyta, seria bez zmian
  r := kuznia_zamknij_dzien('2030-02-07', u);
  assert (r->>'zaliczony')::bool = false and (r->>'tarcza_uzyta')::bool and (r->>'seria')::int = 3 and (r->>'tarcze')::int = 0, '(b) tarcza ratuje serię';
  assert (select zamkniety_at is not null from kuznia_dni where user_id=u and date='2030-02-07'), '(b) pusty dzień zapisany jako zamknięty';
  -- (c) drugi pusty dzień → seria 0, seria_utracona 3
  r := kuznia_zamknij_dzien('2030-02-08', u);
  assert (r->>'seria')::int = 0 and (r->>'seria_utracona')::int = 3, '(c) utrata serii';
  assert (select najdluzsza_seria from kuznia_stan where user_id=u) = 3, '(c) najdłuższa seria 3';
  -- (d) Normal: sobota, aktywne kalorie+sen+modlitwa, zrobiona tylko modlitwa → kara 10
  insert into days(user_id,date,morning) values (u,'2030-02-09','{"modlitwa":true}');
  r := kuznia_zamknij_dzien('2030-02-09', u);
  assert (r->>'kara_dyscyplina')::int = 10, '(d) 2 niezrobione = kara 10';
  assert r->>'zadanie_karne_jutro' is null, '(d) Normal bez zadania karnego';
  -- (f) idempotencja: drugie wywołanie = ten sam wynik, xp_suma bez zmian
  x := (select xp_suma from kuznia_stan where user_id=u);
  r2 := kuznia_zamknij_dzien('2030-02-09', u);
  assert r2 = r, '(f) ten sam wynik';
  assert (select xp_suma from kuznia_stan where user_id=u) = x, '(f) xp_suma bez zmian';
  assert (select count(*) from kuznia_dni where user_id=u and date between '2030-02-04' and '2030-02-09' and zamkniety_at is not null) = 6, '(f) 6 zamkniętych dni';
  -- xp_suma = 10 × 4 dni z modlitwą
  assert x = 40, '(f) xp_suma = 40, jest ' || x;
  -- tarcza wraca po pełnych 7 dniach serii
  perform pg_temp.reset(u);
  for d in select generate_series('2030-02-11'::date, '2030-02-17', '1 day')::date loop
    insert into days(user_id,date,morning) values (u,d,'{"modlitwa":true}');
  end loop;
  perform kuznia_zamknij_dzien('2030-02-11', u);
  perform kuznia_zamknij_dzien('2030-02-12', u);  -- tarcza na start = 1
  update kuznia_stan set tarcze = 0 where user_id = u;
  for d in select generate_series('2030-02-13'::date, '2030-02-17', '1 day')::date loop r := kuznia_zamknij_dzien(d, u); end loop;
  assert (r->>'seria')::int = 7 and (r->>'tarcze')::int = 1, '(a2) nowa tarcza po 7 dniach serii';
end $$;

-- (g) Review Focus 2: kilka zaległych dni naraz, bez podwójnego liczenia
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; begin
  perform pg_temp.reset(u);
  perform kuznia_zamknij_dzien('2030-03-03', u);           -- niedziela: tworzy stan
  r := kuznia_zamknij_zalegle('2030-03-06', u);             -- pn–śr bez danych
  assert jsonb_array_length(r) = 3, '(g) 3 zaległe dni';
  assert (select bool_and(not (x->>'zaliczony')::bool and (x->>'kara_dyscyplina')::int = 30) from jsonb_array_elements(r) x), '(g) każdy niezaliczony, kara osobno';
  assert (select string_agg(x->>'date', ',' order by x->>'date') from jsonb_array_elements(r) x) = '2030-03-04,2030-03-05,2030-03-06', '(g) po kolei';
  assert jsonb_array_length(kuznia_zamknij_zalegle('2030-03-06', u)) = 0, '(g) drugie wywołanie nic nie zamyka';
  assert (select sum(kara_dyscyplina) from kuznia_dni where user_id=u) = 90 + 15, '(g) kara bez podwójnego liczenia';
  -- brak stanu: zamyka tylko p_do
  perform pg_temp.reset(u);
  r := kuznia_zamknij_zalegle('2030-03-10', u);
  assert jsonb_array_length(r) = 1 and r->0->>'date' = '2030-03-10', '(g) bez stanu zamyka tylko p_do';
end $$;

-- (e) Hard: zadanie karne
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; begin
  perform pg_temp.reset(u, 'hard');
  insert into days(user_id,date,morning) values (u,'2030-04-01','{"modlitwa":true}');
  r := kuznia_zamknij_dzien('2030-04-01', u);                  -- nieczysty, +10 XP
  assert r->>'zadanie_karne_jutro' like 'Nadrób: %', '(e) zadanie karne na jutro: ' || coalesce(r->>'zadanie_karne_jutro','null');
  assert (select zadanie_karne from kuznia_dni where user_id=u and date='2030-04-02') = r->>'zadanie_karne_jutro', '(e) zapisane na następny dzień';
  r := kuznia_zamknij_dzien('2030-04-02', u);                  -- karne niezrobione: 10 - 30 → 0
  assert r->>'karne' = 'niezrobione' and (r->>'xp_suma')::int = 0, '(e) −30 XP, nie poniżej 0';
  update kuznia_stan set xp_suma = 100 where user_id = u;
  r := kuznia_zamknij_dzien('2030-04-03', u);
  assert (r->>'xp_suma')::int = 70, '(e) 100 − 30 = 70';
  update kuznia_dni set karne_zrobione = true where user_id=u and date='2030-04-04';
  r := kuznia_zamknij_dzien('2030-04-04', u);
  assert r->>'karne' = 'zrobione' and (r->>'xp_suma')::int = 70, '(e) zrobione karne bez kary';
  -- Normal nie daje zadań karnych
  perform pg_temp.reset(u, 'normal');
  r := kuznia_zamknij_dzien('2030-04-08', u);
  assert r->>'zadanie_karne_jutro' is null and not exists (select 1 from kuznia_dni where user_id=u and date='2030-04-09'), '(e) Normal bez zadania karnego';
end $$;

-- (h) boss: 20 h GetMed w tygodniu → w niedzielę pokonany, +200 raz
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; d date; x int; begin
  perform pg_temp.reset(u);
  for d in select generate_series('2030-05-06'::date, '2030-05-10', '1 day')::date loop
    insert into praca(user_id,date,kind,started_at,ended_at) values (u,d,'getmed',(d + time '08:00') at time zone 'Europe/Warsaw',(d + time '12:00') at time zone 'Europe/Warsaw');
  end loop;
  for d in select generate_series('2030-05-06'::date, '2030-05-11', '1 day')::date loop r := kuznia_zamknij_dzien(d, u); end loop;
  assert (r->'boss'->>'pokonany')::bool = false and (r->'boss'->>'hp')::numeric = 0, '(h) sobota: hp 0, nagroda dopiero w niedzielę';
  x := (select xp_suma from kuznia_stan where user_id=u);
  r := kuznia_zamknij_dzien('2030-05-12', u);
  assert (r->'boss'->>'pokonany')::bool, '(h) niedziela: boss pokonany';
  assert (r->>'xp')::int = 200 and (r->>'xp_suma')::int = x + 200, '(h) +200 XP';
  r := kuznia_zamknij_dzien('2030-05-12', u);
  assert (select xp_suma from kuznia_stan where user_id=u) = x + 200, '(h) +200 tylko raz';
  -- tydzień bez pracy: boss nie pokonany
  r := kuznia_zamknij_dzien('2030-05-19', u);
  assert (r->'boss'->>'pokonany')::bool = false and (r->'boss'->>'hp')::numeric = 20, '(h) boss cały';
  -- poziom w górę: 5 × 40 XP getmed + 200 = 400 XP → poziom 3
  assert (select (kuznia_poziom(xp_suma)->>'poziom')::int from kuznia_stan where user_id=u) = 3, '(h) poziom 3 po 400 XP';
end $$;

-- sezon 6 tygodni od poniedziałku i flaga „poziom w górę”
do $$ declare u uuid := (select id from auth.users where email='mfryczu@gmail.com'); r jsonb; begin
  perform pg_temp.reset(u);
  r := kuznia_zamknij_dzien('2030-06-05', u);
  assert (r->>'sezon_nr')::int = 1 and (select sezon_start from kuznia_stan where user_id=u) = '2030-06-03', 'sezon: start w poniedziałek';
  r := kuznia_zamknij_dzien('2030-07-14', u);
  assert (r->>'sezon_nr')::int = 1, 'sezon: dzień 42 to jeszcze sezon 1';
  r := kuznia_zamknij_dzien('2030-07-15', u);
  assert (r->>'sezon_nr')::int = 2 and (select sezon_start from kuznia_stan where user_id=u) = '2030-07-15', 'sezon: po 42 dniach sezon 2';
  update kuznia_stan set xp_suma = 140 where user_id = u;
  insert into days(user_id,date,morning) values (u,'2030-07-16','{"modlitwa":true}');
  r := kuznia_zamknij_dzien('2030-07-16', u);
  assert (r->>'poziom_w_gore')::bool and (r->>'poziom')::int = 2, 'poziom w górę przy 150 XP';
  r := kuznia_stan_teraz(u);
  assert (r->>'xp_suma')::int = 150 and r ? 'boss' and r ? 'sezon' and (r->'statystyki') ? 'Pracowitość', 'stan_teraz: pola';
end $$;

-- (i) poziomy i rangi
do $$ begin
  assert (kuznia_poziom(0)->>'poziom')::int = 1 and kuznia_poziom(0)->>'ranga' = 'Ruda', '(i) 0 XP = poziom 1 Ruda';
  assert (kuznia_poziom(0)->>'do_nastepnego')::int = 150, '(i) do poziomu 2: 150';
  assert (kuznia_poziom(149)->>'poziom')::int = 1, '(i) 149 = poziom 1';
  assert (kuznia_poziom(150)->>'poziom')::int = 2 and (kuznia_poziom(150)->>'w_poziomie')::int = 0, '(i) 150 = poziom 2';
  assert (kuznia_poziom(150)->>'do_nastepnego')::int = 188, '(i) próg 3 = 150 + 188';
  assert (kuznia_poziom(337)->>'poziom')::int = 2 and (kuznia_poziom(338)->>'poziom')::int = 3, '(i) 338 = poziom 3';
  assert kuznia_poziom(338)->>'ranga' = 'Żelazo', '(i) poziom 3 = Żelazo';
  assert kuznia_poziom(1000000)->>'ranga' = 'Legenda', '(i) Legenda';
end $$;

-- bezpieczeństwo: cudze konto i rola anon
do $$ begin
  assert not has_function_privilege('anon', 'public.kuznia_dzien_na_zywo(date, uuid)', 'execute'), 'anon nie woła kuznia_dzien_na_zywo';
  assert not has_function_privilege('anon', 'public.kuznia_zamknij_dzien(date, uuid)', 'execute'), 'anon nie zamyka dnia';
  assert not has_function_privilege('anon', 'public.kuznia_zamknij_zalegle(date, uuid)', 'execute'), 'anon nie zamyka zaległych';
  assert not has_function_privilege('anon', 'public.kuznia_stan_teraz(uuid)', 'execute'), 'anon nie czyta stanu';
  assert not has_function_privilege('authenticated', 'public.kuznia__dzien(date, uuid, boolean)', 'execute'), 'pomocnik niedostępny z apki';
end $$;
select set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where email='realhuntrix@gmail.com'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$ declare ok bool := false; begin
  begin
    perform kuznia_dzien_na_zywo('2030-01-08', '00000000-0000-0000-0000-000000000001'::uuid);
  exception when others then ok := sqlerrm like '%cudze konto%'; end;
  assert ok, 'cudze konto: wyjątek';
  perform kuznia_dzien_na_zywo('2030-01-08');                 -- własne konto: bez błędu
end $$;
reset role;

rollback;

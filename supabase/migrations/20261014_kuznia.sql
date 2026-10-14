-- Kuźnia (Faza A, 14.10.2026): apka Dzień jako gra – cała logika w bazie.
-- Plan: docs/superpowers/plans/2026-10-14-kuznia.md, spec: docs/superpowers/specs/2026-10-14-kuznia-design.md (repo CEO).
-- Testy: supabase/tests/kuznia_test.sql (w transakcji z rollback).
-- Publiczne funkcje: kuznia_domyslne_zadania, kuznia_dzien_na_zywo, kuznia_zamknij_dzien, kuznia_zamknij_zalegle,
-- kuznia_poziom, kuznia_stan_teraz. Pomocnicze kuznia__* – tylko dla właściciela i roli serwisowej.

-- ===== A1: tabele i ustawienia =====
alter table public.settings add column if not exists kuznia_tryb text not null default 'normal' check (kuznia_tryb in ('normal','hard'));
alter table public.settings add column if not exists kuznia_zadania jsonb;   -- null = kuznia_domyslne_zadania()
alter table public.settings add column if not exists boss jsonb;             -- {"nazwa","zrodlo":"praca:<kind>","cel"}; null = brak bossa

-- Jeden wiersz na zamknięty dzień (i na dzień z ręcznymi odhaczeniami albo zadaniem karnym przed zamknięciem)
create table public.kuznia_dni (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date date not null,
  reczne jsonb not null default '{}'::jsonb,        -- ręczne odhaczenia: {"<klucz>": true}
  zadanie_karne text,                               -- Hard: zadanie karne NA TEN dzień
  karne_zrobione boolean not null default false,
  zadania jsonb,                                    -- wynik przy zamknięciu: [{k,nazwa,zrodlo,postep,cel,jedn,zrobione,xp,stat,aktywne}]
  xp int not null default 0,
  xp_stat jsonb not null default '{}'::jsonb,       -- {"Pracowitość": 60, ...}
  czysty boolean, zaliczony boolean, tarcza_uzyta boolean not null default false,
  kara_dyscyplina int not null default 0,
  zamkniety_at timestamptz,
  podsumowanie jsonb,                               -- to, co zwróciło kuznia_zamknij_dzien (idempotencja)
  primary key (user_id, date)
);
alter table public.kuznia_dni enable row level security;
create policy wlasne on public.kuznia_dni for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Stan gry konta. Apka tylko czyta – zmienia go wyłącznie kuznia_zamknij_dzien (żeby nie dało się dopisać sobie XP).
create table public.kuznia_stan (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  xp_suma int not null default 0,
  seria int not null default 0, najdluzsza_seria int not null default 0,
  tarcze int not null default 1 check (tarcze between 0 and 1),
  seria_utracona int not null default 0,             -- długość ostatnio utraconej serii (do płatnej naprawy)
  sezon_nr int not null default 1, sezon_start date,
  ostatni_zamkniety date,
  updated_at timestamptz not null default now()
);
alter table public.kuznia_stan enable row level security;
create policy wlasne_odczyt on public.kuznia_stan for select to authenticated using (user_id = (select auth.uid()));

-- Michał: boss 20 h GetMed
update public.settings set boss = '{"nazwa":"Strażnik 20 godzin","zrodlo":"praca:getmed","cel":20}'::jsonb
 where user_id = (select id from auth.users where email = 'mfryczu@gmail.com');

-- ===== Pomocnicze =====
create or replace function public.kuznia__dzis() returns date language sql stable set search_path = public as $$
  select (now() at time zone 'Europe/Warsaw')::date
$$;

-- Koniec dnia (północ następnego dnia czasu warszawskiego)
create or replace function public.kuznia__koniec(p_date date) returns timestamptz language sql stable set search_path = public as $$
  select (p_date + 1)::timestamp at time zone 'Europe/Warsaw'
$$;

-- Godziny pracy danego rodzaju w dniach p_od..p_do. Odcinek liczy się do dnia startu (praca.date).
-- Niezamknięty odcinek: w podglądzie (p_live) i dla dzisiejszego dnia – do teraz; dla dnia minionego – do końca dnia.
create or replace function public.kuznia__godziny(p_user uuid, p_kind text, p_od date, p_do date, p_live boolean)
returns numeric language sql stable set search_path = public as $$
  select coalesce(sum(greatest(0, extract(epoch from
           coalesce(p.ended_at, case when p_live or p.date = kuznia__dzis() then now() else kuznia__koniec(p.date) end)
           - p.started_at))), 0) / 3600.0
    from praca p where p.user_id = p_user and p.kind = p_kind and p.date between p_od and p_do
$$;

-- Boss tygodnia (pn..p_date): {"nazwa","hp","cel"} albo null
create or replace function public.kuznia__boss(p_user uuid, p_date date, p_live boolean)
returns jsonb language plpgsql stable set search_path = public as $$
declare b jsonb; cel numeric; h numeric := 0; pn date := p_date - (extract(isodow from p_date)::int - 1);
begin
  select boss into b from settings where user_id = p_user;
  if b is null or jsonb_typeof(b) <> 'object' then return null; end if;
  cel := coalesce((b->>'cel')::numeric, 20);
  if b->>'zrodlo' like 'praca:%' then h := kuznia__godziny(p_user, substr(b->>'zrodlo', 7), pn, p_date, p_live); end if;
  return jsonb_build_object('nazwa', coalesce(b->>'nazwa', 'Boss tygodnia'), 'hp', round(greatest(0, cel - h), 2), 'cel', cel);
end $$;

-- Dostęp: rola serwisowa (rutyny) ma auth.uid() = null; zalogowany Kowal tylko swoje konto.
create or replace function public.kuznia__sprawdz(p_user uuid) returns void language plpgsql stable set search_path = public as $$
begin
  if p_user is null then raise exception 'brak konta'; end if;
  if auth.uid() is not null and p_user <> auth.uid() then raise exception 'cudze konto'; end if;
end $$;

-- ===== A2: zadania dnia =====
create or replace function public.kuznia_domyslne_zadania() returns jsonb language sql immutable as $$
  select '[
   {"k":"getmed","nazwa":"GetMed – praca","zrodlo":"praca:getmed","cel":4,"jedn":"h","xp_jedn":10,"stat":"Pracowitość","dni":[1,2,3,4,5]},
   {"k":"zlap","nazwa":"Złap Termin – praca","zrodlo":"praca:zlap","cel":1,"jedn":"h","xp_jedn":10,"stat":"Pracowitość","dni":[1,2,3,4,5]},
   {"k":"trening","nazwa":"Trening","zrodlo":"trening","cel":1,"xp":30,"stat":"Siła","dni":[1,2,3]},
   {"k":"kalorie","nazwa":"Kalorie","zrodlo":"kalorie","cel":0.9,"xp":15,"stat":"Zdrowie"},
   {"k":"sen","nazwa":"Sen 7 h","zrodlo":"sen","cel":7,"xp":15,"stat":"Zdrowie"},
   {"k":"modlitwa","nazwa":"Modlitwa","zrodlo":"modlitwa","cel":1,"xp":10,"stat":"Duch"},
   {"k":"plan","nazwa":"Plan dnia","zrodlo":"plan","cel":1,"xp":20,"stat":"Wiedza"}
  ]'::jsonb
$$;

-- Wynik dnia. p_live = podgląd (otwarty odcinek stopera do teraz), false = zamknięcie (do końca dnia).
-- XP liczy się także z zadań nieaktywnych danego dnia (np. praca w sobotę); aktywne decydują o czystym dniu, zaliczeniu i karze.
create or replace function public.kuznia__dzien(p_date date, p_user uuid, p_live boolean)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  s settings%rowtype; dy days%rowtype; kd kuznia_dni%rowtype;
  t jsonb; zadania jsonb := '[]'::jsonb; xp_stat jsonb := '{}'::jsonb;
  dow int := extract(isodow from p_date)::int;
  src text; stat text; jedn text; extra jsonb;
  aktywne boolean; zrobione boolean; postep numeric; cel numeric; xp int;
  praca_xp int := 0; suma int := 0; n_akt int := 0; n_zrob int := 0;
  kcal int; kcal_cel int; plan_n int; plan_done int; w_kind text;
begin
  select * into s from settings where user_id = p_user;
  select * into dy from days where user_id = p_user and date = p_date;
  select * into kd from kuznia_dni where user_id = p_user and date = p_date;

  for t in select * from jsonb_array_elements(coalesce(s.kuznia_zadania, kuznia_domyslne_zadania())) loop
    src := coalesce(t->>'zrodlo', 'reczne');
    stat := coalesce(t->>'stat', 'Wiedza');
    jedn := t->>'jedn';
    cel := coalesce((t->>'cel')::numeric, 1);
    aktywne := jsonb_typeof(t->'dni') is distinct from 'array' or (t->'dni') @> to_jsonb(dow);
    xp := null; extra := '{}'::jsonb;

    if src like 'praca:%' then
      postep := round(kuznia__godziny(p_user, substr(src, 7), p_date, p_date, p_live), 2);
      zrobione := postep >= cel;
      xp := least(round(postep * coalesce((t->>'xp_jedn')::numeric, 10))::int, greatest(0, 100 - praca_xp));  -- praca łącznie maks. 100/dzień
      praca_xp := praca_xp + xp;
    elsif src = 'trening' then
      select count(*), (array_agg(kind order by created_at))[1] into postep, w_kind
        from workouts where user_id = p_user and date = p_date and status = 'zrobiony';
      zrobione := postep >= cel;
      if w_kind in ('wspinaczka', 'bieg') then stat := 'Zwinność'; end if;
    elsif src = 'kalorie' then
      select coalesce(sum(m.kcal), 0) into kcal from meals m where m.user_id = p_user and m.date = p_date;
      kcal_cel := coalesce(dy.kcal_target, s.kcal_target, 2500);
      zrobione := kcal_cel > 0 and kcal::numeric / kcal_cel >= cel;
      postep := round(kcal::numeric / nullif(kcal_cel, 0), 2);
      extra := jsonb_build_object('kcal', kcal, 'kcal_cel', kcal_cel);
    elsif src = 'sen' then
      postep := coalesce(dy.sleep_h, 0);
      zrobione := postep >= cel;
    elsif src = 'modlitwa' then
      zrobione := coalesce(dy.morning->>'modlitwa', '') = 'true' or coalesce(kd.reczne->>(t->>'k'), '') = 'true';
      postep := case when zrobione then 1 else 0 end;
    elsif src = 'rehab' then
      zrobione := coalesce(dy.rehab, false) or coalesce(kd.reczne->>(t->>'k'), '') = 'true';
      postep := case when zrobione then 1 else 0 end;
    elsif src = 'plan' then
      -- pozycje planu bez rehabu i leków (jak planWithoutToggles w lib.js)
      select count(*), count(*) filter (where coalesce(p->>'done', '') = 'true') into plan_n, plan_done
        from jsonb_array_elements(case when jsonb_typeof(dy.plan) = 'array' then dy.plan else '[]'::jsonb end) p
       where coalesce(p->>'text', '') !~* '^\s*(rehab|leki)';
      aktywne := aktywne and plan_n > 0;
      postep := plan_done; cel := plan_n;
      zrobione := plan_n > 0 and plan_done = plan_n;
      xp := coalesce((t->>'xp')::int, 20) * least(plan_done, coalesce((t->>'maks')::int, 3));
    else  -- 'reczne' i każde inne: odhaczenie w kuznia_dni.reczne
      zrobione := coalesce(kd.reczne->>(t->>'k'), '') = 'true';
      postep := case when zrobione then 1 else 0 end;
    end if;

    if xp is null then xp := case when zrobione then coalesce((t->>'xp')::int, 10) else 0 end; end if;
    if aktywne then n_akt := n_akt + 1; if zrobione then n_zrob := n_zrob + 1; end if; end if;
    suma := suma + xp;
    if xp <> 0 then xp_stat := xp_stat || jsonb_build_object(stat, coalesce((xp_stat->>stat)::int, 0) + xp); end if;
    zadania := zadania || jsonb_build_array(jsonb_build_object(
      'k', t->>'k', 'nazwa', t->>'nazwa', 'zrodlo', src, 'postep', postep, 'cel', cel, 'jedn', jedn,
      'zrobione', zrobione, 'xp', xp, 'stat', stat, 'aktywne', aktywne) || extra);
  end loop;

  if n_akt > 0 and n_zrob = n_akt then   -- czysty dzień: +25 do Dyscypliny
    suma := suma + 25;
    xp_stat := xp_stat || jsonb_build_object('Dyscyplina', coalesce((xp_stat->>'Dyscyplina')::int, 0) + 25);
  end if;

  return jsonb_build_object(
    'date', p_date, 'zadania', zadania, 'xp', suma, 'xp_stat', xp_stat,
    'czysty', n_akt > 0 and n_zrob = n_akt, 'zaliczony', n_zrob > 0,
    'zadanie_karne', kd.zadanie_karne, 'karne_zrobione', coalesce(kd.karne_zrobione, false),
    'boss', kuznia__boss(p_user, p_date, p_live));
end $$;

create or replace function public.kuznia_dzien_na_zywo(p_date date, p_user uuid default auth.uid())
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform kuznia__sprawdz(p_user);
  return kuznia__dzien(p_date, p_user, true);
end $$;

-- ===== A3: poziom, zamknięcie dnia, zaległe dni, stan =====
-- Próg: 150 XP na poziom 2, każdy kolejny ×1,25 (zaokrąglony). do_nastepnego = ile XP brakuje, prog = wielkość poziomu.
create or replace function public.kuznia_poziom(xp int) returns jsonb language plpgsql immutable as $$
declare lvl int := 1; baza int := 0; prog int := 150; x int := greatest(coalesce(xp, 0), 0);
begin
  while x >= baza + prog loop
    baza := baza + prog; lvl := lvl + 1;
    prog := round(150 * power(1.25::numeric, lvl - 1))::int;
  end loop;
  return jsonb_build_object('poziom', lvl, 'w_poziomie', x - baza, 'do_nastepnego', baza + prog - x, 'prog', prog,
    'ranga', case when lvl <= 2 then 'Ruda' when lvl <= 4 then 'Żelazo' when lvl <= 8 then 'Stal'
                  when lvl <= 13 then 'Hart' when lvl <= 19 then 'Damast' else 'Legenda' end);
end $$;

-- Zamknięcie dnia – idempotentne: dzień już zamknięty → zapisane podsumowanie bez zmian.
create or replace function public.kuznia_zamknij_dzien(p_date date, p_user uuid default auth.uid())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  st kuznia_stan%rowtype; kd kuznia_dni%rowtype; d jsonb; tryb text; wynik jsonb; b jsonb;
  xp_dnia int; poziom_przed int; poziom_po jsonb; kara int; tarcza boolean := false;
  karne text := null; karne_jutro text := null; pierwsze text; praca_nazwa text; pokonany boolean := false;
  czysty boolean; zaliczony boolean; komunikat text;
  winy text[] := array[
    '[ KUŹNIA ] Kowal wybrał wygodę zamiast ognia. Stal stygnie.',
    '[ KUŹNIA ] Boss tygodnia odzyskuje siły. Ty nie.',
    '[ KUŹNIA ] Słabość odnotowana. Kuźnia pamięta.',
    '[ KUŹNIA ] Żelazo bez ognia rdzewieje.'];
begin
  perform kuznia__sprawdz(p_user);
  insert into kuznia_stan(user_id) values (p_user) on conflict (user_id) do nothing;
  select * into st from kuznia_stan where user_id = p_user for update;   -- jedno zamknięcie naraz na konto
  select * into kd from kuznia_dni where user_id = p_user and date = p_date;
  if kd.zamkniety_at is not null then return kd.podsumowanie; end if;

  tryb := coalesce((select kuznia_tryb from settings where user_id = p_user), 'normal');
  d := kuznia__dzien(p_date, p_user, false);                              -- 1. wynik dnia, odcinki do końca dnia
  czysty := (d->>'czysty')::boolean; zaliczony := (d->>'zaliczony')::boolean;
  xp_dnia := (d->>'xp')::int;
  poziom_przed := (kuznia_poziom(st.xp_suma)->>'poziom')::int;

  if kd.zadanie_karne is not null then                                    -- 2. zadanie karne na ten dzień
    if coalesce(kd.karne_zrobione, false) then karne := 'zrobione';
    else
      karne := 'niezrobione';
      if tryb = 'hard' then st.xp_suma := greatest(0, st.xp_suma - 30); end if;
    end if;
  end if;

  select 5 * count(*) into kara from jsonb_array_elements(d->'zadania') z   -- 3. kara Dyscypliny
   where (z->>'aktywne')::boolean and not (z->>'zrobione')::boolean;

  if zaliczony then                                                        -- 4. seria i tarcza
    st.seria := st.seria + 1;
    if st.seria % 7 = 0 then st.tarcze := 1; end if;
  elsif st.seria > 0 and st.tarcze >= 1 then
    st.tarcze := 0; tarcza := true;
  elsif st.seria > 0 then
    st.seria_utracona := st.seria; st.seria := 0;
  end if;
  st.najdluzsza_seria := greatest(st.najdluzsza_seria, st.seria);

  if tryb = 'hard' and not czysty then                                    -- 5. Hard: zadanie karne na jutro
    select z->>'nazwa' into pierwsze from jsonb_array_elements(d->'zadania') with ordinality x(z, i)
     where (z->>'aktywne')::boolean and not (z->>'zrobione')::boolean order by i limit 1;
    select z->>'nazwa' into praca_nazwa from jsonb_array_elements(d->'zadania') with ordinality x(z, i)
     where z->>'zrodlo' like 'praca:%' order by i limit 1;
    karne_jutro := 'Nadrób: ' || coalesce(pierwsze, 'zadania dnia') || coalesce(' + 1 h ' || praca_nazwa || ' ekstra', '');
    insert into kuznia_dni(user_id, date, zadanie_karne) values (p_user, p_date + 1, karne_jutro)
      on conflict (user_id, date) do update set zadanie_karne = excluded.zadanie_karne
      where kuznia_dni.zamkniety_at is null;
  end if;

  b := d->'boss';                                                          -- 7. boss: rozliczenie w niedzielę
  if jsonb_typeof(b) = 'object' then
    pokonany := extract(isodow from p_date) = 7 and (b->>'hp')::numeric <= 0;
    if pokonany then xp_dnia := xp_dnia + 200; end if;
    b := b || jsonb_build_object('pokonany', pokonany);
  else b := null;
  end if;

  st.xp_suma := st.xp_suma + xp_dnia;                                     -- 6. XP i poziom
  poziom_po := kuznia_poziom(st.xp_suma);

  if st.sezon_start is null then                                          -- 8. sezon 6 tygodni od poniedziałku
    st.sezon_start := p_date - (extract(isodow from p_date)::int - 1);
  end if;
  while p_date >= st.sezon_start + 42 loop
    st.sezon_nr := st.sezon_nr + 1; st.sezon_start := st.sezon_start + 42;
  end loop;

  komunikat := case                                                        -- 9. komunikat Kuźni
    when pokonany then '[ KUŹNIA ] Boss tygodnia pada. Stal Kowala twardnieje.'
    when czysty then '[ KUŹNIA ] Dzień wykuty. Stal twardnieje.'
    else winy[1 + floor(random() * array_length(winy, 1))::int] end;

  wynik := jsonb_build_object(
    'date', p_date, 'xp', xp_dnia, 'czysty', czysty, 'zaliczony', zaliczony, 'tarcza_uzyta', tarcza,
    'kara_dyscyplina', kara, 'seria', st.seria, 'seria_utracona', st.seria_utracona, 'tarcze', st.tarcze,
    'xp_suma', st.xp_suma, 'poziom', (poziom_po->>'poziom')::int, 'ranga', poziom_po->>'ranga',
    'poziom_w_gore', (poziom_po->>'poziom')::int > poziom_przed,
    'zadanie_karne_jutro', karne_jutro, 'karne', karne, 'boss', b, 'sezon_nr', st.sezon_nr, 'komunikat', komunikat);

  insert into kuznia_dni(user_id, date, zadania, xp, xp_stat, czysty, zaliczony, tarcza_uzyta, kara_dyscyplina, zamkniety_at, podsumowanie)
  values (p_user, p_date, d->'zadania', xp_dnia, d->'xp_stat', czysty, zaliczony, tarcza, kara, now(), wynik)
  on conflict (user_id, date) do update set zadania = excluded.zadania, xp = excluded.xp, xp_stat = excluded.xp_stat,
    czysty = excluded.czysty, zaliczony = excluded.zaliczony, tarcza_uzyta = excluded.tarcza_uzyta,
    kara_dyscyplina = excluded.kara_dyscyplina, zamkniety_at = excluded.zamkniety_at, podsumowanie = excluded.podsumowanie;

  update kuznia_stan set xp_suma = st.xp_suma, seria = st.seria, najdluzsza_seria = st.najdluzsza_seria,
    tarcze = st.tarcze, seria_utracona = st.seria_utracona, sezon_nr = st.sezon_nr, sezon_start = st.sezon_start,
    ostatni_zamkniety = greatest(coalesce(st.ostatni_zamkniety, p_date), p_date), updated_at = now()
   where user_id = p_user;
  return wynik;
end $$;

-- Zamyka po kolei dni od ostatni_zamkniety + 1 (albo samo p_do, gdy konto nie ma stanu) do p_do.
create or replace function public.kuznia_zamknij_zalegle(p_do date, p_user uuid default auth.uid())
returns jsonb language plpgsql security definer set search_path = public as $$
declare od date; dzien date; wynik jsonb := '[]'::jsonb;
begin
  perform kuznia__sprawdz(p_user);
  select ostatni_zamkniety + 1 into od from kuznia_stan where user_id = p_user;
  for dzien in select generate_series(coalesce(od, p_do), p_do, interval '1 day')::date loop
    wynik := wynik || jsonb_build_array(kuznia_zamknij_dzien(dzien, p_user));
  end loop;
  return wynik;
end $$;

-- Stan gry teraz: XP, poziom, seria, statystyki z 28 dni, boss tygodnia na żywo, sezon.
create or replace function public.kuznia_stan_teraz(p_user uuid default auth.uid())
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st kuznia_stan%rowtype; dzis date := kuznia__dzis(); p jsonb; staty jsonb := '{}'::jsonb; n text;
  czyste int; kary int; sezon_xp int;
begin
  perform kuznia__sprawdz(p_user);
  select * into st from kuznia_stan where user_id = p_user;
  p := kuznia_poziom(coalesce(st.xp_suma, 0));
  foreach n in array array['Siła','Zwinność','Zdrowie','Pracowitość','Wiedza','Duch','Relacje'] loop
    staty := staty || jsonb_build_object(n, (select least(99, coalesce(sum((xp_stat->>n)::int), 0) / 10)
      from kuznia_dni where user_id = p_user and zamkniety_at is not null and date > dzis - 28 and date <= dzis));
  end loop;
  select count(*) filter (where czysty), coalesce(sum(kara_dyscyplina), 0) into czyste, kary
    from kuznia_dni where user_id = p_user and zamkniety_at is not null and date > dzis - 28 and date <= dzis;
  staty := staty || jsonb_build_object('Dyscyplina', least(99, greatest(0, 50 + 3 * czyste - kary)));
  select coalesce(sum(xp), 0) into sezon_xp from kuznia_dni
   where user_id = p_user and zamkniety_at is not null and date between st.sezon_start and st.sezon_start + 41;
  return p || jsonb_build_object(
    'xp_suma', coalesce(st.xp_suma, 0), 'seria', coalesce(st.seria, 0), 'najdluzsza_seria', coalesce(st.najdluzsza_seria, 0),
    'tarcze', coalesce(st.tarcze, 1), 'seria_utracona', coalesce(st.seria_utracona, 0),
    'ostatni_zamkniety', st.ostatni_zamkniety,
    'tryb', coalesce((select kuznia_tryb from settings where user_id = p_user), 'normal'),
    'statystyki', staty,
    'boss', kuznia__boss(p_user, dzis, true),
    'sezon', jsonb_build_object('nr', coalesce(st.sezon_nr, 1), 'start', st.sezon_start, 'koniec', st.sezon_start + 41,
                                'xp', sezon_xp, 'poziom', sezon_xp / 100));
end $$;

-- ===== Uprawnienia =====
-- Funkcje security definer: anon nie może ich wołać (auth.uid() = null przeszedłby kontrolę „cudze konto”).
revoke all on function public.kuznia_dzien_na_zywo(date, uuid) from public, anon;
revoke all on function public.kuznia_zamknij_dzien(date, uuid) from public, anon;
revoke all on function public.kuznia_zamknij_zalegle(date, uuid) from public, anon;
revoke all on function public.kuznia_stan_teraz(uuid) from public, anon;
grant execute on function public.kuznia_dzien_na_zywo(date, uuid) to authenticated, service_role;
grant execute on function public.kuznia_zamknij_dzien(date, uuid) to authenticated, service_role;
grant execute on function public.kuznia_zamknij_zalegle(date, uuid) to authenticated, service_role;
grant execute on function public.kuznia_stan_teraz(uuid) to authenticated, service_role;
-- Pomocnicze: tylko właściciel (wołane z funkcji wyżej) i rola serwisowa.
revoke all on function public.kuznia__dzis() from public, anon, authenticated;
revoke all on function public.kuznia__koniec(date) from public, anon, authenticated;
revoke all on function public.kuznia__godziny(uuid, text, date, date, boolean) from public, anon, authenticated;
revoke all on function public.kuznia__boss(uuid, date, boolean) from public, anon, authenticated;
revoke all on function public.kuznia__sprawdz(uuid) from public, anon, authenticated;
revoke all on function public.kuznia__dzien(date, uuid, boolean) from public, anon, authenticated;
grant execute on function public.kuznia__dzis(), public.kuznia__koniec(date), public.kuznia__godziny(uuid, text, date, date, boolean),
  public.kuznia__boss(uuid, date, boolean), public.kuznia__sprawdz(uuid), public.kuznia__dzien(date, uuid, boolean) to service_role;

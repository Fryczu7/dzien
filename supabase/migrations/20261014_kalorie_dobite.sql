-- „Kalorie dobite” bez wpisywania posiłków (decyzja Michała 14.10, wieczór).
-- Michał dobija cel codziennie, ale nie zawsze wpisuje jedzenie (weekendy, brak czasu). Dlatego:
--  1. days.kcal_ok – jedno „tak / nie” na dzień (null = nie wiadomo). Ustawia Claude w rozmowie
--     (select public.kalorie_dobite(dzień, true/false)), później przycisk w apce.
--  2. Przypomnienie push o 21:00 (Warszawa), tylko gdy dzień nie jest rozliczony
--     (posiłki < 90% celu i brak „tak / nie”).
--  3. Korekta celu trenera: dzień „dobity” = kcal_ok, a gdy go brak – posiłki ≥ 90% celu.
--     Tempo z trendu: przy ≥ 3 ważeniach z ostatnich 21 dni (rozpiętość ≥ 14 dni) – nachylenie prostej
--     (regresja), przy 2 ważeniach – jak dotąd z dwóch punktów.
--  4. Kuźnia: zadanie „kalorie” zaliczone także przy kcal_ok = true.
-- Kopia: dzien-app/supabase/migrations/20261014_kalorie_dobite.sql

alter table public.days add column if not exists kcal_ok boolean;

-- Zapis „dobite / nie dobite”. Z apki: konto zalogowanego; z Claude (rola serwisowa): konto Michała.
create or replace function public.kalorie_dobite(p_date date, p_ok boolean)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare u uuid := coalesce(auth.uid(), public.coach_owner());
begin
  if p_date is null or p_date > (now() at time zone 'Europe/Warsaw')::date then
    raise exception 'zła data: %', p_date;
  end if;
  insert into public.days (user_id, date, kcal_ok) values (u, p_date, p_ok)
  on conflict (user_id, date) do update set kcal_ok = excluded.kcal_ok, updated_at = now();
  return format('ok kalorie %s: %s', to_char(p_date, 'DD.MM'), case when p_ok then 'dobite' when p_ok = false then 'nie dobite' else 'nie wiadomo' end);
end $$;
revoke all on function public.kalorie_dobite(date, boolean) from public, anon;
grant execute on function public.kalorie_dobite(date, boolean) to authenticated;

-- Przypomnienie wieczorne – dziennik, żeby nie wysłać dwa razy.
create table if not exists public.kalorie_przypomnienia (
  user_id uuid not null references auth.users(id) on delete cascade,
  date date not null,
  tresc text not null,
  wyslano_at timestamptz not null default now(),
  primary key (user_id, date)
);
alter table public.kalorie_przypomnienia enable row level security;
create policy wlasne_odczyt on public.kalorie_przypomnienia for select to authenticated using (user_id = (select auth.uid()));

-- p_teraz tylko do testów. Wysyła o 21:00–21:59 czasu warszawskiego, raz dziennie.
create or replace function public.kalorie_przypomnienie_tick(p_teraz timestamptz default now(), p_wyslij boolean default true)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  u uuid := public.coach_owner();
  lok timestamp := p_teraz at time zone 'Europe/Warsaw';
  dzien date := lok::date;
  cel int;
  zjedzone int;
  ok boolean;
  tresc text;
begin
  if extract(hour from lok) <> 21 then return 'nie pora'; end if;
  if exists (select 1 from public.kalorie_przypomnienia where user_id = u and date = dzien) then return 'już wysłane'; end if;
  select kcal_ok, kcal_target into ok, cel from public.days where user_id = u and date = dzien;
  cel := coalesce(cel, (select kcal_target from public.settings where user_id = u));
  select coalesce(sum(kcal), 0) into zjedzone from public.meals where user_id = u and date = dzien;
  if ok is not null then return 'rozliczone'; end if;
  if zjedzone >= 0.9 * cel then return 'dobite z posiłków'; end if;
  tresc := case when zjedzone > 0
    then format('Zapisane %s z %s kcal. Dobite? Napisz Claude: „dobite” albo „nie”.', zjedzone, cel)
    else format('Dziś bez wpisów. Cel %s kcal – dobite? Napisz Claude: „dobite” albo „nie”.', cel) end;
  insert into public.kalorie_przypomnienia (user_id, date, tresc) values (u, dzien, tresc);
  if p_wyslij then perform public.push_send(u, 'Kalorie dziś', tresc); end if;
  return 'wysłane: ' || tresc;
end $$;
revoke all on function public.kalorie_przypomnienie_tick(timestamptz, boolean) from public, anon, authenticated;

-- pg_cron w UTC: 19:00 i 20:00 UTC; funkcja sama wybiera 21:00 w Warszawie (lato i zima).
select cron.schedule('kalorie-przypomnienie', '0 19,20 * * *', 'select public.kalorie_przypomnienie_tick()');

-- Kuźnia: „kalorie” zaliczone także przy kcal_ok = true (podmiana jednej linii w żywej funkcji).
do $k$
declare d text;
begin
  d := pg_get_functiondef('public.kuznia__dzien(date,uuid,boolean)'::regprocedure);
  if position('or coalesce(dy.kcal_ok, false)' in d) = 0 then
    if position('zrobione := kcal_cel > 0 and kcal::numeric / kcal_cel >= cel;' in d) = 0 then
      raise exception 'kuznia__dzien: nie znalazłem linii z kaloriami';
    end if;
    d := replace(d, 'zrobione := kcal_cel > 0 and kcal::numeric / kcal_cel >= cel;',
                    'zrobione := (kcal_cel > 0 and kcal::numeric / kcal_cel >= cel) or coalesce(dy.kcal_ok, false);');
    execute d;
  end if;
end $k$;

-- Korekta celu: dzień dobity z kcal_ok, tempo z trendu (zastępuje wersję z 20261014_trener_cele.sql).
create or replace function public.trener_korekta_ocena()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  u uuid := public.coach_owner();
  dzis date := (now() at time zone 'Europe/Warsaw')::date;
  s record;
  w1 record;
  w0 record;
  v_dni int;
  v_tempo numeric;
  v_ok int := 0;
  v_wpisy int := 0;
  v_srednia int;
  v_cel int;
  v_kcal int;
  v_bialko int;
  v_kod text;
  v_powod text;
  v_ostatnia_zmiana date;
  v_nowe boolean;
  v_n int;
  v_od date;
  v_trend boolean := false;
  v_tak int := 0;
begin
  select kcal_target, protein_target, korekta into s from public.settings where user_id = u;
  if not found then
    return jsonb_build_object('blad', 'brak settings');
  end if;

  select date, kg into w1 from public.weights where user_id = u order by date desc limit 1;
  if not found then
    return jsonb_build_object('nowe_wazenie', false, 'kod', 'brak_wag',
      'kcal_obecny', s.kcal_target, 'kcal_nowy', s.kcal_target,
      'bialko_obecne', s.protein_target, 'bialko_nowe', s.protein_target,
      'powod', 'Brak ważeń – cel bez zmian.');
  end if;
  select date, kg into w0 from public.weights where user_id = u and date < w1.date order by date desc limit 1;

  v_nowe := s.korekta is null or (s.korekta->>'waga_data') is null or w1.date > (s.korekta->>'waga_data')::date;
  v_ostatnia_zmiana := (s.korekta->>'kcal_zmiana')::date;

  -- Białko: 2,0 g na kg, zaokrąglone do 5 g, 140–220 g.
  v_bialko := least(220, greatest(140, (round(2.0 * w1.kg / 5) * 5)::int));

  -- Jedzenie w 14 dniach przed ostatnim ważeniem (cel dnia: days.kcal_target albo settings).
  -- Dzień dobity = „dobite / nie” od Michała (days.kcal_ok), a gdy go brak – posiłki ≥ 90% celu.
  select count(*) filter (where coalesce(z.ok, z.kcal >= 0.9 * z.cel)),
         count(*) filter (where z.kcal > 0 or z.ok is not null),
         round(avg(z.kcal) filter (where z.kcal > 0))::int,
         round(avg(z.cel))::int
         , count(*) filter (where z.ok)
    into v_ok, v_wpisy, v_srednia, v_cel, v_tak
  from (
    select d::date as dzien,
           coalesce((select sum(m.kcal) from public.meals m where m.user_id = u and m.date = d::date), 0) as kcal,
           coalesce((select dd.kcal_target from public.days dd where dd.user_id = u and dd.date = d::date), s.kcal_target) as cel,
           (select dd.kcal_ok from public.days dd where dd.user_id = u and dd.date = d::date) as ok
    from generate_series(w1.date - 14, w1.date - 1, interval '1 day') d
  ) z;

  v_kcal := s.kcal_target;

  if w0.date is null then
    v_kod := 'jeden_pomiar';
    v_powod := format('Jest jeden pomiar (%s kg, %s) – nie ma jeszcze tempa. Kalorie bez zmian.', replace(w1.kg::text, '.', ','), to_char(w1.date, 'DD.MM'));
  else
    -- Trend: ≥ 3 ważenia z 21 dni do ostatniego, rozpiętość ≥ 14 dni → nachylenie prostej; inaczej dwa ostatnie punkty.
    select count(*), min(date), regr_slope(kg, date - w1.date) into v_n, v_od, v_tempo
    from public.weights where user_id = u and date between w1.date - 21 and w1.date;
    if v_n >= 3 and w1.date - v_od >= 14 then
      v_trend := true;
      v_dni := w1.date - v_od;
      select date, kg into w0 from public.weights where user_id = u and date = v_od;
      v_tempo := round(v_tempo * 7, 2);
    else
      v_dni := w1.date - w0.date;
      v_tempo := round((w1.kg - w0.kg) / v_dni * 7, 2);
    end if;
    if v_dni < 10 then
      v_kod := 'za_krotko';
      v_powod := format('Pomiary tylko %s dni od siebie (%s → %s) – za krótko na ocenę tempa. Kalorie bez zmian.',
        v_dni, to_char(w0.date, 'DD.MM'), to_char(w1.date, 'DD.MM'));
    elsif abs(v_tempo) > 1.0 and v_ok < 10 then
      v_kod := 'niewiarygodny';
      v_powod := format('Waga %s → %s kg w %s dni = %s kg/tydz., a jedzenie poniżej celu (%s z 14 dni ≥ 90%%, średnio %s/%s kcal) – pomiar wygląda na niewiarygodny. Kalorie bez zmian; najpierw dobij obecny cel.',
        replace(w0.kg::text, '.', ','), replace(w1.kg::text, '.', ','), v_dni, replace(v_tempo::text, '.', ','), v_ok, coalesce(v_srednia, 0), v_cel);
    elsif v_ostatnia_zmiana is not null and dzis - v_ostatnia_zmiana < 13 then
      v_kod := 'zmiana_niedawno';
      v_powod := format('Kalorie zmienione %s – jedna zmiana na 2 tygodnie. Bez zmian.', to_char(v_ostatnia_zmiana, 'DD.MM'));
    elsif v_tempo < 0.25 then
      if v_ok >= 10 then
        v_kod := 'podnies';
        v_kcal := least(4500, s.kcal_target + 200);
        v_powod := format('Tempo %s kg/tydz. (< 0,25) przy jedzeniu ≥ 90%% celu w %s z 14 dni – cel +200 kcal: %s → %s.',
          replace(v_tempo::text, '.', ','), v_ok, s.kcal_target, v_kcal);
      else
        v_kod := 'najpierw_dobij';
        v_powod := format('Tempo %s kg/tydz. (< 0,25), ale cel dobity tylko w %s z 14 dni (potrzeba 10). Najpierw dobij obecny cel: średnio %s/%s kcal.',
          replace(v_tempo::text, '.', ','), v_ok, coalesce(v_srednia, 0), v_cel);
      end if;
    elsif v_tempo <= 0.5 then
      v_kod := 'bez_zmian';
      v_powod := format('Tempo %s kg/tydz. – w normie (0,25–0,5). Kalorie bez zmian.', replace(v_tempo::text, '.', ','));
    else
      v_kod := 'obniz';
      v_kcal := greatest(2500, s.kcal_target - 100);
      v_powod := format('Tempo %s kg/tydz. (> 0,5) – cel −100 kcal: %s → %s.', replace(v_tempo::text, '.', ','), s.kcal_target, v_kcal);
    end if;
  end if;

  if v_kod in ('najpierw_dobij', 'niewiarygodny') and v_wpisy < 14 then
    v_powod := v_powod || format(' Dni bez danych: %s z 14 (bez posiłków i bez „dobite”).', 14 - v_wpisy);
  end if;
  if v_trend then
    v_powod := format('Trend z %s ważeń (%s–%s). ', v_n, to_char(v_od, 'DD.MM'), to_char(w1.date, 'DD.MM')) || v_powod;
  end if;
  if v_bialko <> s.protein_target then
    v_powod := v_powod || format(' Białko: 2 g × %s kg = %s g (było %s).', replace(w1.kg::text, '.', ','), v_bialko, s.protein_target);
  end if;

  return jsonb_build_object(
    'nowe_wazenie', v_nowe,
    'kod', v_kod,
    'waga_ost', jsonb_build_object('data', w1.date, 'kg', w1.kg),
    'waga_poprz', case when w0.date is null then null else jsonb_build_object('data', w0.date, 'kg', w0.kg) end,
    'dni', v_dni,
    'tempo_kg_tydz', v_tempo,
    'dni_ok_90', v_ok,
    'dni_z_wpisami', v_wpisy,
    'dni_dobite_z_rozmowy', v_tak,
    'trend', v_trend,
    'wazen_w_trendzie', case when v_trend then v_n else 2 end,
    'srednia_kcal', v_srednia,
    'cel_kcal_okno', v_cel,
    'kcal_obecny', s.kcal_target,
    'kcal_nowy', v_kcal,
    'bialko_obecne', s.protein_target,
    'bialko_nowe', v_bialko,
    'ostatnia_korekta', s.korekta,
    'powod', v_powod
  );
end $$;

revoke all on function public.trener_korekta_ocena() from public, anon, authenticated;

-- Korekta celu kalorii i białka na masie (decyzja Michała 14.10).
-- Trener nocny co noc woła public.trener_korekta_ocena() (tylko odczyt, liczy wszystko w SQL),
-- a gdy jest nowe ważenie od ostatniej korekty – public.trener_set_targets(kcal, białko, powód).
-- Zasady:
--   tempo = zmiana wagi / tydzień między dwoma ostatnimi pomiarami;
--   < 0,25 kg/tydz. → +200 kcal (TYLKO gdy w 14 dniach przed ważeniem ≥ 10 dni z jedzeniem ≥ 90% celu),
--   0,25–0,5 → bez zmian, > 0,5 → −100 kcal; jedna zmiana kcal na 2 tygodnie;
--   pomiary < 10 dni od siebie albo > 1 kg/tydz. przy jedzeniu poniżej celu → kcal bez zmian;
--   białko = 2,0 × ostatnia waga, do 5 g, min. 140 g – przy każdym ważeniu.
-- Twarde granice w funkcji zapisu: kcal 2500–4500, białko 120–220, zmiana kcal maks. ±200.
-- Kopia: dzien-app/supabase/migrations/20261014_trener_cele.sql

-- Ślad ostatniej korekty: {"data": "RRRR-MM-DD", "waga_data": "RRRR-MM-DD", "kcal_zmiana": "RRRR-MM-DD" | null}
alter table public.settings add column if not exists korekta jsonb;

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
  select count(*) filter (where z.kcal >= 0.9 * z.cel),
         count(*) filter (where z.kcal > 0),
         round(avg(z.kcal) filter (where z.kcal > 0))::int,
         round(avg(z.cel))::int
    into v_ok, v_wpisy, v_srednia, v_cel
  from (
    select d::date as dzien,
           coalesce((select sum(m.kcal) from public.meals m where m.user_id = u and m.date = d::date), 0) as kcal,
           coalesce((select dd.kcal_target from public.days dd where dd.user_id = u and dd.date = d::date), s.kcal_target) as cel
    from generate_series(w1.date - 14, w1.date - 1, interval '1 day') d
  ) z;

  v_kcal := s.kcal_target;

  if w0.date is null then
    v_kod := 'jeden_pomiar';
    v_powod := format('Jest jeden pomiar (%s kg, %s) – nie ma jeszcze tempa. Kalorie bez zmian.', replace(w1.kg::text, '.', ','), to_char(w1.date, 'DD.MM'));
  else
    v_dni := w1.date - w0.date;
    v_tempo := round((w1.kg - w0.kg) / v_dni * 7, 2);
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

create or replace function public.trener_set_targets(p_kcal int, p_protein int, p_reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  u uuid := public.coach_owner();
  dzis date := (now() at time zone 'Europe/Warsaw')::date;
  v_kcal int;
  v_bialko int;
  v_korekta jsonb;
  v_waga date;
begin
  if p_kcal is null or p_kcal < 2500 or p_kcal > 4500 then
    raise exception 'kcal poza granicami 2500–4500: %', p_kcal;
  end if;
  if p_protein is null or p_protein < 120 or p_protein > 220 then
    raise exception 'białko poza granicami 120–220: %', p_protein;
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'brak powodu';
  end if;

  select kcal_target, protein_target, korekta into v_kcal, v_bialko, v_korekta
  from public.settings where user_id = u for update;
  if not found then
    raise exception 'brak settings właściciela';
  end if;
  if abs(p_kcal - v_kcal) > 200 then
    raise exception 'zmiana kcal maks. ±200 (jest % → %)', v_kcal, p_kcal;
  end if;

  select max(date) into v_waga from public.weights where user_id = u;

  update public.settings
     set kcal_target = p_kcal,
         protein_target = p_protein,
         korekta = jsonb_build_object(
           'data', dzis,
           'waga_data', v_waga,
           'kcal_zmiana', case when p_kcal <> v_kcal then to_jsonb(dzis) else coalesce(v_korekta->'kcal_zmiana', 'null'::jsonb) end),
         updated_at = now()
   where user_id = u;

  -- Poprzednie wpisy trenera o celu są zastąpione nowym.
  update public.memory
     set status = 'zrobione', updated_at = now()
   where user_id = u and kind = 'decyzja' and title like 'Trener: cel kalorii i białka%' and status = 'otwarte';

  insert into public.memory (user_id, kind, title, body, goal_id, source, status)
  values (u, 'decyzja',
    format('Trener: cel kalorii i białka %s kcal / %s g (od %s)', p_kcal, p_protein, to_char(dzis, 'DD.MM')),
    format('%s: %s kcal → %s kcal, białko %s g → %s g. Powód: %s', dzis, v_kcal, p_kcal, v_bialko, p_protein, p_reason),
    'C5', 'noc', 'otwarte');

  return format('ok cel %s kcal / %s g (było %s / %s)', p_kcal, p_protein, v_kcal, v_bialko);
end $$;

revoke all on function public.trener_korekta_ocena() from public, anon, authenticated;
revoke all on function public.trener_set_targets(int, int, text) from public, anon, authenticated;

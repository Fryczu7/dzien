-- Trener nocny, regularność treningów i podsumowanie obserwacji (decyzje Michała 8.10).
-- 1) Treningi: kalistenika jako osobny rodzaj; status – zrobiony / odwołany (zajęcia odwołane, nie jego wina) / opuszczony.
alter table public.workouts drop constraint workouts_kind_check;
alter table public.workouts add constraint workouts_kind_check check (kind in ('silownia','wspinaczka','kalistenika','bieg','inne'));
alter table public.workouts add column status text not null default 'zrobiony' check (status in ('zrobiony','odwolany','opuszczony'));

-- 2) Minimum treningów w tygodniu (Michał: 3 to minimum, każdy więcej to plus).
alter table public.settings add column training_min integer not null default 3;

-- 3) Coach: wiersz „trener” (trener personalny, co noc 2:00) i „obserwacje” (niedzielne podsumowanie z laptopa).
--    accepted_at: apka pokazuje obserwacje, dopóki Michał ich nie odhaczy (np. po weekendzie poza domem).
alter table public.coach drop constraint coach_kind_check;
alter table public.coach add constraint coach_kind_check check (kind in ('noc','tydzien','miesiac','trener','obserwacje'));
alter table public.coach add column accepted_at timestamptz;

-- Ponowny zapis tego samego dnia i rodzaju znów pokazuje wiersz jako nieprzeczytany.
create or replace function public.coach_save(p_date date, p_kind text, p_morning text, p_report text, p_work jsonb default '[]')
returns text language plpgsql security definer set search_path = public as $$
declare u uuid := public.coach_owner();
begin
  insert into public.coach (user_id, date, kind, morning, report, work)
  values (u, p_date, p_kind, coalesce(p_morning, ''), coalesce(p_report, ''), coalesce(p_work, '[]'::jsonb))
  on conflict (user_id, date, kind) do update
    set morning = excluded.morning, report = excluded.report, work = excluded.work, created_at = now(), accepted_at = null;
  if p_kind = 'noc' then
    insert into public.days (user_id, date, coach_morning) values (u, p_date, p_morning)
    on conflict (user_id, date) do update set coach_morning = excluded.coach_morning;
  end if;
  return 'ok ' || p_kind || ' ' || p_date;
end $$;
revoke all on function public.coach_save(date, text, text, text, jsonb) from public, anon, authenticated;

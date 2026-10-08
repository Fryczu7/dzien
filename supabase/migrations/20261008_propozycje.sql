-- Asystent i coach – dwie osobne role (decyzja Michała 8.10).
-- propozycje: asystent proponuje (plan dnia albo większy pomysł), Michał decyduje: Biorę / Zmień / Nie.
create table public.propozycje (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date date,                                   -- dzień, którego dotyczy (null dla pomysłu)
  kind text not null check (kind in ('dzien','pomysl')),
  title text not null,                         -- co zrobić, max ~8 słów
  why text not null default '',                -- dlaczego, jedno zdanie z liczbą
  detail text not null default '',             -- pełna treść (skrypt, lista, wyliczenia)
  goal_id text,
  status text not null default 'nowa' check (status in ('nowa','wzieta','zmieniona','odrzucona')),
  reply text,                                  -- odpowiedź Michała: powód „Nie” albo jego wersja przy „Zmień”
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index propozycje_user_date on public.propozycje (user_id, date, status);
alter table public.propozycje enable row level security;
create policy wlasne on public.propozycje for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Coach od mentalu: odpowiedź na wieczorny check-in (days.coach_evening). Funkcja, bo konektor pyta o potwierdzenie UPDATE.
create or replace function public.coach_evening_save(p_date date, p_text text)
returns text language plpgsql security definer set search_path = public as $$
declare u uuid := public.coach_owner();
begin
  insert into public.days (user_id, date, coach_evening) values (u, p_date, p_text)
  on conflict (user_id, date) do update set coach_evening = excluded.coach_evening;
  return 'ok ' || p_date;
end $$;
revoke all on function public.coach_evening_save(date, text) from public, anon, authenticated;

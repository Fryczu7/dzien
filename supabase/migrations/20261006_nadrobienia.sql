-- Nadrobienie luki: jedno podsumowanie za kilka dni bez wpisów (do zestawienia tygodnia).
create table public.catchups (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  from_date date not null,
  to_date date not null,
  rehab_count integer,
  training_count integer,
  meds_days integer,
  kcal_ok text check (kcal_ok in ('tak', 'czesciowo', 'nie')),
  sleep_h numeric,
  created_at timestamptz not null default now(),
  check (from_date <= to_date)
);
alter table public.catchups enable row level security;
create policy wlasne on public.catchups for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create index catchups_user_to on public.catchups (user_id, to_date);

-- Dzień zamknięty wieczorem (karta „Zamknij dzień”).
alter table public.days add column closed boolean not null default false;

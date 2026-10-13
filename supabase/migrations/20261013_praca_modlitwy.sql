-- Stoper pracy (decyzja Michała 13.10): jeden stoper, Michał wybiera, do czego leci czas.
-- Każdy odcinek Start→Stop to jeden wiersz; ended_at = null znaczy, że stoper właśnie chodzi.
create table public.praca (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date date not null,                          -- dzień startu (odcinek po północy liczy się do dnia startu)
  kind text not null check (kind in ('getmed','zlap','projekty')),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  check (ended_at is null or ended_at >= started_at)
);
create index praca_user_date on public.praca (user_id, date);
-- Najwyżej jeden chodzący stoper na osobę.
create unique index praca_jeden_chodzi on public.praca (user_id) where ended_at is null;
alter table public.praca enable row level security;
create policy wlasne on public.praca for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Cele czasu pracy w minutach (dzień = pon–pt, tydzień = suma pon–nd).
alter table public.settings add column if not exists work_targets jsonb not null
  default '{"getmed":{"dzien":240,"tydzien":1200},"zlap":{"dzien":60,"tydzien":300}}'::jsonb;

-- Modlitwy do czytania w apce (teksty tylko w bazie – repo apki jest publiczne).
create table public.modlitwy (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null,
  body text not null,
  sort int not null default 100,
  created_at timestamptz not null default now()
);
alter table public.modlitwy enable row level security;
create policy wlasne on public.modlitwy for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

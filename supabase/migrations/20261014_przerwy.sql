-- Przerwy w pracy (decyzja Michała 14.10): przerwa w bazie, żeby telefon i komputer pokazywały to samo.
-- auto = stoper sam stanął po limicie pracy; false = Michał kliknął „Przerwa”. ended_at null = przerwa trwa.
-- Zastosowana w bazie 14.10 (migracja przerwy_stoper).
create table public.przerwy (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  kind text check (kind in ('getmed','zlap','projekty')),   -- do czego wrócić po „Wracam”
  auto boolean not null default false,
  push_stop_at timestamptz,   -- serwer wysłał powiadomienie „przerwa” (Web Push)
  push_end_at timestamptz,    -- serwer wysłał powiadomienie „koniec przerwy”
  created_at timestamptz not null default now(),
  check (ended_at is null or ended_at >= started_at)
);
create index przerwy_user_start on public.przerwy (user_id, started_at);
create unique index przerwy_jedna_trwa on public.przerwy (user_id) where ended_at is null;
alter table public.przerwy enable row level security;
create policy wlasne on public.przerwy for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Ustawienia stopera: limit pracy przed przerwą, zakres przerwy (min) i wybrane dźwięki.
alter table public.settings add column if not exists work_break jsonb not null
  default '{"limit_min":60,"break_min":5,"break_max":15,"sound_stop":"trzy-tony","sound_end":"dwa-tony"}'::jsonb;

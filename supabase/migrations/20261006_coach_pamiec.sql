-- Coach nocny i pamięć (drugi mózg) – spec: docs/superpowers/specs/2026-10-06-coach-nocny-design.md
create table public.memory (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind text not null check (kind in ('zadanie','pomysl','osoba','decyzja','wniosek')),
  title text not null,
  body text not null default '',
  goal_id text,
  links text[] not null default '{}',
  status text not null default 'otwarte' check (status in ('otwarte','zrobione','odrzucone')),
  due date,
  last_touched date not null default ((now() at time zone 'Europe/Warsaw')::date),
  source text not null default 'rozmowa' check (source in ('rozmowa','noc','apka','import')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index memory_user_status on public.memory (user_id, status, last_touched);
alter table public.memory enable row level security;
create policy wlasne on public.memory for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create table public.coach (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date date not null,
  kind text not null check (kind in ('noc','tydzien','miesiac')),
  morning text not null default '',
  report text not null default '',
  work jsonb not null default '[]',
  created_at timestamptz not null default now(),
  unique (user_id, date, kind)
);
alter table public.coach enable row level security;
create policy wlasne on public.coach for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

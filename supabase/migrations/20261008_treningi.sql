-- Treningi: sesja (workouts) + serie (workout_sets) + plany do powtarzania (workout_plans).
-- Wpisuje Claude z rozmowy; apka na razie tylko czyta (widok w kolejnym kroku).

create table public.workouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date date,                       -- null = data nieznana (import historii)
  name text not null,              -- np. „Klatka + triceps”
  kind text not null default 'silownia' check (kind in ('silownia','wspinaczka','bieg','inne')),
  notes text not null default '',
  created_at timestamptz not null default now()
);
create index workouts_user_date on public.workouts (user_id, date desc);

create table public.workout_sets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  workout_id uuid not null references public.workouts(id) on delete cascade,
  exercise text not null,
  set_no integer not null,
  kg numeric,                      -- null = masa ciała
  reps integer,
  rir text,                        -- np. '1-2', '~1'
  warmup boolean not null default false,
  note text not null default ''
);
create index workout_sets_user_ex on public.workout_sets (user_id, exercise);
create index workout_sets_workout on public.workout_sets (workout_id);

create table public.workout_plans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  exercises jsonb not null default '[]'::jsonb,   -- [{"name": "...", "sets": 3, "reps": "8-12", "note": "..."}]
  notes text not null default '',
  updated_at timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['workouts','workout_sets','workout_plans'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy wlasne on public.%I for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t);
  end loop;
end $$;

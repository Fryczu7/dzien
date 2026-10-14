-- Menu na dziś (decyzja Michała 8.10): rano wybór na każdy posiłek – „jak ostatnio”, „z planu”, „nowe”;
-- stałe pozycje (shake, banan, mieszanka studencka) zawsze. Układa automat „CEO menu na dziś” o 5:00,
-- apka pokazuje w zakładce Jedzenie, Michał wybiera opcję i klika „zjadłem” (wpis do meals robi apka).
-- Jeden wiersz na dzień. slots = [{slot, label, time, options:[{name,kcal,protein,src,detail}], chosen, eaten}],
-- chosen = indeks wybranej opcji (null = nie wybrano), stale = [{name,kcal,protein,time}],
-- kupic = [tekst] (czego brakuje do opcji). Kopia tego pliku: dzien-app/supabase/migrations/.
create table public.menu (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date date not null,
  slots jsonb not null default '[]',
  stale jsonb not null default '[]',
  kupic jsonb not null default '[]',
  note text not null default '',          -- jedno zdanie od automatu (np. „dzień treningowy: więcej ryżu”)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, date)
);
alter table public.menu enable row level security;
create policy wlasne on public.menu for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Zapis automatu. Funkcja, bo konektor Supabase pyta o potwierdzenie przy UPDATE / ON CONFLICT,
-- a o 5:00 nie ma kto kliknąć. Nie nadpisuje dnia, w którym Michał już coś wybrał albo zjadł.
create or replace function public.menu_save(p_date date, p_slots jsonb, p_stale jsonb, p_kupic jsonb default '[]', p_note text default '')
returns text language plpgsql security definer set search_path = public as $$
declare u uuid := public.coach_owner(); s jsonb;
begin
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then
    return 'błąd: puste slots';
  end if;
  select slots into s from public.menu where user_id = u and date = p_date;
  if s is not null and exists (
    select 1 from jsonb_array_elements(s) e
    where jsonb_typeof(e->'chosen') = 'number' or coalesce((e->>'eaten')::boolean, false)) then
    return 'pominięto ' || p_date || ' – Michał już wybrał';
  end if;
  insert into public.menu (user_id, date, slots, stale, kupic, note)
  values (u, p_date, p_slots, coalesce(p_stale, '[]'), coalesce(p_kupic, '[]'), coalesce(p_note, ''))
  on conflict (user_id, date) do update
    set slots = excluded.slots, stale = excluded.stale, kupic = excluded.kupic, note = excluded.note, updated_at = now();
  return 'ok menu ' || p_date;
end $$;

revoke all on function public.menu_save(date, jsonb, jsonb, jsonb, text) from public, anon, authenticated;

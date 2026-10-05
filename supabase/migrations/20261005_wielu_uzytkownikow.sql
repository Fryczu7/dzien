-- Wielu użytkowników: każdy wiersz ma właściciela, RLS po auth.uid(), ustawienia w bazie.
-- Istniejące dane (seed z 5.10) przypisujemy do konta Michała. Brak konta = przerwanie migracji (not null).

do $$
declare t text;
begin
  foreach t in array array['days','meals','items','goals','film','rules','notes','weights'] loop
    execute format('alter table public.%I add column user_id uuid references auth.users(id) on delete cascade', t);
    execute format('update public.%I set user_id = (select id from auth.users where email = %L)', t, 'mfryczu@gmail.com');
    execute format('alter table public.%I alter column user_id set not null, alter column user_id set default auth.uid()', t);
    execute format('drop policy owner_all on public.%I', t);
    execute format('create policy wlasne on public.%I for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t);
  end loop;
end $$;

alter table public.days    drop constraint days_pkey,    add primary key (user_id, date);
alter table public.weights drop constraint weights_pkey, add primary key (user_id, date);
alter table public.goals   drop constraint goals_pkey,   add primary key (user_id, id);
alter table public.film    drop constraint film_pkey,    add primary key (user_id, id);
alter table public.rules   drop constraint rules_pkey,   add primary key (user_id, nr);
create index meals_user_date on public.meals (user_id, date);
create index items_user on public.items (user_id);
create index notes_user_created on public.notes (user_id, created_at desc);

alter table public.days alter column kcal_target drop default, alter column protein_target drop default;

drop function public.is_owner();

create table public.settings (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  kcal_target integer not null default 2500,
  protein_target integer not null default 120,
  morning_items jsonb not null default '[]'::jsonb,
  evening_items jsonb not null default '[]'::jsonb,
  quick_meals jsonb not null default '[]'::jsonb,
  weight_start numeric,
  weight_mid numeric,
  weight_goal numeric,
  updated_at timestamptz not null default now()
);
alter table public.settings enable row level security;
create policy wlasne on public.settings for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

insert into public.settings (user_id, kcal_target, protein_target, morning_items, evening_items, quick_meals, weight_start, weight_mid, weight_goal)
select id, 3300, 150,
  '[["lozko","Łóżko pościelone"],["modlitwa","Modlitwa"],["woda","Woda"],["leki","Leki rano (do śniadania)"],["matma","10 min matematyki przed pracą"]]'::jsonb,
  '[["leki_wieczor","Leki wieczorne"],["spac_na_czas","Idę spać przed 0:00"]]'::jsonb,
  '[["Shake (mleko b/l + odżywka + banan)",600,40],["Owsianka 60 g z odżywką",620,47],["3 jajka + pieczywo",600,30],["Kurczak + ryż + warzywa",700,55],["Wrap z kurczakiem",650,45],["Spaghetti z mielonym",750,45],["Płatki ryżowe przed treningiem",350,8],["Kanapki (3 kromki)",500,22]]'::jsonb,
  75, 79, 90
from auth.users where email = 'mfryczu@gmail.com';

-- Nowy użytkownik dostaje ustawienia domyślne.
create function public.nowy_uzytkownik() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.settings (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;
revoke execute on function public.nowy_uzytkownik() from public, anon, authenticated;
create trigger po_rejestracji after insert on auth.users for each row execute function public.nowy_uzytkownik();

-- Zespół agentów (tor 4, 19.11.2026). Układ danych wg tasks/plan-torow-2026-11-18.md
-- („Układ danych w bazie zycie-app”). Dodatkowo: kolumna id w każdej tablicy (panel
-- zapisuje Tak/Nie po id) i klucz unikalny w zuzycie (licznik tokenów robi upsert).
-- RLS włączone bez zasad: piszą tylko klucz serwisowy (rutyny przez konektor, bot
-- Telegram kluczem sb_secret_, licznik tokenów kluczem publicznym przez funkcję zuzycie_wgraj z hasłem – niżej).

create table if not exists public.zespol_agenci (
  id bigint generated always as identity primary key,
  imie text not null unique,
  rola text not null,
  stan text not null default 'stoi'
    check (stan in ('pracuje', 'czeka_na_michala', 'stoi', 'skonczyl')),
  zadanie_teraz text,
  ostatni_krok text,
  nastepny_krok text,
  zaktualizowano timestamptz not null default now()
);

create table if not exists public.zespol_zdarzenia (
  id bigint generated always as identity primary key,
  agent text not null,
  typ text not null check (typ in ('start', 'krok', 'zmiana', 'wynik', 'blad')),
  opis text not null,
  link text,
  tokeny_we bigint,
  tokeny_wy bigint,
  utworzono timestamptz not null default now()
);
create index if not exists zespol_zdarzenia_utworzono on public.zespol_zdarzenia (utworzono desc);
create index if not exists zespol_zdarzenia_agent on public.zespol_zdarzenia (agent, utworzono desc);

create table if not exists public.zespol_akceptacje (
  id bigint generated always as identity primary key,
  agent text not null,
  co text not null,
  dlaczego text,
  opcje jsonb not null default '[]'::jsonb,
  stan text not null default 'czeka' check (stan in ('czeka', 'tak', 'nie')),
  odpowiedz text,
  utworzono timestamptz not null default now()
);
create index if not exists zespol_akceptacje_stan on public.zespol_akceptacje (stan, utworzono desc);

create table if not exists public.zespol_wiadomosci (
  id bigint generated always as identity primary key,
  od text not null,
  "do" text not null,
  temat text not null,
  tresc text not null,
  watek bigint,
  przeczytane boolean not null default false,
  utworzono timestamptz not null default now()
);
create index if not exists zespol_wiadomosci_do on public.zespol_wiadomosci ("do", przeczytane, utworzono desc);

create table if not exists public.zuzycie (
  id bigint generated always as identity primary key,
  zrodlo text not null check (zrodlo in ('pc', 'chmura')),
  sesja text not null,
  model text not null,
  dzien date not null,
  tokeny_we bigint not null default 0,
  tokeny_wy bigint not null default 0,
  cache bigint not null default 0,
  koszt_usd numeric(12, 4),
  unique (zrodlo, sesja, model, dzien)
);
create index if not exists zuzycie_dzien on public.zuzycie (dzien desc);

alter table public.zespol_agenci enable row level security;
alter table public.zespol_zdarzenia enable row level security;
alter table public.zespol_akceptacje enable row level security;
alter table public.zespol_wiadomosci enable row level security;
alter table public.zuzycie enable row level security;

-- Karty startowe (stan 'stoi' do pierwszego przebiegu).
insert into public.zespol_agenci (imie, rola, stan, zadanie_teraz) values
  ('Aleksander Kierownik', 'Kierownik – rozdziela zadania, pilnuje terminów', 'stoi', 'Czeka na pierwszy przebieg'),
  ('Maria Odkrywczyni', 'Szuka stałych zleceń jak Złap Termin i getmed', 'stoi', 'Czeka na pierwszy przebieg'),
  ('Marek Pisarz', 'Pisze szkice maili w Gmailu', 'stoi', 'Czeka na pierwszy przebieg'),
  ('Benjamin Zegarmistrz', 'Mierzy Twoje moce przerobowe', 'stoi', 'Czeka na pierwszy przebieg'),
  ('Leonardo Wynalazca', 'Innowator – usprawnienia zespołu', 'stoi', 'Czeka na pierwszy przebieg'),
  ('Florence Porządna', 'Porządek na dysku – sprząta i pilnuje', 'stoi', 'Co niedzielę 19:00')
on conflict (imie) do nothing;

-- Zmiany stanu przez funkcje (konektor Supabase w rutynie pyta o zgodę przy gołym UPDATE).
create or replace function public.zespol_stan(p_imie text, p_stan text, p_zadanie text default null, p_ostatni text default null, p_nastepny text default null)
returns void language sql security definer set search_path = public as $$
  update public.zespol_agenci set
    stan = p_stan,
    zadanie_teraz = coalesce(p_zadanie, zadanie_teraz),
    ostatni_krok = coalesce(p_ostatni, ostatni_krok),
    nastepny_krok = coalesce(p_nastepny, nastepny_krok),
    zaktualizowano = now()
  where imie = p_imie;
$$;

create or replace function public.zespol_przeczytane(p_imie text)
returns integer language sql security definer set search_path = public as $$
  with u as (
    update public.zespol_wiadomosci set przeczytane = true
    where "do" = p_imie and not przeczytane returning 1)
  select count(*)::int from u;
$$;

revoke all on function public.zespol_stan(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.zespol_przeczytane(text) from public, anon, authenticated;
grant execute on function public.zespol_stan(text, text, text, text, text) to service_role;
grant execute on function public.zespol_przeczytane(text) to service_role;

-- Lokalny licznik tokenów (zespol/narzedzia/licznik_tokenow.py) pisze kluczem publicznym przez tę
-- funkcję; hasło w vault (nazwa 'zuzycie_haslo', tworzone ręcznie: vault.create_secret(...))
-- i lokalnie w ~/.claude/zespol-licznik.env – nigdy w repo.
create or replace function public.zuzycie_wgraj(p_haslo text, p_wiersze jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_haslo is null or p_haslo <> (select decrypted_secret from vault.decrypted_secrets where name = 'zuzycie_haslo' limit 1) then
    raise exception 'złe hasło';
  end if;
  insert into public.zuzycie (zrodlo, sesja, model, dzien, tokeny_we, tokeny_wy, cache, koszt_usd)
  select coalesce(w->>'zrodlo', 'pc'), w->>'sesja', w->>'model', (w->>'dzien')::date,
         coalesce((w->>'tokeny_we')::bigint, 0), coalesce((w->>'tokeny_wy')::bigint, 0),
         coalesce((w->>'cache')::bigint, 0), (w->>'koszt_usd')::numeric
  from jsonb_array_elements(p_wiersze) w
  on conflict (zrodlo, sesja, model, dzien) do update set
    tokeny_we = excluded.tokeny_we, tokeny_wy = excluded.tokeny_wy,
    cache = excluded.cache, koszt_usd = excluded.koszt_usd;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.zuzycie_wgraj(text, jsonb) from public;
grant execute on function public.zuzycie_wgraj(text, jsonb) to anon, service_role;

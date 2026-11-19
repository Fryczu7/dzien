-- Zespół agentów: kontakty z firmami (CV na etat + oferta stałych zleceń) i każda wiadomość w obie strony.
-- Panel liczy z tego: wysłane, odpowiedzi, rozmowy, % odpowiedzi – osobno dla lejka 'etat' i 'zlecenia'.

create table if not exists public.zespol_kontakty (
  id bigint generated always as identity primary key,
  lejek text not null check (lejek in ('etat', 'zlecenia')),
  firma text not null,
  osoba text,
  kanal text not null check (kanal in ('mail', 'linkedin', 'instagram')),
  adres text,                 -- e-mail, link do profilu LinkedIn / Instagram
  zrodlo text,                -- link do ogłoszenia albo strony firmy
  agent text not null,        -- kto prowadzi kontakt (imię z zespol_agenci)
  stan text not null default 'do_wyslania' check (stan in (
    'do_wyslania', 'wyslane', 'odpowiedz', 'rozmowa', 'oferta', 'odmowa', 'brak_odpowiedzi', 'nie_pisac')),
  wyslano timestamptz,
  ostatnia_odpowiedz timestamptz,
  nastepny_kontakt date,      -- kiedy przypomnieć się / odpisać
  notatka text,
  utworzono timestamptz not null default now(),
  zaktualizowano timestamptz not null default now()
);

create table if not exists public.zespol_kontakty_wiadomosci (
  id bigint generated always as identity primary key,
  kontakt_id bigint not null references public.zespol_kontakty(id) on delete cascade,
  kierunek text not null check (kierunek in ('wyslana', 'odebrana')),
  kanal text not null check (kanal in ('mail', 'linkedin', 'instagram')),
  temat text,
  tresc text not null,
  agent text,                 -- kto wysłał (dla 'wyslana')
  ocena_michala text check (ocena_michala in ('dobra', 'zla')),  -- filtr Michała na starcie
  uwaga_michala text,
  utworzono timestamptz not null default now()
);

create index if not exists zespol_kontakty_lejek_stan on public.zespol_kontakty (lejek, stan);
create index if not exists zespol_kontakty_nastepny on public.zespol_kontakty (nastepny_kontakt) where stan not in ('odmowa', 'nie_pisac');
create index if not exists zespol_kontakty_wiad_kontakt on public.zespol_kontakty_wiadomosci (kontakt_id, utworzono);

alter table public.zespol_kontakty enable row level security;
alter table public.zespol_kontakty_wiadomosci enable row level security;

-- Zmiana stanu kontaktu bez gołego UPDATE (konektor w rutynie pyta o zgodę przy UPDATE).
create or replace function public.zespol_kontakt_stan(
  p_id bigint, p_stan text, p_nastepny date default null, p_notatka text default null)
returns void language sql security definer set search_path = public as $$
  update public.zespol_kontakty set
    stan = p_stan,
    wyslano = case when p_stan = 'wyslane' and wyslano is null then now() else wyslano end,
    ostatnia_odpowiedz = case when p_stan in ('odpowiedz', 'rozmowa', 'oferta', 'odmowa') then now() else ostatnia_odpowiedz end,
    nastepny_kontakt = coalesce(p_nastepny, nastepny_kontakt),
    notatka = coalesce(p_notatka, notatka),
    zaktualizowano = now()
  where id = p_id;
$$;

-- Liczby do panelu: jeden wiersz na lejek.
create or replace view public.zespol_kontakty_liczby as
select lejek,
  count(*) filter (where stan <> 'do_wyslania') as wyslane,
  count(*) filter (where stan in ('odpowiedz', 'rozmowa', 'oferta', 'odmowa')) as odpowiedzi,
  count(*) filter (where stan in ('rozmowa', 'oferta')) as rozmowy,
  count(*) filter (where stan = 'oferta') as oferty,
  round(100.0 * count(*) filter (where stan in ('odpowiedz', 'rozmowa', 'oferta', 'odmowa'))
    / nullif(count(*) filter (where stan <> 'do_wyslania'), 0), 1) as procent_odpowiedzi
from public.zespol_kontakty
group by lejek;

alter view public.zespol_kontakty_liczby set (security_invoker = true);

-- Tylko klucz serwisowy / konektor (jak zespol_stan).
revoke execute on function public.zespol_kontakt_stan(bigint, text, date, text) from public, anon, authenticated;

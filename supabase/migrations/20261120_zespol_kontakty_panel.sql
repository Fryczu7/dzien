-- Kontakty z firmami: dane dla panelu zespołu (prośba czatu panelu, 20.11).
-- branza, ocena_social 0–10, reklamy (tak/nie) wypełnia Maria Odkrywczyni;
-- stan 'umowa' + kwota (zł) ustawia Dale Rozmówca.

alter table public.zespol_kontakty
  add column if not exists branza text,
  add column if not exists ocena_social smallint check (ocena_social between 0 and 10),
  add column if not exists reklamy boolean,
  add column if not exists kwota numeric(10, 2) check (kwota >= 0);

alter table public.zespol_kontakty drop constraint if exists zespol_kontakty_stan_check;
alter table public.zespol_kontakty add constraint zespol_kontakty_stan_check check (stan in (
  'do_wyslania', 'wyslane', 'odpowiedz', 'rozmowa', 'oferta', 'umowa',
  'odmowa', 'brak_odpowiedzi', 'nie_pisac'));

-- Zmiana stanu: nowy parametr p_kwota (stare wywołania z 2–4 argumentami działają dalej).
drop function if exists public.zespol_kontakt_stan(bigint, text, date, text);
create function public.zespol_kontakt_stan(
  p_id bigint, p_stan text, p_nastepny date default null, p_notatka text default null,
  p_kwota numeric default null)
returns void language sql security definer set search_path = public as $$
  update public.zespol_kontakty set
    stan = p_stan,
    wyslano = case when p_stan = 'wyslane' and wyslano is null then now() else wyslano end,
    ostatnia_odpowiedz = case when p_stan in ('odpowiedz', 'rozmowa', 'oferta', 'umowa', 'odmowa') then now() else ostatnia_odpowiedz end,
    nastepny_kontakt = coalesce(p_nastepny, nastepny_kontakt),
    notatka = coalesce(p_notatka, notatka),
    kwota = coalesce(p_kwota, kwota),
    zaktualizowano = now()
  where id = p_id;
$$;
revoke execute on function public.zespol_kontakt_stan(bigint, text, date, text, numeric) from public, anon, authenticated;

-- Liczby lejka: 'umowa' liczy się jako odpowiedź, rozmowa i oferta; nowe kolumny na końcu.
create or replace view public.zespol_kontakty_liczby with (security_invoker = true) as
select
  lejek,
  count(*) filter (where stan <> 'do_wyslania') as wyslane,
  count(*) filter (where stan in ('odpowiedz', 'rozmowa', 'oferta', 'umowa', 'odmowa')) as odpowiedzi,
  count(*) filter (where stan in ('rozmowa', 'oferta', 'umowa')) as rozmowy,
  count(*) filter (where stan in ('oferta', 'umowa')) as oferty,
  round(100.0 * count(*) filter (where stan in ('odpowiedz', 'rozmowa', 'oferta', 'umowa', 'odmowa'))
    / nullif(count(*) filter (where stan <> 'do_wyslania'), 0), 1) as procent_odpowiedzi,
  count(*) filter (where stan = 'umowa') as umowy,
  coalesce(sum(kwota) filter (where stan = 'umowa'), 0) as kwota_umow
from public.zespol_kontakty
group by lejek;

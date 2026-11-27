-- Automaty – nasz „Zapier” w bazie (tor A, 27.11.2026).
-- Projekt i kontrakt: CEO docs/superpowers/specs/2026-11-27-automaty-design.md.
-- „Gdy X → sprawdź Y → zrób Z”: zdarzenia wpadają do automaty_zdarzenia (wyzwalacze w bazie,
-- most Gmail), pg_cron co minutę woła automaty_tick(), który dla każdego włączonego automatu
-- z pasującym `gdy` sprawdza warunki, wykonuje kroki i zapisuje przebieg.
-- Dostęp jak w tablicach zespol_*: RLS włączone bez zasad (pisze tylko klucz serwisowy /
-- konektor), funkcje security definer bez prawa wykonania dla public/anon/authenticated.
-- Jak dodać automat i katalog kroków: repo zespol, automaty/README.md.

-- ============================================================ tablice

create table if not exists public.automaty (
  id bigserial primary key,
  nazwa text not null unique,
  opis text,                                   -- 1 zdanie po ludzku (panel)
  wlaczony boolean not null default false,
  gdy text not null,                           -- typ zdarzenia
  warunki jsonb not null default '[]'::jsonb,  -- lista warunków (wszystkie muszą być spełnione)
  kroki jsonb not null,                        -- lista kroków po kolei
  utworzono timestamptz not null default now(),
  zaktualizowano timestamptz not null default now()
);

create table if not exists public.automaty_zdarzenia (
  id bigserial primary key,
  typ text not null,
  zrodlo text not null check (zrodlo in ('gmail', 'baza', 'cron', 'reczne')),
  dane jsonb not null default '{}'::jsonb,
  utworzono timestamptz not null default now(),
  obsluzono timestamptz
);
create index if not exists automaty_zdarzenia_czeka on public.automaty_zdarzenia (id) where obsluzono is null;
create index if not exists automaty_zdarzenia_typ on public.automaty_zdarzenia (typ, utworzono desc);
create index if not exists automaty_zdarzenia_kontakt on public.automaty_zdarzenia ((dane->>'kontakt_id'), id desc)
  where typ = 'mail_przyszedl';
-- Most Gmail nie zapisze dwa razy tego samego maila (prośba toru B).
create unique index if not exists automaty_zdarzenia_gmail_id on public.automaty_zdarzenia ((dane->>'gmail_id'))
  where typ = 'mail_przyszedl';

create table if not exists public.automaty_przebiegi (
  id bigserial primary key,
  automat_id bigint not null references public.automaty(id) on delete cascade,
  zdarzenie_id bigint references public.automaty_zdarzenia(id) on delete set null,
  stan text not null check (stan in ('ok', 'pominiety', 'blad')),
  kroki_wynik jsonb not null default '[]'::jsonb,   -- lista {krok, ok, opis}
  utworzono timestamptz not null default now()
);
create index if not exists automaty_przebiegi_utworzono on public.automaty_przebiegi (utworzono desc);
create index if not exists automaty_przebiegi_automat on public.automaty_przebiegi (automat_id, utworzono desc);

create table if not exists public.automaty_akcje (
  id bigserial primary key,
  przebieg_id bigint references public.automaty_przebiegi(id) on delete set null,
  typ text not null,                            -- 'gmail_wyslij' | 'gmail_archiwizuj' | …
  dane jsonb not null default '{}'::jsonb,
  stan text not null default 'czeka' check (stan in ('czeka', 'w_toku', 'zrobione', 'blad')),
  wynik jsonb,
  utworzono timestamptz not null default now(),
  zrobiono timestamptz
);
create index if not exists automaty_akcje_stan on public.automaty_akcje (stan, id);
-- Twarda bariera przeciw podwójnej wysyłce: jedna akcja gmail_wyslij na jeden szkic, na zawsze.
create unique index if not exists automaty_akcje_jedna_wysylka on public.automaty_akcje ((dane->>'wiadomosc_id'))
  where typ = 'gmail_wyslij';

alter table public.automaty enable row level security;
alter table public.automaty_zdarzenia enable row level security;
alter table public.automaty_przebiegi enable row level security;
alter table public.automaty_akcje enable row level security;

-- ============================================================ pomocnicze

-- Typy zdarzeń, na które może czekać automat (nowy typ = dopisz tu i w README).
create or replace function public.automaty_typy_zdarzen()
returns text[] language sql immutable as $$
  select array['mail_przyszedl', 'kontakt_dodany', 'szkic_oceniony', 'akcja_wykonana', 'reczne']
$$;

-- Wartość z kontekstu po ścieżce „a.b.c”; gdy brak – szuka w kontekst.dane (skrót {{temat}}).
create or replace function public.automaty_wartosc(p_ctx jsonb, p_sciezka text)
returns jsonb language sql immutable as $$
  select coalesce(
    nullif(p_ctx #> string_to_array(p_sciezka, '.'), 'null'::jsonb),
    nullif(p_ctx -> 'dane' #> string_to_array(p_sciezka, '.'), 'null'::jsonb))
$$;

create or replace function public.automaty_tekst(p_ctx jsonb, p_sciezka text)
returns text language sql immutable as $$
  select case jsonb_typeof(v) when 'string' then v #>> '{}' else v::text end
  from (select public.automaty_wartosc(p_ctx, p_sciezka) as v) x
$$;

-- Podstawienia {{pole}} w tekście; brak wartości = pusty tekst.
create or replace function public.automaty_podstaw(p_tekst text, p_ctx jsonb)
returns text language plpgsql immutable as $$
declare
  v_wynik text := p_tekst;
  v_pole text;
  v_wart text;
begin
  if p_tekst is null then return null; end if;
  for v_pole in select distinct (regexp_matches(p_tekst, '\{\{\s*([A-Za-z0-9_.]+)\s*\}\}', 'g'))[1] loop
    v_wart := coalesce(public.automaty_tekst(p_ctx, v_pole), '');
    v_wynik := regexp_replace(v_wynik,
      '\{\{\s*' || replace(v_pole, '.', '\.') || '\s*\}\}',
      replace(v_wart, '\', '\\'), 'g');
  end loop;
  return v_wynik;
end $$;

-- Podstawienia w całym jsonie (dane akcji). Wartość dokładnie "{{pole}}" zachowuje typ (liczba, lista).
create or replace function public.automaty_podstaw_json(p_j jsonb, p_ctx jsonb)
returns jsonb language plpgsql immutable as $$
declare
  v_pole text;
begin
  case jsonb_typeof(p_j)
    when 'string' then
      v_pole := substring(p_j #>> '{}' from '^\{\{\s*([A-Za-z0-9_.]+)\s*\}\}$');
      if v_pole is not null then
        return coalesce(public.automaty_wartosc(p_ctx, v_pole), 'null'::jsonb);
      end if;
      return to_jsonb(public.automaty_podstaw(p_j #>> '{}', p_ctx));
    when 'object' then
      return coalesce((select jsonb_object_agg(key, public.automaty_podstaw_json(value, p_ctx))
                       from jsonb_each(p_j)), '{}'::jsonb);
    when 'array' then
      return coalesce((select jsonb_agg(public.automaty_podstaw_json(value, p_ctx) order by o)
                       from jsonb_array_elements(p_j) with ordinality e(value, o)), '[]'::jsonb);
    else
      return p_j;
  end case;
end $$;

-- Adresy e-mail zapisane w polu adres kontaktu (bywa kilka, bywa link zamiast maila).
create or replace function public.automaty_maile(p_adres text)
returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct lower(m[1])), '{}')
  from regexp_matches(coalesce(p_adres, ''), '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})', 'g') m
$$;

-- Domeny poczty ogólnej: po nich nie dopasowujemy firmy, tylko po pełnym adresie.
create or replace function public.automaty_domena_ogolna(p_domena text)
returns boolean language sql immutable as $$
  select lower(p_domena) = any (array['gmail.com', 'googlemail.com', 'wp.pl', 'o2.pl', 'onet.pl', 'onet.eu',
    'op.pl', 'vp.pl', 'interia.pl', 'interia.eu', 'poczta.fm', 'gazeta.pl', 'tlen.pl', 'int.pl', 'spoko.pl',
    'outlook.com', 'outlook.pl', 'hotmail.com', 'live.com', 'yahoo.com', 'icloud.com', 'me.com',
    'proton.me', 'protonmail.com', 'aol.com', 'gmx.com', 'gmx.net'])
$$;

-- Kontakt z zespol_kontakty pasujący do nadawcy maila („Firma <biuro@firma.pl>” albo sam adres).
-- Najpierw pełny adres, potem domena firmy (także poddomena i domena z linku w polu adres).
create or replace function public.automaty_kontakt_nadawcy(p_od text)
returns bigint language sql stable security definer set search_path = public as $$
  with n as (
    select e, split_part(e, '@', 2) as dom
    from (select lower(substring(coalesce(p_od, '') from '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')) as e) x
    where e is not null
  ), k as (
    select k.id, k.zaktualizowano,
      public.automaty_maile(k.adres) as maile,
      case when k.adres !~ '@' then
        lower(substring(k.adres from '^\s*(?:https?://)?(?:www\.)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})'))
      end as dom_linku
    from public.zespol_kontakty k
    where k.adres is not null
  )
  select k.id
  from k, n
  where n.e = any (k.maile)
     or (not public.automaty_domena_ogolna(n.dom) and (
           exists (select 1 from unnest(k.maile) m
                   where not public.automaty_domena_ogolna(split_part(m, '@', 2))
                     and (n.dom = split_part(m, '@', 2) or n.dom like '%.' || split_part(m, '@', 2)))
        or (k.dom_linku is not null and (n.dom = k.dom_linku or n.dom like '%.' || k.dom_linku))))
  order by (n.e = any (k.maile)) desc, k.zaktualizowano desc, k.id desc
  limit 1
$$;

-- Kontekst przebiegu: zdarzenie, jego dane, kontakt (z polem email), szkic, wątek Gmaila kontaktu.
create or replace function public.automaty_kontekst(p_z public.automaty_zdarzenia)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_ctx jsonb;
  v_kontakt bigint;
  v_wiad bigint;
  v_k jsonb;
begin
  v_ctx := jsonb_build_object(
    'zdarzenie', jsonb_build_object('id', p_z.id, 'typ', p_z.typ, 'zrodlo', p_z.zrodlo, 'utworzono', p_z.utworzono),
    'dane', coalesce(p_z.dane, '{}'::jsonb));
  v_kontakt := case
    when p_z.typ = 'kontakt_dodany' then (p_z.dane->>'id')::bigint
    when p_z.dane ? 'kontakt_id' then (p_z.dane->>'kontakt_id')::bigint
    when p_z.typ = 'mail_przyszedl' then public.automaty_kontakt_nadawcy(p_z.dane->>'od')
  end;
  if v_kontakt is not null then
    select to_jsonb(k) || jsonb_build_object('email', (public.automaty_maile(k.adres))[1])
      into v_k from public.zespol_kontakty k where k.id = v_kontakt;
    if v_k is not null then
      v_ctx := v_ctx || jsonb_build_object('kontakt', v_k,
        'watek_id', (select z.dane->>'watek_id' from public.automaty_zdarzenia z
                     where z.typ = 'mail_przyszedl' and z.dane->>'kontakt_id' = v_kontakt::text
                       and z.dane->>'watek_id' is not null
                     order by z.id desc limit 1));
    end if;
  end if;
  v_wiad := (p_z.dane->>'wiadomosc_id')::bigint;
  if v_wiad is not null then
    v_ctx := v_ctx || jsonb_build_object('wiadomosc',
      (select to_jsonb(w) from public.zespol_kontakty_wiadomosci w where w.id = v_wiad));
  end if;
  return v_ctx;
end $$;

-- ============================================================ warunki

create or replace function public.automaty_warunek(p_w jsonb, p_ctx jsonb)
returns boolean language plpgsql stable as $$
declare
  v_typ text := p_w->>'typ';
  v_wart text;
  v_wzorce text[];
begin
  case v_typ
    when 'nadawca_jest_kontaktem' then
      return coalesce(jsonb_typeof(p_ctx->'kontakt') = 'object', false);
    when 'pole_pasuje' then
      v_wart := public.automaty_tekst(p_ctx, p_w->>'pole');
      v_wzorce := case jsonb_typeof(p_w->'wzorzec')
        when 'array' then array(select jsonb_array_elements_text(p_w->'wzorzec'))
        else array[p_w->>'wzorzec'] end;
      return v_wart is not null and exists (select 1 from unnest(v_wzorce) w where v_wart ~* w);
    when 'pole_rowne' then
      return public.automaty_tekst(p_ctx, p_w->>'pole') is not distinct from (p_w->>'wartosc');
    when 'pole_puste' then
      return coalesce(public.automaty_tekst(p_ctx, p_w->>'pole'), '') = '';
    when 'ocena_rowna' then
      return coalesce(coalesce(p_ctx->'dane'->>'ocena', p_ctx->'wiadomosc'->>'ocena_michala') = p_w->>'ocena', false);
    when 'nie' then
      return not coalesce(public.automaty_warunek(p_w->'warunek', p_ctx), false);
    when 'wszystkie' then
      return not exists (select 1 from jsonb_array_elements(p_w->'warunki') w
                         where not coalesce(public.automaty_warunek(w, p_ctx), false));
    when 'ktorykolwiek' then
      return exists (select 1 from jsonb_array_elements(p_w->'warunki') w
                     where public.automaty_warunek(w, p_ctx));
    else
      raise exception 'nieznany warunek: %', coalesce(v_typ, '(brak typ)');
  end case;
end $$;

-- ============================================================ blokada wysyłki

-- Zwraca null, gdy wysyłka szkicu jest dozwolona, inaczej powód. Wysyłka maila do ludzi tylko
-- po ocenie „dobra” Michała przy tym konkretnym szkicu, raz (spec: „Wysyłka maili do ludzi”).
create or replace function public.automaty_wysylka_powod_odmowy(p_przebieg_id bigint, p_wiadomosc_id bigint)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_z public.automaty_zdarzenia;
  v_w public.zespol_kontakty_wiadomosci;
begin
  if p_przebieg_id is null then
    return 'gmail_wyslij tylko z przebiegu automatu po ocenie Michała';
  end if;
  select z.* into v_z from public.automaty_przebiegi p
    join public.automaty_zdarzenia z on z.id = p.zdarzenie_id where p.id = p_przebieg_id;
  if v_z.id is null or v_z.typ <> 'szkic_oceniony' then
    return 'gmail_wyslij dozwolone tylko po zdarzeniu szkic_oceniony (jest: ' || coalesce(v_z.typ, 'brak') || ')';
  end if;
  if coalesce(v_z.dane->>'ocena', '') <> 'dobra' then
    return 'ocena Michała nie jest „dobra” (jest: ' || coalesce(v_z.dane->>'ocena', 'brak') || ')';
  end if;
  if p_wiadomosc_id is null or (v_z.dane->>'wiadomosc_id')::bigint is distinct from p_wiadomosc_id then
    return 'akcja dotyczy innego szkicu niż oceniony';
  end if;
  select * into v_w from public.zespol_kontakty_wiadomosci where id = p_wiadomosc_id;
  if v_w.id is null then return 'nie ma szkicu ' || p_wiadomosc_id; end if;
  if v_w.kierunek <> 'wyslana' then return 'to nie jest szkic do wysłania (kierunek ' || v_w.kierunek || ')'; end if;
  if v_w.ocena_michala is distinct from 'dobra' then return 'szkic nie ma dziś oceny „dobra”'; end if;
  if v_w.wyslano is not null then return 'szkic już wysłany ' || v_w.wyslano; end if;
  if exists (select 1 from public.automaty_akcje a
             where a.typ = 'gmail_wyslij' and a.dane->>'wiadomosc_id' = p_wiadomosc_id::text) then
    return 'wysyłka tego szkicu już zlecona (akcja istnieje)';
  end if;
  return null;
end $$;

-- Ta sama blokada na samej tablicy: także ręczny insert akcji gmail_wyslij przechodzi przez nią.
create or replace function public.automaty_akcje_straznik()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_powod text;
begin
  if new.typ = 'gmail_wyslij' then
    v_powod := public.automaty_wysylka_powod_odmowy(new.przebieg_id, (new.dane->>'wiadomosc_id')::bigint);
    if v_powod is not null then
      raise exception 'blokada gmail_wyslij: %', v_powod;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists automaty_akcje_straznik on public.automaty_akcje;
create trigger automaty_akcje_straznik before insert on public.automaty_akcje
  for each row execute function public.automaty_akcje_straznik();

-- ============================================================ walidacja automatu

create or replace function public.automaty_waliduj_warunek(p_w jsonb)
returns void language plpgsql immutable as $$
declare
  v jsonb;
begin
  if jsonb_typeof(p_w) <> 'object' then raise exception 'warunek musi być obiektem: %', p_w; end if;
  case p_w->>'typ'
    when 'nadawca_jest_kontaktem' then null;
    when 'pole_pasuje' then
      if p_w->>'pole' is null or p_w->'wzorzec' is null then raise exception 'pole_pasuje wymaga pole i wzorzec'; end if;
    when 'pole_rowne' then
      if p_w->>'pole' is null or not p_w ? 'wartosc' then raise exception 'pole_rowne wymaga pole i wartosc'; end if;
    when 'pole_puste' then
      if p_w->>'pole' is null then raise exception 'pole_puste wymaga pole'; end if;
    when 'ocena_rowna' then
      if p_w->>'ocena' not in ('dobra', 'zla') then raise exception 'ocena_rowna: ocena dobra albo zla'; end if;
    when 'nie' then perform public.automaty_waliduj_warunek(p_w->'warunek');
    when 'wszystkie', 'ktorykolwiek' then
      if jsonb_typeof(p_w->'warunki') <> 'array' then raise exception '% wymaga listy warunki', p_w->>'typ'; end if;
      for v in select jsonb_array_elements(p_w->'warunki') loop perform public.automaty_waliduj_warunek(v); end loop;
    else raise exception 'nieznany warunek: %', coalesce(p_w->>'typ', '(brak typ)');
  end case;
end $$;

create or replace function public.automaty_waliduj()
returns trigger language plpgsql as $$
declare
  v jsonb;
begin
  if not (new.gdy = any (public.automaty_typy_zdarzen())) then
    raise exception 'nieznany typ zdarzenia w gdy: % (znane: %)', new.gdy, public.automaty_typy_zdarzen();
  end if;
  if jsonb_typeof(new.warunki) <> 'array' then raise exception 'warunki muszą być listą'; end if;
  for v in select jsonb_array_elements(new.warunki) loop perform public.automaty_waliduj_warunek(v); end loop;
  if jsonb_typeof(new.kroki) <> 'array' or jsonb_array_length(new.kroki) = 0 then
    raise exception 'kroki muszą być niepustą listą';
  end if;
  for v in select jsonb_array_elements(new.kroki) loop
    case v->>'typ'
      when 'powiadom' then
        if v->>'tytul' is null then raise exception 'powiadom wymaga tytul'; end if;
      when 'wiadomosc_do_agenta' then
        if v->>'do' is null or v->>'temat' is null or v->>'tresc' is null then
          raise exception 'wiadomosc_do_agenta wymaga do, temat, tresc';
        end if;
      when 'stan_kontaktu' then
        if v->>'stan' is null then raise exception 'stan_kontaktu wymaga stan'; end if;
      when 'zapisz_wiadomosc_firmy' then null;
      when 'akcja' then
        if v->>'akcja' is null then raise exception 'krok akcja wymaga pola akcja'; end if;
        if v->>'akcja' = 'gmail_wyslij' and new.gdy <> 'szkic_oceniony' then
          raise exception 'gmail_wyslij dozwolone tylko w automacie gdy = szkic_oceniony';
        end if;
      else raise exception 'nieznany krok: %', coalesce(v->>'typ', '(brak typ)');
    end case;
  end loop;
  new.zaktualizowano := now();
  return new;
end $$;
drop trigger if exists automaty_waliduj on public.automaty;
create trigger automaty_waliduj before insert or update on public.automaty
  for each row execute function public.automaty_waliduj();

-- ============================================================ kroki

-- Wykonuje jeden krok. Zwraca {opis, ctx} – ctx to dopiski do kontekstu dla kolejnych kroków.
create or replace function public.automaty_krok(p_k jsonb, p_ctx jsonb, p_przebieg_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_typ text := p_k->>'typ';
  v_id bigint;
  v_txt1 text;
  v_txt2 text;
  v_user uuid;
  v_dane jsonb;
  v_powod text;
begin
  case v_typ
    when 'powiadom' then
      v_txt1 := left(public.automaty_podstaw(p_k->>'tytul', p_ctx), 80);
      v_txt2 := left(coalesce(public.automaty_podstaw(p_k->>'tresc', p_ctx), ''), 300);
      if coalesce((p_k->>'na_sucho')::boolean, false) then
        return jsonb_build_object('opis', 'push na sucho: ' || v_txt1 || ' | ' || v_txt2);
      end if;
      select id into v_user from auth.users where email = 'mfryczu@gmail.com';
      if v_user is null then raise exception 'nie ma konta Michała w auth.users'; end if;
      perform public.push_send(v_user, v_txt1, v_txt2);
      return jsonb_build_object('opis', 'push: ' || v_txt1);
    when 'wiadomosc_do_agenta' then
      v_txt1 := public.automaty_podstaw(p_k->>'do', p_ctx);
      if not exists (select 1 from public.zespol_agenci where imie = v_txt1) then
        raise exception 'nie ma agenta „%” w zespol_agenci', v_txt1;
      end if;
      insert into public.zespol_wiadomosci (od, "do", temat, tresc)
      values (coalesce(p_k->>'od', 'Automaty'), v_txt1,
              public.automaty_podstaw(p_k->>'temat', p_ctx), public.automaty_podstaw(p_k->>'tresc', p_ctx))
      returning id into v_id;
      return jsonb_build_object('opis', 'wiadomość ' || v_id || ' do ' || v_txt1);
    when 'stan_kontaktu' then
      v_id := coalesce(nullif(public.automaty_podstaw(p_k->>'kontakt_id', p_ctx), '')::bigint,
                       (p_ctx->'kontakt'->>'id')::bigint);
      if v_id is null then raise exception 'stan_kontaktu: brak kontaktu w zdarzeniu'; end if;
      perform public.zespol_kontakt_stan(v_id, p_k->>'stan', null::date,
                                         public.automaty_podstaw(p_k->>'notatka', p_ctx));
      return jsonb_build_object('opis', 'kontakt ' || v_id || ' → ' || (p_k->>'stan'));
    when 'zapisz_wiadomosc_firmy' then
      v_id := (p_ctx->'kontakt'->>'id')::bigint;
      if v_id is null then raise exception 'zapisz_wiadomosc_firmy: nadawca nie jest kontaktem'; end if;
      v_txt1 := coalesce(public.automaty_podstaw(p_k->>'temat', p_ctx), public.automaty_tekst(p_ctx, 'dane.temat'));
      v_txt2 := coalesce(public.automaty_podstaw(p_k->>'tresc', p_ctx), public.automaty_tekst(p_ctx, 'dane.tresc'), '');
      insert into public.zespol_kontakty_wiadomosci (kontakt_id, kierunek, kanal, temat, tresc)
      values (v_id, 'odebrana', 'mail', v_txt1, v_txt2)
      returning id into v_id;
      return jsonb_build_object('opis', 'zapisana wiadomość firmy ' || v_id,
                                'ctx', jsonb_build_object('zapisana_wiadomosc_id', v_id));
    when 'akcja' then
      v_txt1 := p_k->>'akcja';
      v_dane := public.automaty_podstaw_json(coalesce(p_k->'dane', '{}'::jsonb), p_ctx);
      if v_txt1 = 'gmail_wyslij' then
        v_dane := jsonb_strip_nulls(jsonb_build_object(
            'do', p_ctx->'kontakt'->>'email',
            'temat', p_ctx->'wiadomosc'->>'temat',
            'tresc', p_ctx->'wiadomosc'->>'tresc',
            'watek_id', p_ctx->>'watek_id',
            'kontakt_id', (p_ctx->'kontakt'->>'id')::bigint))
          || v_dane
          || jsonb_build_object('wiadomosc_id', (p_ctx->'dane'->>'wiadomosc_id')::bigint);
        v_powod := public.automaty_wysylka_powod_odmowy(p_przebieg_id, (v_dane->>'wiadomosc_id')::bigint);
        if v_powod is not null then raise exception 'blokada gmail_wyslij: %', v_powod; end if;
        if coalesce(v_dane->>'do', '') !~ '@' then raise exception 'gmail_wyslij: kontakt nie ma adresu e-mail'; end if;
        if coalesce(v_dane->>'tresc', '') = '' then raise exception 'gmail_wyslij: pusty szkic'; end if;
      elsif v_txt1 = 'gmail_archiwizuj' then
        v_dane := jsonb_build_object('gmail_id', p_ctx->'dane'->>'gmail_id', 'etykieta', 'Automaty/posprzatane')
                  || jsonb_strip_nulls(v_dane);
        if v_dane->>'gmail_id' is null then raise exception 'gmail_archiwizuj: brak gmail_id'; end if;
      end if;
      insert into public.automaty_akcje (przebieg_id, typ, dane) values (p_przebieg_id, v_txt1, v_dane)
      returning id into v_id;
      return jsonb_build_object('opis', 'akcja ' || v_txt1 || ' ' || v_id || ' czeka na most');
    else
      raise exception 'nieznany krok: %', coalesce(v_typ, '(brak typ)');
  end case;
end $$;

-- ============================================================ silnik

-- Bierze nieobsłużone zdarzenia (maks. 200 na raz) i puszcza je przez włączone automaty.
-- Każdy automat w osobnej podtransakcji: błąd jednego = przebieg 'blad', reszta działa dalej,
-- a skutki kroków sprzed błędu są cofane (nie zostaje pół przebiegu).
create or replace function public.automaty_tick()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_z public.automaty_zdarzenia;
  v_a public.automaty;
  v_ctx jsonb;
  v_ctx_baza jsonb;
  v_ctx_blad text;
  v_kontakt bigint;
  v_przebieg bigint;
  v_wyniki jsonb;
  v_krok jsonb;
  v_nr int;
  v_r jsonb;
  v_w jsonb;
  v_spelnione boolean;
  v_niespelniony text;
  n_zd int := 0; n_ok int := 0; n_pom int := 0; n_bl int := 0;
begin
  for v_z in
    select * from public.automaty_zdarzenia where obsluzono is null order by id limit 200
    for update skip locked
  loop
    n_zd := n_zd + 1;
    v_ctx_blad := null;
    begin
      if v_z.typ = 'mail_przyszedl' and not v_z.dane ? 'kontakt_id' then
        v_kontakt := public.automaty_kontakt_nadawcy(v_z.dane->>'od');
        if v_kontakt is not null then
          v_z.dane := v_z.dane || jsonb_build_object('kontakt_id', v_kontakt);
          update public.automaty_zdarzenia set dane = v_z.dane where id = v_z.id;
        end if;
      end if;
      v_ctx_baza := public.automaty_kontekst(v_z);
    exception when others then
      v_ctx_blad := 'kontekst zdarzenia: ' || sqlerrm;
      v_ctx_baza := null;
    end;
    for v_a in
      select * from public.automaty where wlaczony and gdy = v_z.typ order by id
    loop
      v_wyniki := '[]'::jsonb;
      begin
        if v_ctx_blad is not null then raise exception '%', v_ctx_blad; end if;
        v_ctx := v_ctx_baza || jsonb_build_object('automat', jsonb_build_object('id', v_a.id, 'nazwa', v_a.nazwa));
        v_spelnione := true;
        v_niespelniony := null;
        v_nr := 0;
        for v_w in select jsonb_array_elements(v_a.warunki) loop
          v_nr := v_nr + 1;
          if not coalesce(public.automaty_warunek(v_w, v_ctx), false) then
            v_spelnione := false;
            v_niespelniony := v_nr || '. ' || (v_w->>'typ') || coalesce(' ' || (v_w->>'pole'), '');
            exit;
          end if;
        end loop;
        if not v_spelnione then
          insert into public.automaty_przebiegi (automat_id, zdarzenie_id, stan, kroki_wynik)
          values (v_a.id, v_z.id, 'pominiety', jsonb_build_array(jsonb_build_object(
            'krok', 'warunki', 'ok', false, 'opis', 'niespełniony warunek ' || v_niespelniony)));
          n_pom := n_pom + 1;
          continue;
        end if;
        insert into public.automaty_przebiegi (automat_id, zdarzenie_id, stan, kroki_wynik)
        values (v_a.id, v_z.id, 'ok', '[]'::jsonb) returning id into v_przebieg;
        v_nr := 0;
        for v_krok in select jsonb_array_elements(v_a.kroki) loop
          v_nr := v_nr + 1;
          begin
            v_r := public.automaty_krok(v_krok, v_ctx, v_przebieg);
          exception when others then
            v_wyniki := v_wyniki || jsonb_build_array(jsonb_build_object(
              'krok', v_nr || '. ' || coalesce(v_krok->>'typ', '?'), 'ok', false, 'opis', sqlerrm));
            raise;
          end;
          v_ctx := v_ctx || coalesce(v_r->'ctx', '{}'::jsonb);
          v_wyniki := v_wyniki || jsonb_build_array(jsonb_build_object(
            'krok', v_nr || '. ' || (v_krok->>'typ'), 'ok', true, 'opis', v_r->>'opis'));
        end loop;
        update public.automaty_przebiegi set kroki_wynik = v_wyniki where id = v_przebieg;
        n_ok := n_ok + 1;
      exception when others then
        if jsonb_array_length(v_wyniki) = 0 then
          v_wyniki := jsonb_build_array(jsonb_build_object('krok', 'start', 'ok', false, 'opis', sqlerrm));
        end if;
        insert into public.automaty_przebiegi (automat_id, zdarzenie_id, stan, kroki_wynik)
        values (v_a.id, v_z.id, 'blad', v_wyniki || jsonb_build_array(jsonb_build_object(
          'krok', 'cofnięto', 'ok', false, 'opis', 'skutki kroków tego przebiegu cofnięte')));
        n_bl := n_bl + 1;
      end;
    end loop;
    update public.automaty_zdarzenia set obsluzono = now() where id = v_z.id;
  end loop;
  return jsonb_build_object('zdarzenia', n_zd, 'ok', n_ok, 'pominiete', n_pom, 'bledy', n_bl);
end $$;

-- ============================================================ wyzwalacze zdarzeń

create or replace function public.automaty_zd_kontakt_dodany()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.automaty_zdarzenia (typ, zrodlo, dane) values ('kontakt_dodany', 'baza', to_jsonb(new));
  return new;
end $$;
drop trigger if exists automaty_kontakt_dodany on public.zespol_kontakty;
create trigger automaty_kontakt_dodany after insert on public.zespol_kontakty
  for each row execute function public.automaty_zd_kontakt_dodany();

create or replace function public.automaty_zd_szkic_oceniony()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.automaty_zdarzenia (typ, zrodlo, dane) values ('szkic_oceniony', 'baza', jsonb_build_object(
    'wiadomosc_id', new.id, 'kontakt_id', new.kontakt_id, 'ocena', new.ocena_michala, 'uwaga', new.uwaga_michala));
  return new;
end $$;
drop trigger if exists automaty_szkic_oceniony on public.zespol_kontakty_wiadomosci;
create trigger automaty_szkic_oceniony after update of ocena_michala on public.zespol_kontakty_wiadomosci
  for each row when (old.ocena_michala is null and new.ocena_michala is not null)
  execute function public.automaty_zd_szkic_oceniony();

-- ============================================================ funkcje dla panelu i mostu

create or replace function public.automaty_przelacz(p_id bigint, p_wlaczony boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v jsonb;
begin
  update public.automaty set wlaczony = p_wlaczony where id = p_id
  returning jsonb_build_object('id', id, 'nazwa', nazwa, 'wlaczony', wlaczony) into v;
  if v is null then raise exception 'nie ma automatu %', p_id; end if;
  return v;
end $$;

-- Szkic poszedł: ustawia wyslano (raz). Zwraca true, gdy właśnie ustawiono.
create or replace function public.automaty_wiadomosc_wyslana(p_wiadomosc_id bigint)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.zespol_kontakty_wiadomosci set wyslano = now()
   where id = p_wiadomosc_id and kierunek = 'wyslana' and wyslano is null;
  return found;
end $$;

-- Most zgłasza postęp akcji: 'w_toku' (wziął), 'zrobione' albo 'blad' (koniec).
-- Koniec akcji = zdarzenie akcja_wykonana (automaty mogą na nie reagować, np. push „Wysłane do…”).
-- gmail_wyslij zrobione = od razu wyslano przy szkicu (nawet gdy most zapomni o osobnym wywołaniu).
create or replace function public.automaty_akcja_wynik(p_id bigint, p_stan text, p_wynik jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v public.automaty_akcje;
begin
  if p_stan not in ('w_toku', 'zrobione', 'blad') then
    raise exception 'stan akcji: w_toku, zrobione albo blad (jest: %)', p_stan;
  end if;
  select * into v from public.automaty_akcje where id = p_id for update;
  if v.id is null then raise exception 'nie ma akcji %', p_id; end if;
  if v.stan in ('zrobione', 'blad') then
    raise exception 'akcja % już zakończona (%)', p_id, v.stan;
  end if;
  update public.automaty_akcje
     set stan = p_stan,
         wynik = coalesce(p_wynik, wynik),
         zrobiono = case when p_stan in ('zrobione', 'blad') then now() end
   where id = p_id;
  if p_stan = 'zrobione' and v.typ = 'gmail_wyslij' then
    perform public.automaty_wiadomosc_wyslana((v.dane->>'wiadomosc_id')::bigint);
  end if;
  if p_stan in ('zrobione', 'blad') then
    insert into public.automaty_zdarzenia (typ, zrodlo, dane) values ('akcja_wykonana', 'baza',
      jsonb_strip_nulls(jsonb_build_object(
        'akcja_id', v.id, 'akcja', v.typ, 'stan', p_stan, 'wynik', p_wynik, 'przebieg_id', v.przebieg_id,
        'kontakt_id', v.dane->'kontakt_id', 'wiadomosc_id', v.dane->'wiadomosc_id',
        'gmail_id', v.dane->'gmail_id')));
  end if;
end $$;

-- Sprzątanie raz na dobę: maile niezwiązane z kontaktami po 14 dniach, przebiegi 'pominiety' po 14 dniach.
create or replace function public.automaty_sprzatanie()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  n_maile int; n_pom int;
begin
  delete from public.automaty_zdarzenia z
   where z.typ = 'mail_przyszedl' and z.obsluzono is not null
     and z.utworzono < now() - interval '14 days'
     and not z.dane ? 'kontakt_id'
     and public.automaty_kontakt_nadawcy(z.dane->>'od') is null;
  get diagnostics n_maile = row_count;
  delete from public.automaty_przebiegi p
   where p.stan = 'pominiety' and p.utworzono < now() - interval '14 days'
     and not exists (select 1 from public.automaty_akcje a where a.przebieg_id = p.id);
  get diagnostics n_pom = row_count;
  return jsonb_build_object('maile', n_maile, 'pominiete', n_pom);
end $$;

-- ============================================================ uprawnienia

revoke all on function public.automaty_kontakt_nadawcy(text) from public, anon, authenticated;
revoke all on function public.automaty_kontekst(public.automaty_zdarzenia) from public, anon, authenticated;
revoke all on function public.automaty_wysylka_powod_odmowy(bigint, bigint) from public, anon, authenticated;
revoke all on function public.automaty_krok(jsonb, jsonb, bigint) from public, anon, authenticated;
revoke all on function public.automaty_tick() from public, anon, authenticated;
revoke all on function public.automaty_przelacz(bigint, boolean) from public, anon, authenticated;
revoke all on function public.automaty_wiadomosc_wyslana(bigint) from public, anon, authenticated;
revoke all on function public.automaty_akcja_wynik(bigint, text, jsonb) from public, anon, authenticated;
revoke all on function public.automaty_sprzatanie() from public, anon, authenticated;
revoke all on function public.automaty_akcje_straznik() from public, anon, authenticated;
revoke all on function public.automaty_zd_kontakt_dodany() from public, anon, authenticated;
revoke all on function public.automaty_zd_szkic_oceniony() from public, anon, authenticated;

-- ============================================================ pg_cron

do $$
begin
  if exists (select 1 from cron.job where jobname = 'automaty-tick') then
    perform cron.unschedule('automaty-tick');
  end if;
  if exists (select 1 from cron.job where jobname = 'automaty-sprzatanie') then
    perform cron.unschedule('automaty-sprzatanie');
  end if;
end $$;
select cron.schedule('automaty-tick', '* * * * *', 'select public.automaty_tick()');
select cron.schedule('automaty-sprzatanie', '30 3 * * *', 'select public.automaty_sprzatanie()');

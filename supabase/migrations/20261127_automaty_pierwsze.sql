-- Automaty – tor D (27.11.2026): pierwsze automaty + 3 drobne poprawki silnika i mostu.
-- Spec: CEO docs/superpowers/specs/2026-11-27-automaty-design.md (sekcja „Tor D”).
--
-- Poprawki (opis w specu, „Zmiany kontraktu”):
--  1. automaty_domena_ogolna: także platformy rekrutacyjne i portale (pracuj.pl, workable, ashby, lever…)
--     i ich poddomeny – po nich nie dopasowujemy firmy po domenie (jedna domena = setki firm).
--  2. automaty_krok: każdy krok może mieć `tylko_gdy` (warunek tylko dla tego kroku);
--     `stan_kontaktu` przyjmuje `nastepny_za_dni` (data przypomnienia = dziś w Warszawie + N).
--  3. gmail_most_akcje: tryb próbny mostu nie kończy wysyłki do firmy błędem – akcja czeka,
--     aż tryb próbny zostanie zdjęty (błąd blokował szkic na zawsze).

-- ============================================================ 1. domeny wspólne
create or replace function public.automaty_domena_ogolna(p_domena text)
returns boolean language sql immutable as $$
  select exists (
    select 1 from unnest(array[
      -- poczta ogólna
      'gmail.com', 'googlemail.com', 'wp.pl', 'o2.pl', 'onet.pl', 'onet.eu',
      'op.pl', 'vp.pl', 'interia.pl', 'interia.eu', 'poczta.fm', 'gazeta.pl', 'tlen.pl', 'int.pl', 'spoko.pl',
      'outlook.com', 'outlook.pl', 'hotmail.com', 'live.com', 'yahoo.com', 'icloud.com', 'me.com',
      'proton.me', 'protonmail.com', 'aol.com', 'gmx.com', 'gmx.net',
      -- platformy rekrutacyjne i portale (wspólne dla wielu firm; tor D, 27.11)
      'pracuj.pl', 'erecruiter.pl', 'workablemail.com', 'workable.com', 'ashbyhq.com', 'lever.co',
      'smartrecruiters.com', 'traffit-mail.com', 'traffit.com', 'recruitee-mail.com', 'recruitee-email.com',
      'recruitee-mailbox.com', 'recruitee-inbox.com', 'recruitee.com', 'hibob.com', 'tomhrm.com',
      'comeet-notifications.com', 'hipeople.io', 'peopleforce.io', 'manatal.com', 'justjoin.it',
      'rocketjobs.pl', 'rocketjobs.com', 'recruitify.ai', 'personio.de', 'greenhouse-mail.io',
      'myworkday.com', 'avature.net', 'oraclecloud.com', 'applytojob.com', 'linkedin.com', 'google.com',
      'calendly.com', 'thesmartjobs.com', 'elementapp.ai', 'elevato.net', 'huzzle.app'
    ]) d
    where lower(coalesce(p_domena, '')) = d or lower(coalesce(p_domena, '')) like '%.' || d)
$$;

-- ============================================================ 2. kroki: tylko_gdy, nastepny_za_dni
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
  v_data date;
begin
  -- warunek tylko dla tego kroku (tor D): niespełniony = krok pominięty, przebieg idzie dalej
  if p_k ? 'tylko_gdy' and not coalesce(public.automaty_warunek(p_k->'tylko_gdy', p_ctx), false) then
    return jsonb_build_object('opis', 'pominięty (warunek tylko_gdy niespełniony)');
  end if;
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
      if p_k ? 'nastepny_za_dni' then
        v_data := (now() at time zone 'Europe/Warsaw')::date + (p_k->>'nastepny_za_dni')::int;
      end if;
      perform public.zespol_kontakt_stan(v_id, p_k->>'stan', v_data,
                                         public.automaty_podstaw(p_k->>'notatka', p_ctx));
      return jsonb_build_object('opis', 'kontakt ' || v_id || ' → ' || (p_k->>'stan')
                                        || coalesce(', następny kontakt ' || v_data, ''));
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
revoke all on function public.automaty_krok(jsonb, jsonb, bigint) from public, anon, authenticated;

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
    if v ? 'tylko_gdy' then perform public.automaty_waliduj_warunek(v->'tylko_gdy'); end if;
    case v->>'typ'
      when 'powiadom' then
        if v->>'tytul' is null then raise exception 'powiadom wymaga tytul'; end if;
      when 'wiadomosc_do_agenta' then
        if v->>'do' is null or v->>'temat' is null or v->>'tresc' is null then
          raise exception 'wiadomosc_do_agenta wymaga do, temat, tresc';
        end if;
      when 'stan_kontaktu' then
        if v->>'stan' is null then raise exception 'stan_kontaktu wymaga stan'; end if;
        if v ? 'nastepny_za_dni' and jsonb_typeof(v->'nastepny_za_dni') <> 'number' then
          raise exception 'stan_kontaktu: nastepny_za_dni musi być liczbą';
        end if;
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

-- ============================================================ 3. most: tryb próbny = czekaj
create or replace function public.gmail_most_akcje(p_limit int default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a record; v_dozw text[]; v_out jsonb := '[]'::jsonb;
begin
  for a in select id from automaty_akcje
            where typ = 'gmail_archiwizuj' and stan = 'w_toku'
              and (wynik->>'most_pobral')::timestamptz < now() - interval '15 minutes'
            for update skip locked loop
    update automaty_akcje set stan = 'czeka' where id = a.id;
  end loop;
  for a in select id from automaty_akcje
            where typ = 'gmail_wyslij' and stan = 'w_toku'
              and (wynik->>'most_pobral')::timestamptz < now() - interval '60 minutes'
            for update skip locked loop
    perform automaty_akcja_wynik(a.id, 'blad', jsonb_build_object(
      'blad', 'Most nie potwierdził wysyłki w 60 min – sprawdź „Wysłane” w Gmailu frycz.wideo; nie ponawiam.'));
  end loop;

  -- Tryb próbny (wysylka_dozwolona_do): wysyłka na inny adres zostaje w 'czeka' (nie jest pobierana),
  -- aż Claude zdejmie tryb próbny. Filtr w zapytaniu, żeby czekające nie zajmowały limitu.
  select wysylka_dozwolona_do into v_dozw from gmail_most_stan where id = 1;

  for a in select id, typ, dane from automaty_akcje
            where stan = 'czeka' and typ in ('gmail_wyslij', 'gmail_archiwizuj')
              and not (typ = 'gmail_wyslij' and v_dozw is not null
                       and not (lower(trim(coalesce(dane->>'do', ''))) = any (v_dozw)))
            order by id limit greatest(1, least(p_limit, 50))
            for update skip locked loop
    update automaty_akcje
       set stan = 'w_toku', wynik = coalesce(wynik, '{}'::jsonb) || jsonb_build_object('most_pobral', now())
     where id = a.id;
    v_out := v_out || jsonb_build_object('id', a.id, 'typ', a.typ, 'dane', a.dane);
  end loop;
  return v_out;
end $$;

-- ============================================================ 4. pierwsze automaty
-- Upsert po nazwie: ponowne uruchomienie migracji poprawia treść, a stan wł./wył. ustawia jawnie.
insert into public.automaty (nazwa, opis, wlaczony, gdy, warunki, kroki) values
(
  'Firma odpisała',
  'Gdy firma z naszej listy odpisze na frycz.wideo: zapisuję odpowiedź, push do Michała i prośba do Dale’a Rozmówcy o szkic.',
  true,
  'mail_przyszedl',
  $j$[
    {"typ":"nadawca_jest_kontaktem","opis":"nadawca jest w zespol_kontakty"},
    {"typ":"nie","opis":"to nie wspólny adres systemowy (no-reply portalu – jeden adres dla wielu firm)",
     "warunek":{"typ":"pole_pasuje","pole":"dane.od","wzorzec":"^(no-?reply|noreply|do-?not-?reply|donotreply|notifications?|system|mail|mailer-daemon|[a-z]+-noreply)@"}}
  ]$j$::jsonb,
  $j$[
    {"typ":"zapisz_wiadomosc_firmy","opis":"zapis odpowiedzi przy kontakcie"},
    {"typ":"stan_kontaktu","stan":"odpowiedz","opis":"stan „odpowiedź” (tylko gdy rozmowa jeszcze nie ruszyła)",
     "tylko_gdy":{"typ":"ktorykolwiek","warunki":[
       {"typ":"pole_puste","pole":"kontakt.stan"},
       {"typ":"pole_pasuje","pole":"kontakt.stan","wzorzec":"^(do_wyslania|wyslane|brak_odpowiedzi)$"}]}},
    {"typ":"powiadom","tytul":"{{kontakt.firma}} odpisała: {{temat}}","tresc":"{{tresc}}"},
    {"typ":"wiadomosc_do_agenta","do":"Dale Rozmówca",
     "temat":"Odpowiedź od {{kontakt.firma}} – przygotuj szkic",
     "tresc":"Automat „Firma odpisała”: kontakt {{kontakt.id}} ({{kontakt.firma}}), odpowiedź zapisana jako wiadomość {{zapisana_wiadomosc_id}} w zespol_kontakty_wiadomosci (nie zapisuj jej drugi raz). Temat: {{temat}}. Stan kontaktu: popraw wg treści (rozmowa / oferta / odmowa / nie_pisac). Szkic odpowiedzi zapisz jak zwykle – po ocenie „dobra” wyśle go automat „Zgoda → wysyłka”, Ty nie wysyłasz."}
  ]$j$::jsonb
),
(
  'Sprzątanie skrzynki',
  'Potwierdzenia aplikacji, alerty ofert i reklamy przenoszę z odbiorczej frycz.wideo do archiwum z etykietą Automaty/posprzatane (nic nie kasuję). Zaproszeń na rozmowę i odmów nie ruszam.',
  false,
  'mail_przyszedl',
  $j$[
    {"typ":"ktorykolwiek","opis":"nadawca nie jest firmą z listy (albo to wspólny adres no-reply portalu)","warunki":[
      {"typ":"nie","warunek":{"typ":"nadawca_jest_kontaktem"}},
      {"typ":"pole_pasuje","pole":"dane.od","wzorzec":"^(no-?reply|noreply|do-?not-?reply|donotreply|notifications?|system|mail|[a-z]+-noreply)@"}]},
    {"typ":"ktorykolwiek","opis":"potwierdzenie aplikacji, alert ofert, newsletter albo reklama","warunki":[
      {"typ":"pole_pasuje","pole":"dane.od","wzorzec":[
        "^rekomendacje@wysylka\\.pracuj\\.pl$", "^jobalerts-noreply@linkedin\\.com$", "@hello\\.justjoin\\.it$",
        "@(email\\.)?manychat\\.com$", "@dribbble\\.com$", "^info@creatio\\.com$", "^info@useme\\.com$",
        "@thesmartjobs\\.com$", "@himalayas\\.app$", "@huzzle\\.app$", "@elementapp\\.ai$",
        "^noreply@konto\\.pracuj\\.pl$", "@promo\\.comeet-notifications\\.com$"]},
      {"typ":"pole_pasuje","pole":"dane.temat","wzorzec":[
        "dzi[eę]kujemy za (twoj[aą] |pa[nń]sk[aą] )?(aplikacj|zg[lł]oszeni|przes[lł]ani|zainteresowani)",
        "otrzymali[sś]my (twoj|pa[nń]sk|twoje|zg[lł]oszeni|aplikacj|cv)",
        "potwierdzeni[ea] (aplikacji|z[lł]o[zż]enia|otrzymania|zg[lł]oszenia)",
        "(twoja |pa[nń]ska )?aplikacja (zosta[lł]a )?(wys[lł]ana|przes[lł]ana|z[lł]o[zż]ona|dotar[lł]a|trafi[lł]a)",
        "thank(s| you) for (applying|your application|your interest|submitting)",
        "application (received|submitted|confirmation|was sent)",
        "(we('ve| have)? )?received your (application|cv|resume)",
        "your application (to|for|at|has been (sent|received|submitted))",
        "newsletter", "webinar", "(nowe|polecane|rekomendowane|dopasowane) oferty", "oferty (pracy )?dla ciebie",
        "job alert", "new jobs? (for you|matching)", "nie zapomnij doko[nń]czy[cć]", "complete your (application|profile)"]},
      {"typ":"pole_pasuje","pole":"dane.tresc","wzorzec":[
        "unsubscribe", "wypisz si[eę]", "zrezygnuj z (subskrypcji|otrzymywania)", "rezygnacja z (subskrypcji|newslettera)"]}]},
    {"typ":"nie","opis":"strażnik: zaproszenie na rozmowę, kolejny etap albo odmowa – zostaje w skrzynce","warunek":
      {"typ":"ktorykolwiek","warunki":[
        {"typ":"pole_pasuje","pole":"dane.temat","wzorzec":"(zaprasza|zaprosi|zaproszeni|rozmow[aęyieą]|spotkani|interview|\\ycall\\y|calendly|um[oó]w|schedule|availability|dost[eę]pno[sś]|next step|kolejn\\w* etap|nast[eę]pn\\w* etap|zadani\\w* rekrutacyjn|assessment|test (rekrutacyjny|kompetencji)|niestety|unfortunately|regret|not (to )?(move|proceed|progress)|other candidates|innych kandydat|nie (zdecydowali|b[eę]dziemy kontynuowa)|zdecydowali[sś]my|decided|odrzuc|unsuccessful|not been (successful|selected)|position has been filled|oferta pracy dla (ciebie|pana)|offer letter|job offer)"},
        {"typ":"pole_pasuje","pole":"dane.tresc","wzorzec":"(zaprasza|zaprosi|zaproszeni|rozmow[aęyieą]|spotkani|interview|\\ycall\\y|calendly|um[oó]w|schedule|availability|dost[eę]pno[sś]|next step|kolejn\\w* etap|nast[eę]pn\\w* etap|zadani\\w* rekrutacyjn|assessment|test (rekrutacyjny|kompetencji)|niestety|unfortunately|regret|not (to )?(move|proceed|progress)|other candidates|innych kandydat|nie (zdecydowali|b[eę]dziemy kontynuowa)|zdecydowali[sś]my|decided|odrzuc|unsuccessful|not been (successful|selected)|position has been filled|oferta pracy dla (ciebie|pana)|offer letter|job offer)"}]}}
  ]$j$::jsonb,
  $j$[
    {"typ":"akcja","akcja":"gmail_archiwizuj","opis":"do archiwum z etykietą Automaty/posprzatane"}
  ]$j$::jsonb
),
(
  'Przekazanie firm',
  'Gdy Maria Odkrywczyni doda firmę dla Marka Pisarza (stan „do wysłania”), Marek dostaje wiadomość z id kontaktu. Wyłączony do etapu nauki cold maili.',
  false,
  'kontakt_dodany',
  $j$[
    {"typ":"pole_rowne","pole":"dane.agent","wartosc":"Marek Pisarz"},
    {"typ":"pole_rowne","pole":"dane.stan","wartosc":"do_wyslania"}
  ]$j$::jsonb,
  $j$[
    {"typ":"wiadomosc_do_agenta","do":"Marek Pisarz",
     "temat":"Nowa firma do maila: {{dane.firma}} ({{dane.id}})",
     "tresc":"Automat „Przekazanie firm”: kontakt {{dane.id}} – {{dane.firma}}, adres: {{dane.adres}}, branża: {{dane.branza}}. Szkic wg karty i zasad zimnego maila; wyśle go automat po ocenie „dobra”."}
  ]$j$::jsonb
),
(
  'Zgoda → wysyłka',
  'Gdy Michał oceni szkic maila Dale’a Rozmówcy albo Marka Pisarza na „dobra”, zlecam mostowi Gmail wysyłkę z frycz.wideo (raz, w wątku, jeśli firma już pisała).',
  true,
  'szkic_oceniony',
  $j$[
    {"typ":"ocena_rowna","ocena":"dobra"},
    {"typ":"pole_rowne","pole":"wiadomosc.kierunek","wartosc":"wyslana","opis":"to szkic do wysłania"},
    {"typ":"pole_puste","pole":"wiadomosc.wyslano","opis":"jeszcze nie wysłany"},
    {"typ":"pole_rowne","pole":"wiadomosc.kanal","wartosc":"mail","opis":"kanał: mail"},
    {"typ":"pole_pasuje","pole":"wiadomosc.agent","wzorzec":"^(Dale Rozmówca|Marek Pisarz)$","opis":"szkic Dale’a Rozmówcy albo Marka Pisarza"},
    {"typ":"nie","opis":"kontakt ma adres e-mail","warunek":{"typ":"pole_puste","pole":"kontakt.email"}}
  ]$j$::jsonb,
  $j$[
    {"typ":"akcja","akcja":"gmail_wyslij","opis":"wysyłka szkicu z frycz.wideo (most Gmail)"}
  ]$j$::jsonb
),
(
  'Zgoda → wysyłka: po wysyłce',
  'Gdy most Gmail wyśle oceniony szkic: stan kontaktu i data przypomnienia, push „Wysłane do…”; gdy wysyłka padnie – push z powodem.',
  true,
  'akcja_wykonana',
  $j$[
    {"typ":"pole_rowne","pole":"dane.akcja","wartosc":"gmail_wyslij"}
  ]$j$::jsonb,
  $j$[
    {"typ":"stan_kontaktu","stan":"wyslane","nastepny_za_dni":6,
     "opis":"pierwszy mail: stan „wysłane”, przypomnienie za 6 dni (≈4 dni robocze)",
     "tylko_gdy":{"typ":"wszystkie","warunki":[
       {"typ":"pole_rowne","pole":"dane.stan","wartosc":"zrobione"},
       {"typ":"pole_rowne","pole":"kontakt.stan","wartosc":"do_wyslania"}]}},
    {"typ":"stan_kontaktu","stan":"wyslane","nastepny_za_dni":7,
     "opis":"przypomnienie Dale’a: następne za 7 dni",
     "tylko_gdy":{"typ":"wszystkie","warunki":[
       {"typ":"pole_rowne","pole":"dane.stan","wartosc":"zrobione"},
       {"typ":"pole_rowne","pole":"kontakt.stan","wartosc":"wyslane"}]}},
    {"typ":"powiadom","tytul":"Wysłane do {{kontakt.firma}}","tresc":"{{wiadomosc.temat}}",
     "tylko_gdy":{"typ":"pole_rowne","pole":"dane.stan","wartosc":"zrobione"}},
    {"typ":"powiadom","tytul":"Nie wysłano do {{kontakt.firma}}","tresc":"{{dane.wynik.blad}}",
     "tylko_gdy":{"typ":"pole_rowne","pole":"dane.stan","wartosc":"blad"}}
  ]$j$::jsonb
)
on conflict (nazwa) do update set
  opis = excluded.opis, wlaczony = excluded.wlaczony, gdy = excluded.gdy,
  warunki = excluded.warunki, kroki = excluded.kroki;

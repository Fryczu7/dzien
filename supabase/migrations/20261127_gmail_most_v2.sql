-- Most Gmail v2 (27.11.2026): dopasowanie do sygnatury toru A
-- automaty_akcja_wynik(p_id bigint, p_stan text, p_wynik jsonb) – p_stan 'zrobione' | 'blad'.
-- 'zrobione' przy gmail_wyslij samo ustawia wyslano przy szkicu (tor A), więc most nie woła
-- już automaty_wiadomosc_wyslana. Zakończonej akcji nie da się zmienić drugi raz.

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

  select wysylka_dozwolona_do into v_dozw from gmail_most_stan where id = 1;

  for a in select id, typ, dane from automaty_akcje
            where stan = 'czeka' and typ in ('gmail_wyslij', 'gmail_archiwizuj')
            order by id limit greatest(1, least(p_limit, 50))
            for update skip locked loop
    if a.typ = 'gmail_wyslij' and v_dozw is not null
       and not (lower(trim(coalesce(a.dane->>'do', ''))) = any (v_dozw)) then
      perform automaty_akcja_wynik(a.id, 'blad', jsonb_build_object(
        'blad', 'Most w trybie próbnym: wysyłka tylko do ' || array_to_string(v_dozw, ', ')
                || '. Wyłączenie: update gmail_most_stan set wysylka_dozwolona_do = null.'));
      continue;
    end if;
    update automaty_akcje
       set stan = 'w_toku', wynik = coalesce(wynik, '{}'::jsonb) || jsonb_build_object('most_pobral', now())
     where id = a.id;
    v_out := v_out || jsonb_build_object('id', a.id, 'typ', a.typ, 'dane', a.dane);
  end loop;
  return v_out;
end $$;

create or replace function public.gmail_most_wynik(p_akcja_id bigint, p_ok boolean, p_wynik jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_stan text;
begin
  select stan into v_stan from automaty_akcje where id = p_akcja_id for update;
  if not found or v_stan <> 'w_toku' then return false; end if;
  perform automaty_akcja_wynik(p_akcja_id, case when p_ok then 'zrobione' else 'blad' end,
                               coalesce(p_wynik, '{}'::jsonb));
  return true;
end $$;

revoke all on function public.gmail_most_akcje(int), public.gmail_most_wynik(bigint, boolean, jsonb)
  from public, anon, authenticated;
grant execute on function public.gmail_most_akcje(int), public.gmail_most_wynik(bigint, boolean, jsonb)
  to service_role;

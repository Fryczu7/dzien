-- Szkic vs wysłana wiadomość do firmy (23.11): agenci (Marek Pisarz, Dale Rozmówca) wysyłają
-- szkic dopiero po ocenie Michała 'dobra' i muszą zaznaczyć, że już poszedł – inaczej
-- kolejny przebieg wysłałby go drugi raz. Agenci nie robią gołego UPDATE, więc funkcja.

alter table public.zespol_kontakty_wiadomosci
  add column if not exists wyslano timestamptz;

create or replace function public.zespol_wiadomosc_wyslana(p_id bigint)
returns void language sql security definer set search_path = public as $$
  update public.zespol_kontakty_wiadomosci
     set wyslano = now()
   where id = p_id and kierunek = 'wyslana' and wyslano is null;
$$;
revoke execute on function public.zespol_wiadomosc_wyslana(bigint) from public, anon, authenticated;

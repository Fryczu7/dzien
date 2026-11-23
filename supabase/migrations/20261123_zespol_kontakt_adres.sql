-- Adres e-mail kontaktu znaleziony później (23.11): Marek Pisarz znajduje maile firm,
-- których Maria Odkrywczyni nie miała; agenci nie robią gołego UPDATE, więc funkcja.
create or replace function public.zespol_kontakt_adres(p_id bigint, p_adres text)
returns void language sql security definer set search_path = public as $$
  update public.zespol_kontakty
     set adres = p_adres, zaktualizowano = now()
   where id = p_id and nullif(trim(p_adres), '') is not null;
$$;
revoke execute on function public.zespol_kontakt_adres(bigint, text) from public, anon, authenticated;

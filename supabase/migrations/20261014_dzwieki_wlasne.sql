-- Własne dźwięki stopera (decyzja Michała 14.10): prywatny kubełek, każdy widzi tylko swój folder <user_id>/.
-- Zastosowana w bazie 14.10 (migracja dzwieki_wlasne_i_teksty_systemu; ta sama migracja zmieniła teksty
-- powiadomień w public.praca_tick na styl „Systemu” z Solo Leveling – logika funkcji bez zmian).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dzwieki', 'dzwieki', false, 1048576,
  array['audio/mpeg','audio/mp3','audio/mp4','audio/x-m4a','audio/m4a','audio/aac','audio/wav','audio/x-wav','audio/wave','audio/ogg','audio/webm'])
on conflict (id) do nothing;
create policy "dzwieki wlasne select" on storage.objects for select to authenticated
  using (bucket_id = 'dzwieki' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "dzwieki wlasne insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'dzwieki' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "dzwieki wlasne update" on storage.objects for update to authenticated
  using (bucket_id = 'dzwieki' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "dzwieki wlasne delete" on storage.objects for delete to authenticated
  using (bucket_id = 'dzwieki' and (storage.foldername(name))[1] = (select auth.uid())::text);

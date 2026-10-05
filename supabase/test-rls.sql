-- Test izolacji danych. Uruchamiać trzema osobnymi wywołaniami, każde kończy się rollback.
-- :MICHAL podmienić na uuid konta Michała (select id from auth.users where email = 'mfryczu@gmail.com').

-- A. Obcy użytkownik nie widzi niczego. Oczekiwane: wszystkie zera.
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
select (select count(*) from public.days) d, (select count(*) from public.meals) m, (select count(*) from public.rules) r,
       (select count(*) from public.settings) s, (select count(*) from public.notes) n;
rollback;

-- B. Michał widzi swoje. Oczekiwane: d>=2, r=12, s=1.
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', ':MICHAL', 'role', 'authenticated')::text, true);
select (select count(*) from public.days) d, (select count(*) from public.rules) r, (select count(*) from public.settings) s;
rollback;

-- C. Obcy nie może zapisać wiersza z cudzym user_id. Oczekiwane: błąd "new row violates row-level security policy".
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
insert into public.weights (user_id, date, kg) values (':MICHAL', '2000-01-01', 1);
rollback;

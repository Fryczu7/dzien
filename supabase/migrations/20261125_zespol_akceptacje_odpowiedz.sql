-- Michał może odpisać agentowi własnymi słowami (panel: „Wyślij odpowiedź”) zamiast Tak/Nie.
-- stan 'odpowiedz' = agent czyta pole odpowiedz i robi według niego.
alter table public.zespol_akceptacje drop constraint zespol_akceptacje_stan_check;
alter table public.zespol_akceptacje add constraint zespol_akceptacje_stan_check check (stan in ('czeka', 'tak', 'nie', 'odpowiedz'));

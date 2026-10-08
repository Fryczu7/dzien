-- Status „wstrzymane”: rzecz odłożona decyzją Michała (np. cold calle do czasu, aż ruszy GetMed).
-- Coach nie traktuje jej jako „stoi w miejscu” i nie przypomina, dopóki Michał jej nie odwiesi.
alter table public.memory drop constraint memory_status_check;
alter table public.memory add constraint memory_status_check check (status in ('otwarte','zrobione','odrzucone','wstrzymane'));

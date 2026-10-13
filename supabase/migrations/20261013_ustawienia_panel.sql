-- Panel ustawień (decyzja Michała 13.10): wyłączanie kart i zakładek, limit planu do zmiany.
-- ui.off = lista kluczy wyłączonych kart (np. "modlitwy") i zakładek (np. "tab-trening").
alter table public.settings add column if not exists ui jsonb not null default '{"off":[]}'::jsonb;
alter table public.settings add column if not exists plan_max int not null default 3 check (plan_max between 1 and 10);

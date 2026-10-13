-- Start dla nowej osoby (decyzja Michała 13.10): przy pierwszym wejściu wybiera karty, zakładki i cele.
alter table public.settings add column if not exists onboarded boolean not null default false;
-- Michał już ma wszystko ustawione – start uruchamia tylko ręcznie z panelu (☰ → Start od nowa).
update public.settings set onboarded = true where user_id = (select id from auth.users where email = 'mfryczu@gmail.com');

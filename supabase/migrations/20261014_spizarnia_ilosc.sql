-- Zwykła ilość przy zakupie (tekst, np. „3–4 szt.”) – pokazywana na liście „Do kupienia” (decyzja Michała 14.10).
alter table public.products add column if not exists usual_qty text;

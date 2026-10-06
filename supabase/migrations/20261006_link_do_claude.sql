-- Link pod przyciskiem „Porozmawiaj z Claude” (np. projekt CEO na claude.ai). Pusty = lista projektów.
alter table public.settings add column claude_url text;

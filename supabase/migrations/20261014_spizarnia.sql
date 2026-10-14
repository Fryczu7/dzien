-- Spiżarnia ze zużyciem (decyzje Michała 14.10): stałe produkty + daty zakupów.
-- Apka sama liczy, co się pewnie kończy (odstępy między zakupami); zakupy wpisuje tylko Claude w rozmowie.
create table public.products (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  category text,                               -- np. nabiał, mięso, owoce i warzywa, suche
  start_days int not null default 7 check (start_days between 1 and 365), -- odstęp startowy z oceny Claude
  active boolean not null default true,
  sort int not null default 100,
  created_at timestamptz not null default now(),
  unique (user_id, name)
);
alter table public.products enable row level security;
create policy wlasne on public.products for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create table public.purchases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  date date not null,
  qty text,                                    -- tylko gdy Michał poda, np. „8 szt.”
  created_at timestamptz not null default now()
);
create index purchases_user_product_date on public.purchases (user_id, product_id, date);
create index purchases_product on public.purchases (product_id);
alter table public.purchases enable row level security;
create policy wlasne on public.purchases for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Web Push dla stopera pracy (decyzja Michała 14.10): alarm po godzinie pracy i po końcu przerwy
-- także przy zablokowanym telefonie. Serwer (pg_cron co 30 s) zamyka odcinek, zapisuje przerwę
-- i przez pg_net woła edge function `push-wyslij`, która wysyła Web Push.
-- Sekrety (klucz prywatny VAPID, sekret wywołań) są tylko w vault – repo apki jest publiczne.

create extension if not exists pg_net with schema extensions;  -- funkcje i tak w schemacie net
create extension if not exists pg_cron;

-- Subskrypcje powiadomień (jedno urządzenie/przeglądarka = jeden wiersz).
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
create policy wlasne on public.push_subscriptions for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Sekret wywołań funkcji: losowy, tworzony w bazie (nigdy nie przechodzi przez repo ani czat).
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'push_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'push_secret', 'Sekret wywołań edge function push-wyslij');
  end if;
end $$;

-- Konfiguracja dla edge function (tylko service_role): sekret + klucze VAPID.
create or replace function public.push_config()
returns jsonb language sql security definer set search_path = '' as $$
  select jsonb_build_object(
    'secret',  (select decrypted_secret from vault.decrypted_secrets where name = 'push_secret'),
    'public',  (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_public'),
    'private', (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_private'));
$$;
revoke all on function public.push_config() from public, anon, authenticated;
grant execute on function public.push_config() to service_role;

-- Jednorazowy zapis kluczy VAPID wygenerowanych przez edge function (drugi raz nic nie zmienia).
create or replace function public.push_vapid_save(pub text, priv text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from vault.secrets where name = 'push_vapid_private') then return false; end if;
  perform vault.create_secret(pub, 'push_vapid_public', 'VAPID – klucz publiczny (jest też w dzien-app/push.js)');
  perform vault.create_secret(priv, 'push_vapid_private', 'VAPID – klucz prywatny');
  return true;
end $$;
revoke all on function public.push_vapid_save(text, text) from public, anon, authenticated;
grant execute on function public.push_vapid_save(text, text) to service_role;

-- Wysyłka: asynchroniczne wywołanie edge function przez pg_net.
create or replace function public.push_send(p_user uuid, p_title text, p_body text)
returns bigint language plpgsql security definer set search_path = '' as $$
begin
  return net.http_post(
    url := 'https://ywoqfvlnteejtzhqdpdd.supabase.co/functions/v1/push-wyslij',
    body := jsonb_build_object('user_id', p_user, 'title', p_title, 'body', p_body),
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-push-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_secret')),
    timeout_milliseconds := 15000);
end $$;
revoke all on function public.push_send(uuid, text, text) from public, anon, authenticated;

-- Start ciągłej pracy (ta sama zasada co lib.js workChainStart): poprzedni odcinek dołącza,
-- gdy luka ≤ 60 s i między nimi nie zaczęła się żadna przerwa.
create or replace function public.praca_chain_start(p_run uuid)
returns timestamptz language plpgsql stable security definer set search_path = '' as $$
declare
  run public.praca;
  st timestamptz;
  r record;
begin
  select * into run from public.praca where id = p_run;
  if not found then return null; end if;
  st := run.started_at;
  for r in select started_at, ended_at from public.praca
           where user_id = run.user_id and id <> run.id and ended_at is not null
             and ended_at > run.started_at - interval '24 hours'
           order by ended_at desc loop
    continue when r.ended_at > st + interval '60 seconds';   -- kończy się po starcie łańcucha – nie poprzednik
    exit when st - r.ended_at > interval '60 seconds';        -- luka = przerwa
    exit when exists (select 1 from public.przerwy p where p.user_id = run.user_id
                        and p.started_at between r.ended_at - interval '1 second' and st);
    st := least(st, r.started_at);
  end loop;
  return st;
end $$;
revoke all on function public.praca_chain_start(uuid) from public, anon, authenticated;

create or replace function public.praca_label(k text) returns text language sql immutable set search_path = '' as $$
  select case k when 'getmed' then 'GetMed' when 'zlap' then 'Złap Termin' when 'projekty' then 'Moje projekty' else 'pracy' end;
$$;

-- Tyknięcie serwera (pg_cron co 30 s).
create or replace function public.praca_tick()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r record;
  lim int; bmin int; bmax int;
  fin timestamptz;
  n_stop int := 0; n_push1 int := 0; n_push2 int := 0; n_close int := 0;
begin
  -- (a) chodzące odcinki po limicie: zamknij na start łańcucha + limit i zacznij przerwę
  for r in select p.*, coalesce((s.work_break->>'limit_min')::int, 60) as lim
           from public.praca p left join public.settings s on s.user_id = p.user_id
           where p.ended_at is null loop
    fin := greatest(r.started_at, public.praca_chain_start(r.id) + make_interval(mins => r.lim));
    if now() >= fin then
      update public.praca set ended_at = fin where id = r.id and ended_at is null;
      if found then
        insert into public.przerwy (user_id, started_at, kind, auto) values (r.user_id, fin, r.kind, true)
          on conflict do nothing;
        n_stop := n_stop + 1;
      end if;
    end if;
  end loop;

  -- (b) świeża przerwa po automatycznym stopie: „wstań od komputera”
  for r in select b.*, coalesce((s.work_break->>'limit_min')::int, 60) as lim,
                  coalesce((s.work_break->>'break_min')::int, 5) as bmin,
                  coalesce((s.work_break->>'break_max')::int, 15) as bmax
           from public.przerwy b left join public.settings s on s.user_id = b.user_id
           where b.ended_at is null and b.auto and b.push_stop_at is null
             and b.started_at > now() - interval '5 minutes' loop
    update public.przerwy set push_stop_at = now() where id = r.id and push_stop_at is null;
    if found then
      perform public.push_send(r.user_id, 'Przerwa ' || r.bmin || '–' || r.bmax || ' min',
        case when r.lim = 60 then 'Godzina pracy' else r.lim || ' min pracy' end
          || ' (' || public.praca_label(r.kind) || ') zapisana. Wstań od komputera.');
      n_push1 := n_push1 + 1;
    end if;
  end loop;

  -- (c) koniec przerwy (break_max minął, najwyżej 5 min temu): „wracasz do …?”
  for r in select b.*, coalesce((s.work_break->>'break_max')::int, 15) as bmax
           from public.przerwy b left join public.settings s on s.user_id = b.user_id
           where b.ended_at is null and b.push_end_at is null
             and now() >= b.started_at + make_interval(mins => coalesce((s.work_break->>'break_max')::int, 15))
             and now() <  b.started_at + make_interval(mins => coalesce((s.work_break->>'break_max')::int, 15) + 5) loop
    update public.przerwy set push_end_at = now() where id = r.id and push_end_at is null;
    if found then
      perform public.push_send(r.user_id, 'Koniec przerwy',
        'Minęło ' || r.bmax || ' min – wracasz do ' || public.praca_label(r.kind) || '?');
      n_push2 := n_push2 + 1;
    end if;
  end loop;

  -- (d) przerwy zapomniane (> 2 h): zamknij na start + break_max
  update public.przerwy b set ended_at = b.started_at + make_interval(mins => coalesce((s.work_break->>'break_max')::int, 15))
    from public.settings s
    where s.user_id = b.user_id and b.ended_at is null and b.started_at < now() - interval '2 hours';
  get diagnostics n_close = row_count;
  update public.przerwy b set ended_at = b.started_at + interval '15 minutes'
    where b.ended_at is null and b.started_at < now() - interval '2 hours';

  return jsonb_build_object('stop', n_stop, 'push_stop', n_push1, 'push_end', n_push2, 'closed', n_close);
end $$;
revoke all on function public.praca_tick() from public, anon, authenticated;

-- Harmonogram: co 30 s (pg_cron 1.6).
select cron.schedule('praca-tick', '30 seconds', $$select public.praca_tick()$$);

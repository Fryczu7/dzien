-- Okno do Obsidiana: odczyt bazy przez program na laptopie (obsidian-okno/ w repo CEO).
-- Docelowe miejsce pliku: dzien-app/supabase/migrations/20261008_okno_obsidian.sql (kopia).
-- Dostęp: długi losowy kod w lokalnym .env (poza gitem). W bazie leży tylko jego sha256.
-- Program woła /rest/v1/rpc/okno_eksport kluczem publicznym; bez właściwego kodu funkcja rzuca błąd.
-- Funkcja tylko czyta. Filtr prywatności jest tutaj, więc wrażliwe dane w ogóle nie wychodzą z bazy:
-- leki tylko jako true/false, zasady tylko jako liczba złamanych, bez „Doceniam” i oceny wieczoru.
-- Zmiana kodu: update public.okno_klucze set token_hash = '<nowy sha256>' where user_id = …

create table if not exists public.okno_klucze (
  user_id uuid primary key references auth.users(id) on delete cascade,
  token_hash text not null unique,
  created_at timestamptz not null default now()
);
-- RLS bez żadnej polityki = z API nikt nie czyta ani nie pisze (tylko funkcja i rola serwisowa).
alter table public.okno_klucze enable row level security;
revoke all on public.okno_klucze from anon, authenticated;

create or replace function public.okno_eksport(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare uid uuid;
begin
  if p_token is null or length(p_token) < 40 then
    raise exception 'zly kod' using errcode = '28000';
  end if;
  select user_id into uid from public.okno_klucze
   where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  if uid is null then
    raise exception 'zly kod' using errcode = '28000';
  end if;

  return jsonb_build_object(
    'wygenerowano', now(),
    'normy', (select jsonb_build_object('kcal', s.kcal_target, 'protein', s.protein_target)
      from public.settings s where s.user_id = uid),
    'cele', coalesce((select jsonb_agg(jsonb_build_object(
        'id', g.id, 'title', g.title, 'metric', g.metric, 'deadline', g.deadline, 'status', g.status,
        'progress', g.progress, 'where_now', g.where_now, 'next_step', g.next_step) order by g.id)
      from public.goals g where g.user_id = uid), '[]'),
    'pamiec', coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'kind', m.kind, 'title', m.title, 'body', m.body, 'goal_id', m.goal_id,
        'links', coalesce(to_jsonb(m.links), '[]'), 'status', m.status, 'due', m.due,
        'last_touched', m.last_touched, 'source', m.source, 'created', m.created_at::date) order by m.created_at)
      from public.memory m where m.user_id = uid), '[]'),
    'coach', coalesce((select jsonb_agg(jsonb_build_object(
        'date', c.date, 'kind', c.kind, 'morning', c.morning, 'report', c.report,
        'work', coalesce(c.work, '[]')) order by c.date, c.created_at)
      from public.coach c where c.user_id = uid), '[]'),
    -- Propozycje asystenta (od 8.10). Check-iny wieczoru (nastrój, blokada) i coach_evening celowo pominięte – prywatne.
    'propozycje', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'date', p.date, 'kind', p.kind, 'title', p.title, 'why', p.why, 'detail', p.detail,
        'goal_id', p.goal_id, 'status', p.status, 'reply', p.reply) order by p.date, p.created_at)
      from public.propozycje p where p.user_id = uid), '[]'),
    'dni', coalesce((select jsonb_agg(jsonb_build_object(
        'date', d.date, 'bed', d.bed, 'wake', d.wake, 'sleep_h', d.sleep_h,
        'training', d.training, 'rehab', d.rehab, 'closed', d.closed,
        'kcal_target', d.kcal_target, 'protein_target', d.protein_target,
        'leki', case when d.morning ? 'leki' then (d.morning->>'leki') = 'true' end,
        'zasady_zlamane', case when jsonb_typeof(d.rules_broken) = 'array' then jsonb_array_length(d.rules_broken) end,
        'plan', case when jsonb_typeof(d.plan) = 'array' then (
            select coalesce(jsonb_agg(jsonb_build_object('text', p->>'text', 'done', coalesce((p->>'done')::boolean, false))), '[]')
            from jsonb_array_elements(d.plan) p where jsonb_typeof(p) = 'object') else '[]' end,
        'coach_morning', d.coach_morning,
        'kcal', (select sum(x.kcal) from public.meals x where x.user_id = uid and x.date = d.date),
        'protein', (select sum(x.protein) from public.meals x where x.user_id = uid and x.date = d.date),
        'treningi', (select coalesce(jsonb_agg(jsonb_build_object('name', w.name, 'kind', w.kind,
            'serie', (select count(*) from public.workout_sets s where s.workout_id = w.id and not coalesce(s.warmup, false)))), '[]')
            from public.workouts w where w.user_id = uid and w.date = d.date)
      ) order by d.date)
      from public.days d where d.user_id = uid), '[]')
  );
end $$;

revoke all on function public.okno_eksport(text) from public;
-- Tylko anon: program nie loguje się kontem. Ostrzeżenie „anon może wywołać SECURITY DEFINER” jest zamierzone –
-- bez właściwego kodu funkcja rzuca błąd i niczego nie zwraca.
grant execute on function public.okno_eksport(text) to anon;
revoke execute on function public.okno_eksport(text) from authenticated;

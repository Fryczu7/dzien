-- Zapis coacha nocnego przez funkcje. Powód: konektor Supabase prosi o potwierdzenie każdego UPDATE,
-- a w nocy nie ma kto kliknąć. Wywołanie „select public.coach_…(…)” nie wymaga potwierdzenia.
-- UWAGA: to NIE jest twarde ograniczenie – konektor działa jako postgres i zwykły INSERT do dowolnej
-- tabeli też przejdzie bez potwierdzenia. Granice zapisu trzyma prompt (rutyny/coach-nocny.md).
-- Właściciel: konto mfryczu@gmail.com.
-- Funkcje dostępne tylko dla roli serwisowej (konektor), nie dla anon/authenticated z apki.

create or replace function public.coach_owner() returns uuid
language sql stable security definer set search_path = public, auth as $$
  select id from auth.users where email = 'mfryczu@gmail.com'
$$;

-- Cel: gdzie jestem, postęp, następny krok. Puste argumenty (null) zostawiają starą wartość.
create or replace function public.coach_goal(p_id text, p_where text, p_progress int default null, p_next text default null)
returns text language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.goals set
    where_now = coalesce(p_where, where_now),
    progress = coalesce(least(greatest(p_progress, 0), 100), progress),
    next_step = coalesce(p_next, next_step),
    updated_at = now()
  where user_id = public.coach_owner() and id = p_id;
  get diagnostics n = row_count;
  return case when n = 1 then 'ok ' || p_id else 'brak celu ' || p_id end;
end $$;

-- Wpis pamięci: dopisz linię do body, odśwież last_touched, opcjonalnie zmień status/cel/termin.
create or replace function public.coach_memory(p_id uuid, p_append text, p_status text default null, p_goal text default null, p_due date default null)
returns text language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.memory set
    body = case when coalesce(p_append, '') = '' then body else body || E'\n' || p_append end,
    status = coalesce(p_status, status),
    goal_id = coalesce(p_goal, goal_id),
    due = coalesce(p_due, due),
    last_touched = (now() at time zone 'Europe/Warsaw')::date,
    updated_at = now()
  where user_id = public.coach_owner() and id = p_id;
  get diagnostics n = row_count;
  return case when n = 1 then 'ok' else 'brak wpisu' end;
end $$;

-- Notatki z apki przetworzone.
create or replace function public.coach_notes_done(p_ids uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.notes set processed = true where user_id = public.coach_owner() and id = any(p_ids);
  get diagnostics n = row_count;
  return n;
end $$;

-- Zapis nocy: wiersz coach (bez duplikatów) + dla 'noc' karta na rano w days.coach_morning (tylko ta kolumna).
create or replace function public.coach_save(p_date date, p_kind text, p_morning text, p_report text, p_work jsonb default '[]')
returns text language plpgsql security definer set search_path = public as $$
declare u uuid := public.coach_owner();
begin
  insert into public.coach (user_id, date, kind, morning, report, work)
  values (u, p_date, p_kind, coalesce(p_morning, ''), coalesce(p_report, ''), coalesce(p_work, '[]'::jsonb))
  on conflict (user_id, date, kind) do update
    set morning = excluded.morning, report = excluded.report, work = excluded.work, created_at = now();
  if p_kind = 'noc' then
    insert into public.days (user_id, date, coach_morning) values (u, p_date, p_morning)
    on conflict (user_id, date) do update set coach_morning = excluded.coach_morning;
  end if;
  return 'ok ' || p_kind || ' ' || p_date;
end $$;

revoke all on function public.coach_owner(), public.coach_goal(text, text, int, text),
  public.coach_memory(uuid, text, text, text, date), public.coach_notes_done(uuid[]),
  public.coach_save(date, text, text, text, jsonb) from public, anon, authenticated;

-- Poprawka: greatest/least pomijają null, więc coach_goal(…, null, …) zerował postęp celu.
-- Ta sama sygnatura (create or replace) – uprawnienia z 20261006_coach_funkcje.sql zostają.
create or replace function public.coach_goal(p_id text, p_where text, p_progress int default null, p_next text default null)
returns text language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.goals set
    where_now = coalesce(p_where, where_now),
    progress = case when p_progress is null then progress else least(greatest(p_progress, 0), 100) end,
    next_step = coalesce(p_next, next_step),
    updated_at = now()
  where user_id = public.coach_owner() and id = p_id;
  get diagnostics n = row_count;
  return case when n = 1 then 'ok ' || p_id else 'brak celu ' || p_id end;
end $$;

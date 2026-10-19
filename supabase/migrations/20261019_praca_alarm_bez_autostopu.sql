-- Stoper pracy: po godzinie NIE przełącza sam na przerwę (decyzja Michała 19.10).
-- Zamiast automatycznego stopu: powiadomienie push „Minęła godzina pracy – kliknij, żeby zrobić przerwę”,
-- potem przypomnienie co 15 min, najwyżej przez 2 h od alarmu (bez zalewania). Przerwę włącza dopiero kliknięcie w apce.
-- „Pracuję dalej” w apce zapisuje praca.snooze_until = teraz + limit – alarm czeka do tej chwili.
-- Ta sama zasada co lib.js workAlarm / workAlarmMsg – zmieniając tu, zmień też tam.

alter table public.praca add column if not exists snooze_until timestamptz; -- „Pracuję dalej”: alarm nie wcześniej niż wtedy
alter table public.praca add column if not exists push_at timestamptz;      -- kiedy serwer ostatnio wysłał alarm (bez dubli)

create or replace function public.praca_tick()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r record;
  cs timestamptz; due timestamptz; slot_at timestamptz;
  slot int; mins int;
  n_alarm int := 0; n_push1 int := 0; n_push2 int := 0; n_close int := 0;
begin
  -- (a) chodzące odcinki po limicie: NIE zamykamy – tylko alarm push (slot 0 = pierwszy, potem co 15 min, do 2 h)
  for r in select p.*, coalesce((s.work_break->>'limit_min')::int, 60) as lim
           from public.praca p left join public.settings s on s.user_id = p.user_id
           where p.ended_at is null loop
    cs := public.praca_chain_start(r.id);
    due := greatest(r.started_at, cs + make_interval(mins => r.lim), coalesce(r.snooze_until, '-infinity'::timestamptz));
    continue when now() < due or now() >= due + interval '2 hours';
    slot := floor(extract(epoch from now() - due) / 900)::int;
    slot_at := due + make_interval(mins => slot * 15);
    continue when r.push_at is not null and r.push_at >= slot_at; -- ten slot już wysłany
    update public.praca set push_at = now()
      where id = r.id and ended_at is null and push_at is not distinct from r.push_at;
    if found then
      mins := floor(extract(epoch from now() - cs) / 60)::int;
      perform public.push_send(r.user_id,
        case when slot = 0 then case when r.lim = 60 then 'Minęła godzina pracy' else 'Minęło ' || r.lim || ' min pracy' end
             else 'Czas na przerwę – pracujesz już ' || (mins / 60) || ':' || lpad((mins % 60)::text, 2, '0') end,
        'Kliknij, żeby zrobić przerwę. Stoper liczy dalej (' || public.praca_label(r.kind) || ').');
      n_alarm := n_alarm + 1;
    end if;
  end loop;

  -- (b) przerwa z auto = true (zakładały ją stare wersje apki): „wstań od komputera” – bez zmian
  for r in select b.*, coalesce((s.work_break->>'limit_min')::int, 60) as lim,
                  coalesce((s.work_break->>'break_min')::int, 5) as bmin,
                  coalesce((s.work_break->>'break_max')::int, 15) as bmax
           from public.przerwy b left join public.settings s on s.user_id = b.user_id
           where b.ended_at is null and b.auto and b.push_stop_at is null
             and b.started_at > now() - interval '5 minutes' loop
    update public.przerwy set push_stop_at = now() where id = r.id and push_stop_at is null;
    if found then
      perform public.push_send(r.user_id, '[ KUŹNIA ] Zadanie ukończone',
        r.lim || ' min skupienia: ' || public.praca_label(r.kind) || '. Czas regeneracji: '
          || r.bmin || '–' || r.bmax || ' min. Wstań od komputera.');
      n_push1 := n_push1 + 1;
    end if;
  end loop;

  -- (c) koniec przerwy (break_max minął, najwyżej 5 min temu) – bez zmian
  for r in select b.*, coalesce((s.work_break->>'break_max')::int, 15) as bmax
           from public.przerwy b left join public.settings s on s.user_id = b.user_id
           where b.ended_at is null and b.push_end_at is null
             and now() >= b.started_at + make_interval(mins => coalesce((s.work_break->>'break_max')::int, 15))
             and now() <  b.started_at + make_interval(mins => coalesce((s.work_break->>'break_max')::int, 15) + 5) loop
    update public.przerwy set push_end_at = now() where id = r.id and push_end_at is null;
    if found then
      perform public.push_send(r.user_id, '[ KUŹNIA ] Regeneracja zakończona',
        'Siły odnowione. Następne zadanie: ' || public.praca_label(r.kind) || '. Wracasz?');
      n_push2 := n_push2 + 1;
    end if;
  end loop;

  -- (d) przerwy zapomniane (> 2 h): zamknij na start + break_max – zabezpieczenie danych, bez zmian
  update public.przerwy b set ended_at = b.started_at + make_interval(mins => coalesce((s.work_break->>'break_max')::int, 15))
    from public.settings s
    where s.user_id = b.user_id and b.ended_at is null and b.started_at < now() - interval '2 hours';
  get diagnostics n_close = row_count;
  update public.przerwy b set ended_at = b.started_at + interval '15 minutes'
    where b.ended_at is null and b.started_at < now() - interval '2 hours';

  return jsonb_build_object('alarm', n_alarm, 'push_stop', n_push1, 'push_end', n_push2, 'closed', n_close);
end $$;
revoke all on function public.praca_tick() from public, anon, authenticated;

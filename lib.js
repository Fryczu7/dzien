// Czyste funkcje apki Dzień – bez DOM i bez sieci, testowane w Node (node --test "test/*.test.mjs").
export const ymd = d => { const z = new Date(d.getTime() - d.getTimezoneOffset() * 60000); return z.toISOString().slice(0, 10); };

export function hoursBetween(b, w) {
  if (!b || !w) return null;
  const [bh, bm] = b.split(':').map(Number), [wh, wm] = w.split(':').map(Number);
  let mins = (wh * 60 + wm) - (bh * 60 + bm); if (mins <= 0) mins += 1440;
  return Math.round(mins / 6) / 10;
}

export const isFuture = (date, today) => date > today;

export function mealTime(cur, now) {
  if (cur !== ymd(now)) return null;
  return String(now.getHours()).padStart(2, '0') + ':' + String(now.getMinutes()).padStart(2, '0');
}

export function ruleState(nr, broken, done) {
  if (broken.includes(nr)) return 'broken';
  return done ? 'ok' : 'unset';
}

export const dayOnResume = (cur, followToday, now) => followToday ? ymd(now) : cur;

// Daty jako tekst RRRR-MM-DD; arytmetyka w UTC, żeby zmiana czasu nie przesuwała dni.
export const addDays = (s, n) => { const d = new Date(s + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
export const weekStart = s => { const dow = (new Date(s + 'T00:00:00Z').getUTCDay() + 6) % 7; return addDays(s, -dow); };

// Luka = dni bez żadnych wpisów, kończące się wczoraj, po ostatnim aktywnym dniu (szukamy max 7 dni wstecz).
// Nowe konto bez historii nie dostaje pytania o nadrabianie; dni pokryte nadrobieniem nie są luką.
export function findGap(active, catchups, today, maxBack = 7) {
  const covered = d => catchups.some(c => c.from_date <= d && d <= c.to_date);
  const empty = [];
  for (let i = 1; i <= maxBack; i++) {
    const d = addDays(today, -i);
    if (active.has(d)) break;
    if (i === maxBack) return null;
    empty.push(d);
  }
  const open = empty.filter(d => !covered(d));
  if (!open.length) return null;
  return { from: open[open.length - 1], to: open[0], days: open.length };
}

// Zestawienie tygodnia (pon–dziś): dni z apki + nadrobienia. Nadrobienie zachodzące na inny tydzień
// liczy się proporcjonalnie do swoich dni w tym tygodniu (luka czw–pon dodaje 1/5 do tego tygodnia).
export function weekStats(days, catchups, today) {
  const from = weekStart(today), inWeek = d => from <= d && d <= today;
  const nDays = (a, b) => Math.round((Date.parse(b) - Date.parse(a)) / 864e5) + 1;
  const w = days.filter(d => inWeek(d.date));
  const c = catchups.map(x => {
    const a = x.from_date > from ? x.from_date : from, b = x.to_date < today ? x.to_date : today;
    return { ...x, part: a <= b ? nDays(a, b) : 0, frac: a <= b ? nDays(a, b) / nDays(x.from_date, x.to_date) : 0 };
  }).filter(x => x.part > 0);
  const sum = key => c.reduce((s, x) => s + (x[key] || 0) * x.frac, 0);
  let sleepSum = 0, sleepN = 0;
  for (const d of w) if (d.sleep_h) { sleepSum += Number(d.sleep_h); sleepN++; }
  for (const x of c) if (x.sleep_h) { sleepSum += Number(x.sleep_h) * x.part; sleepN += x.part; }
  return {
    rehab: w.filter(d => d.rehab).length + Math.round(sum('rehab_count')),
    training: w.filter(d => isTrainingText(d.training)).length + Math.round(sum('training_count')),
    meds: w.filter(d => d.morning?.leki).length + Math.round(sum('meds_days')),
    daysSoFar: Math.round((Date.parse(today) - Date.parse(from)) / 864e5) + 1,
    sleepAvg: sleepN ? Math.round(sleepSum / sleepN * 10) / 10 : null,
  };
}

// Pora dnia ekranu „Dziś”: rano dopóki poranek nieodhaczony (do 14:00), wieczór od 20:00 do 4:00.
export function partOfDay(hour, morningDone) {
  if (hour >= 20 || hour < 4) return 'wieczor';
  if (!morningDone && hour < 14) return 'rano';
  return 'dzien';
}

// Plan dnia bez rzeczy, które mają własne przyciski (rehab, leki) – żeby nie było ich dwa razy. Indeks = pozycja w pełnym planie.
export const planWithoutToggles = plan => (plan || []).map((p, idx) => ({ p, idx })).filter(({ p }) => !/^\s*(rehab|leki)/i.test(p.text || ''));

// Karta coacha: „1. co | dlaczego”, a bez „|” – pierwsze zdanie to „co”. Linia „W nocy zrobiłem: …” osobno.
export function parseCoach(text) {
  const items = []; let night = null;
  for (const raw of String(text || '').split('\n')) {
    const line = raw.trim(); if (!line) continue;
    const n = line.match(/^w nocy zrobiłem:\s*(.*)$/i); if (n) { night = n[1]; continue; }
    const body = line.replace(/^(\d+[.)]|[•\-–])\s*/, '');
    let what, why;
    if (body.includes(' | ')) [what, why] = body.split(' | ', 2);
    else { const m = body.match(/^(.+?[^0-9A-ZŁŚŻŹĆŃÓĘĄ])\.\s+(.+)$/); what = m ? m[1] : body.replace(/\.$/, ''); why = m ? m[2] : ''; }
    items.push({ what: what.trim(), why: (why || '').trim() });
  }
  return { items, night };
}

const norm = s => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/ł/g, 'l').trim();
export const matchesQuery = (name, q) => !q || norm(name).includes(norm(q));

// „Szybko”: wszystko, co już jadł (z kaloriami), najczęstsze na górze; wartości z ostatniego razu (rows od najnowszych).
export function quickFromHistory(rows, presets = []) {
  const map = new Map();
  for (const r of rows) {
    if (r.kcal == null || !r.name) continue;
    const k = norm(r.name);
    if (map.has(k)) map.get(k).n++; else map.set(k, { name: r.name.trim(), kcal: r.kcal, protein: r.protein, n: 1 });
  }
  for (const [name, kcal, protein] of presets) if (!map.has(norm(name))) map.set(norm(name), { name, kcal, protein, n: 0 });
  return [...map.values()].sort((a, b) => b.n - a.n || a.name.localeCompare(b.name, 'pl'));
}

// Przesunięcie palcem: następna/poprzednia zakładka, na końcach zostaje.
export const nextView = (views, v, dir) => views[Math.max(0, Math.min(views.length - 1, views.indexOf(v) + dir))];

const posilki = n => n === 1 ? 'posiłek' : (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) ? 'posiłki' : 'posiłków';

// Lista „Brakuje: …” – tylko rzeczy, które da się dziś jeszcze zrobić albo dopowiedzieć Claude.
export function missingToday(day, meals, cfg, hour) {
  const out = [];
  if (!day.rehab) out.push('rehab');
  if (!day.morning?.leki) out.push('leki rano');
  if ((hour >= 20 || hour < 4) && !day.evening?.leki_wieczor) out.push('leki wieczorem');
  const kcal = meals.reduce((a, m) => a + (m.kcal || 0), 0), target = day.kcal_target || cfg.kcal_target;
  // Kalorie dopiero od 18:00 – wcześniej „brakuje 3300 kcal” to plan dnia, nie zaległość.
  if (target && kcal < target && (hour >= 18 || hour < 4)) out.push((target - kcal) + ' kcal');
  const bez = meals.filter(m => m.kcal == null).length;
  if (bez) out.push(bez + ' ' + posilki(bez) + ' bez kalorii');
  return out;
}

// ---------- Treningi (tylko odczyt; serie wpisuje Claude) ----------
// Zakres powtórzeń z planu: „6-10” → {min 6, max 10}, „10” → {10, 10}; „max” albo brak → null.
export function parseRange(reps) {
  const m = String(reps ?? '').match(/^\s*(\d+)\s*(?:[-–]\s*(\d+))?\s*$/);
  return m ? { min: +m[1], max: +(m[2] ?? m[1]) } : null;
}

// Najnowsze na górze; trening bez daty (import historii) uznajemy za najstarszy.
export const sortWorkouts = ws => [...ws].sort((a, b) =>
  (a.date ? 0 : 1) - (b.date ? 0 : 1) || (b.date || '').localeCompare(a.date || '') || String(b.created_at || '').localeCompare(String(a.created_at || '')));

const better = (a, b) => (Number(a.kg) || 0) - (Number(b.kg) || 0) || (a.reps || 0) - (b.reps || 0);

// Najlepsza seria robocza jednego treningu: bez rozgrzewek; jeśli plan ma zakres, liczą się serie z co najmniej
// dolną granicą powtórzeń (55×5 przy zakresie 6–10 to nieudana próba, nie wynik). Gdy żadna nie łapie się w zakres – najlepsza z roboczych.
export function bestSet(sets, range) {
  const work = sets.filter(s => !s.warmup && s.reps != null);
  if (!work.length) return null;
  const inRange = range ? work.filter(s => s.reps >= range.min) : work;
  return (inRange.length ? inRange : work).reduce((a, b) => better(b, a) > 0 ? b : a);
}

// Następny cel wg zasady Michała: najpierw powtórzenia do góry zakresu, potem ciężar.
export function nextTarget(best, range) {
  if (!best || !range) return null;
  const kg = best.kg == null ? 'masa ciała' : fmtKg(best.kg) + ' kg';
  if (best.reps < range.max) return kg + ' × ' + (best.reps + 1);
  return best.kg == null ? 'dociążenie albo więcej powtórzeń' : 'więcej kg × ' + range.min;
}

export const fmtKg = kg => String(Number(kg)).replace('.', ',');
export const fmtSet = s => (s.kg == null ? 'masa ciała' : fmtKg(s.kg) + ' kg') + ' × ' + s.reps;

// Postęp dla każdego ćwiczenia: ostatni najlepszy wynik, poprzedni (z wcześniejszego treningu) i kierunek.
// workouts: [{date, name, created_at, workout_sets: [...]}], plans: [{exercises: [{name, reps}]}].
export function exerciseProgress(workouts, plans = []) {
  const ranges = new Map();
  for (const p of plans) for (const e of p.exercises || []) ranges.set(norm(e.name), parseRange(e.reps));
  const out = new Map();
  for (const w of sortWorkouts(workouts)) {
    const byEx = new Map();
    for (const s of w.workout_sets || []) { const k = norm(s.exercise); if (!byEx.has(k)) byEx.set(k, []); byEx.get(k).push(s); }
    for (const [k, sets] of byEx) {
      const best = bestSet(sets, ranges.get(k)); if (!best) continue;
      if (!out.has(k)) out.set(k, { name: sets[0].exercise, history: [] });
      out.get(k).history.push({ ...best, date: w.date, workout: w.name });
    }
  }
  for (const [k, p] of out) {
    const [last, prev] = p.history;
    p.last = last; p.prev = prev || null; p.range = ranges.get(k) || null;
    p.trend = prev ? (better(last, prev) > 0 ? 'up' : better(last, prev) < 0 ? 'down' : 'same') : null;
    p.next = nextTarget(last, p.range);
  }
  return out;
}
export const progressFor = (progress, name) => progress.get(norm(name)) || null;

// Ile serii roboczych i rozgrzewkowych w treningu.
export const setCounts = w => { const s = w.workout_sets || []; return { work: s.filter(x => !x.warmup).length, warmup: s.filter(x => x.warmup).length }; };

// Różnica względem poprzedniego wyniku po ludzku: „+2,5 kg”, „+1 powt.”, „bez zmian”.
export function trendLabel(last, prev) {
  if (!last || !prev) return null;
  const dk = (Number(last.kg) || 0) - (Number(prev.kg) || 0), dr = (last.reps || 0) - (prev.reps || 0);
  if (dk) return (dk > 0 ? '+' : '−') + fmtKg(Math.abs(dk)) + ' kg';
  if (dr) return (dr > 0 ? '+' : '−') + Math.abs(dr) + ' powt.';
  return 'bez zmian';
}

// Zrobiony trening z tabeli workouts zaznacza dzień jako treningowy – tydzień na „Dziś” liczy i stare wpisy
// tekstowe (days.training), i nowe treningi, bez podwójnego liczenia jednego dnia.
export function withWorkoutDays(days, workouts) {
  const dates = new Set(workouts.filter(w => w.date && (w.status ?? 'zrobiony') === 'zrobiony').map(w => w.date));
  const out = days.map(d => dates.has(d.date) && !(d.training && d.training.trim()) ? { ...d, training: 'trening' } : d);
  for (const dt of dates) if (!days.some(d => d.date === dt)) out.push({ date: dt, training: 'trening' });
  return out;
}

// Tygodnie pn–nd od bieżącego wstecz: zrobione (każdy trening osobno), odwołane zajęcia, opuszczone, rodzaje.
// Dzień z samym tekstem w days.training (bez wpisu w workouts) liczy się jako jeden trening „inne”.
export function trainingWeeks(workouts, days, today, n = 4) {
  const weeks = [];
  for (let i = 0; i < n; i++) {
    const from = addDays(weekStart(today), -7 * i), to = addDays(from, 6), inW = d => d && from <= d && d <= to && d <= today;
    const ws = workouts.filter(w => inW(w.date)), st = w => w.status ?? 'zrobiony';
    const done = ws.filter(w => st(w) === 'zrobiony'), doneDates = new Set(ws.map(w => w.date));
    const extra = days.filter(d => inW(d.date) && isTrainingText(d.training) && !doneDates.has(d.date));
    const byKind = {};
    for (const w of done) byKind[w.kind || 'inne'] = (byKind[w.kind || 'inne'] || 0) + 1;
    if (extra.length) byKind.inne = (byKind.inne || 0) + extra.length;
    weeks.push({ from, to, done: done.length + extra.length, cancelled: ws.filter(w => st(w) === 'odwolany').length, missed: ws.filter(w => st(w) === 'opuszczony').length, byKind });
  }
  return weeks;
}

// Podsumowanie postępu: ile ćwiczeń (z co najmniej dwoma treningami) idzie w górę, stoi, spada.
export function progressSummary(progress) {
  const s = { up: 0, same: 0, down: 0, first: 0 };
  for (const p of progress.values()) s[p.trend || 'first']++;
  return s;
}

// ---------- Liczniki serii (karta „Ten tydzień” na Dziś), propozycje asystenta (Biorę / Zmień / Nie), check-in ----------
// Seria = kolejne dni wstecz. Dziś jeszcze trwa: jeśli dziś niezrobione, seria liczy się od wczoraj.
export function streakDays(dates, today) {
  let d = dates.has(today) ? today : addDays(today, -1), n = 0;
  while (dates.has(d)) { n++; d = addDays(d, -1); }
  return n;
}

// Dni nadrobienia jako daty – tylko gdy nadrobienie pokrywa całą lukę (rehab każdego dnia, kalorie „tak”).
function catchupDates(catchups, full) {
  const out = [];
  for (const c of catchups) {
    const n = Math.round((Date.parse(c.to_date) - Date.parse(c.from_date)) / 864e5) + 1;
    if (full(c, n)) for (let i = 0; i < n; i++) out.push(addDays(c.from_date, i));
  }
  return out;
}

// Liczniki na „Dziś” i w zakładce Asystent. days z historii (z kcal_target), meals z datą i kcal.
export function counters({ days, meals, catchups = [], workouts = [], today, kcalTarget }) {
  const from = weekStart(today), inWeek = d => from <= d && d <= today;
  const rehab = new Set([...days.filter(d => d.rehab).map(d => d.date), ...catchupDates(catchups, (c, n) => (c.rehab_count || 0) >= n)]);
  const sums = new Map();
  for (const m of meals) if (m.kcal != null) sums.set(m.date, (sums.get(m.date) || 0) + m.kcal);
  const target = d => days.find(x => x.date === d)?.kcal_target || kcalTarget;
  const kcal = new Set([...[...sums].filter(([d, k]) => target && k >= target(d)).map(([d]) => d), ...catchupDates(catchups, c => c.kcal_ok === 'tak')]);
  const ws = weekStats(days, catchups, today);
  return {
    rehabWeek: ws.rehab, rehabStreak: streakDays(rehab, today),
    kcalWeek: [...kcal].filter(inWeek).length, kcalStreak: streakDays(kcal, today),
    daysSoFar: ws.daysSoFar,
    trainingWeek: trainingWeeks(workouts, days, today, 1)[0].done,
  };
}

// Decyzja Michała o propozycji: zmiana w planie dnia + pola do zapisania w propozycje (decided_at dokłada wywołujący).
// Pomysł (kind 'pomysl') nie trafia do planu dnia. Max 3 rzeczy w planie (rehab i leki mają własne przyciski).
export function applyDecision(plan, prop, action, text = '', max = 3) {
  const t = String(text || '').trim();
  if (action === 'nie') return { plan, patch: { status: 'odrzucona', reply: t || null } };
  if (action === 'zmien' && !t) return { error: 'pusto' };
  const patch = action === 'zmien' ? { status: 'zmieniona', reply: t } : { status: 'wzieta', reply: null };
  if (prop.kind === 'pomysl') return { plan, patch };
  const item = { text: action === 'zmien' ? t : prop.title, done: false, src: 'asystent', pid: prop.id };
  const base = plan || [], at = base.findIndex(p => p.pid === prop.id);
  if (at >= 0) return { plan: base.map((p, i) => i === at ? { ...p, text: item.text } : p), patch };
  if (planWithoutToggles(base).length >= max) return { error: 'max3' };
  return { plan: [...base, item], patch };
}
export const undoDecision = (plan, prop) => (plan || []).filter(p => p.pid !== prop.id);

// Propozycje na dziś (do decyzji i już zdecydowane) oraz pomysły (bez względu na datę).
export function splitPropozycje(rows, today) {
  const by = (a, b) => String(a.created_at || '').localeCompare(String(b.created_at || ''));
  const dzis = rows.filter(r => r.kind === 'dzien' && r.date === today).sort(by), ideas = rows.filter(r => r.kind === 'pomysl').sort(by);
  return {
    open: dzis.filter(r => r.status === 'nowa'), decided: dzis.filter(r => r.status !== 'nowa'),
    ideas: ideas.filter(r => r.status === 'nowa'), ideasDecided: ideas.filter(r => r.status !== 'nowa'),
  };
}

// Check-in wieczorny w days.evening – łączymy z tym, co już jest (leki wieczorne, zasady).
export const checkinPatch = (evening, { nastroj, blokada, doceniam }, now) =>
  ({ ...(evening || {}), nastroj, blokada: String(blokada || '').trim(), doceniam: String(doceniam || '').trim(), checkin_at: now.toISOString() });

// Wieczór: krótka ściąga do rozmowy z Claude (od 20:00) – stan dnia w kilku linijkach.
export function eveningBrief(day, meals, cfg, props = []) {
  const k = meals.reduce((a, m) => a + (m.kcal || 0), 0), p = meals.reduce((a, m) => a + (m.protein || 0), 0);
  const kt = day.kcal_target || cfg.kcal_target, pt = day.protein_target || cfg.protein_target, bez = meals.filter(m => m.kcal == null).length;
  const out = ['Kalorie ' + k + ' / ' + kt + (k >= kt ? ' – cel zrobiony' : ' – brakuje ' + (kt - k)) + ' · białko ' + p + ' / ' + pt + ' g' + (bez ? ' · ' + bez + ' ' + posilki(bez) + ' bez kalorii' : '')];
  out.push('Rehab: ' + (day.rehab ? 'zrobiony' : 'nie było') + ' · leki rano: ' + (day.morning?.leki ? 'tak' : 'nie'));
  out.push('Trening: ' + (String(day.training || '').trim() || 'nie było'));
  const plan = planWithoutToggles(day.plan).map(x => x.p), left = plan.filter(x => !x.done).map(x => x.text);
  out.push(plan.length ? 'Plan: ' + (plan.length - left.length) + ' / ' + plan.length + ' zrobione' + (left.length ? ' – zostało: ' + left.join(', ') : '') : 'Plan: pusty');
  if (day.sleep_h) out.push('Sen: ' + String(day.sleep_h).replace('.', ',') + ' h');
  const d = props.filter(x => x.kind === 'dzien'), n = s => d.filter(x => x.status === s).length;
  if (d.length) out.push('Propozycje: wzięte ' + n('wzieta') + ', odrzucone ' + n('odrzucona') + (n('nowa') ? ', bez decyzji ' + n('nowa') : ''));
  return out;
}

// „Napisz do Claude” przy propozycji: gotowa wiadomość do wklejenia w czacie projektu CEO.
export const feedbackMsg = (prop, text) =>
  'Propozycja asystenta na dziś: „' + prop.title + '”.\nMój feedback: ' + String(text || '').trim() + '\nZareaguj na to teraz i zapisz wniosek w pamięci, żeby asystent brał to pod uwagę.';

// Nastrój w check-inie: 1–5 z podpisem (apka i wiadomość do coacha).
export const MOODS = [[1, 'fatalnie'], [2, 'słabo'], [3, 'OK'], [4, 'dobrze'], [5, 'świetnie']];

// „Wyślij coachowi”: wiadomość do rozmowy z Claude, żeby coach odpowiedział od razu i zapisał odpowiedź w apce.
export function checkinMsg(date, ev) {
  const m = MOODS.find(([n]) => n === ev.nastroj), t = s => String(s || '').trim();
  return ['Check-in wieczorny (' + date + ').', 'Nastrój: ' + (m ? m[0] + '/5 (' + m[1] + ')' : '–'),
    t(ev.blokada) ? 'Co blokowało: ' + t(ev.blokada) : '', t(ev.doceniam) ? 'Doceniam się za: ' + t(ev.doceniam) : '',
    'Odpowiedz mi teraz jako coach od mentalu – krótko i wprost. Na koniec zapisz swoją odpowiedź w apce Dzień na ten dzień (funkcja coach_evening_save).']
    .filter(Boolean).join('\n');
}

// ---------- Stoper pracy ----------
// Do czego leci czas (kolejność = kolejność przycisków).
export const WORK = [['getmed', 'GetMed'], ['zlap', 'Złap Termin'], ['projekty', 'Moje projekty']];
const msOf = (r, now) => Math.max(0, (r.ended_at ? Date.parse(r.ended_at) : now) - Date.parse(r.started_at));
// Suma czasu dziś i w tym tygodniu (pon–dziś) na każdą rzecz; chodzący odcinek liczy się do „teraz”.
export function workTotals(rows, today, now) {
  const zero = () => Object.fromEntries(WORK.map(([k]) => [k, 0])), day = zero(), week = zero(), from = weekStart(today);
  for (const r of rows) {
    if (!(r.kind in day)) continue;
    const ms = msOf(r, now);
    if (r.date === today) day[r.kind] += ms;
    if (from <= r.date && r.date <= today) week[r.kind] += ms;
  }
  const running = rows.find(r => !r.ended_at) || null;
  return { day, week, running, runningMs: running ? msOf(running, now) : 0 };
}
// Przerwa co godzinę: po 60 min ciągłej pracy stoper sam staje, odcinek kończy się dokładnie na 60. minucie.
// „Ciągła” = chodzący odcinek plus poprzednie, które przechodzą w siebie bez luki (zmiana „do czego” w trakcie).
// Każda przerwa z tabeli przerwy (sama po godzinie albo kliknięta „Przerwa”, nawet 30-sekundowa) urywa łańcuch.
// Ta sama zasada działa na serwerze (cron w bazie) – zmieniając ją tutaj, zmień też tam.
export const WORK_LIMIT_MS = 60 * 60e3, WORK_JOIN_MS = 60e3, BREAK_MIN_MS = 5 * 60e3, BREAK_MAX_MS = 15 * 60e3;
export function workChainStart(rows, run, joinMs = WORK_JOIN_MS, breaks = []) {
  let start = Date.parse(run.started_at);
  const done = rows.filter(r => r !== run && r.ended_at).sort((a, b) => Date.parse(b.ended_at) - Date.parse(a.ended_at));
  const cut = (from, to) => breaks.some(b => { const s = Date.parse(b.started_at); return s >= from - 1000 && s <= to; });
  for (const r of done) {
    const end = Date.parse(r.ended_at);
    if (end > start + joinMs) continue; // kończy się po starcie łańcucha – nie poprzednik
    if (start - end > joinMs || cut(end, start)) break; // luka albo przerwa = łańcuch się urywa
    start = Math.min(start, Date.parse(r.started_at));
  }
  return start;
}
// Kiedy zamknąć chodzący odcinek: ISO końca (start łańcucha + limit, nie „teraz” – działa też po powrocie z tła) albo null.
export function workAutoStop(rows, now, limitMs = WORK_LIMIT_MS, breaks = []) {
  const run = rows.find(r => !r.ended_at);
  if (!run) return null;
  const end = Math.max(Date.parse(run.started_at), workChainStart(rows, run, WORK_JOIN_MS, breaks) + limitMs);
  return now >= end ? new Date(end).toISOString() : null;
}
// Ile zostało do przerwy (ms) w chodzącym łańcuchu – pod zegarem „do przerwy 0:12:30”. Bez chodzącego: null.
export function workUntilBreak(rows, now, limitMs = WORK_LIMIT_MS, breaks = []) {
  const run = rows.find(r => !r.ended_at);
  return run ? Math.max(0, workChainStart(rows, run, WORK_JOIN_MS, breaks) + limitMs - now) : null;
}
// Ustawienia stopera (settings.work_break) z wartościami domyślnymi; złe liczby → domyślne.
export const WORK_BREAK_DEFAULT = { limit_min: 60, break_min: 5, break_max: 15, sound_stop: 'trzy-tony', sound_end: 'dwa-tony' };
export function workBreakCfg(v) {
  const c = { ...WORK_BREAK_DEFAULT, ...(v || {}) }, ok = (n, lo, hi) => Number.isFinite(n) && n >= lo && n <= hi;
  if (!ok(c.limit_min, 1, 600)) c.limit_min = WORK_BREAK_DEFAULT.limit_min;
  if (!ok(c.break_min, 0, 240)) c.break_min = WORK_BREAK_DEFAULT.break_min;
  if (!ok(c.break_max, 1, 240) || c.break_max < c.break_min) c.break_max = Math.max(WORK_BREAK_DEFAULT.break_max, c.break_min);
  if (c.sound_stop !== 'wlasny' && !SOUNDS_STOP.some(s => s[0] === c.sound_stop)) c.sound_stop = WORK_BREAK_DEFAULT.sound_stop;
  if (c.sound_end !== 'wlasny' && !SOUNDS_END.some(s => s[0] === c.sound_end)) c.sound_end = WORK_BREAK_DEFAULT.sound_end;
  return c;
}
// Dźwięki (Web Audio, bez plików): [id, nazwa, tony]; ton = [Hz, start s, długość s, głośność, kształt, Hz na końcu (opcjonalnie)].
// Pierwsze w listach: w klimacie Kuźni (syntezowane, bez nagrań z anime; nazwy bez Solo Leveling – spec Kuźni). 'wlasny' = plik wgrany w panelu.
export const SOUNDS_STOP = [
  ['system-okno', 'Kuźnia: nowe okno', [[1319, 0, .12, .3, 'sine'], [1661, .07, .12, .3, 'sine'], [1976, .14, .12, .3, 'sine'], [2637, .21, 1.6, .32, 'sine'], [2650, .21, 1.6, .12, 'triangle'], [1319, .21, 1.4, .18, 'sine']]],
  ['system-zadanie', 'Kuźnia: zadanie ukończone', [[440, 0, .16, .45, 'triangle'], [554, .14, .16, .45, 'triangle'], [659, .28, .16, .45, 'triangle'], [880, .42, 1.8, .45, 'triangle'], [1319, .42, 1.8, .22, 'sine'], [220, .42, 1.8, .3, 'sine']]],
  ['level-up', 'Level up', [[300, 0, .5, .25, 'sawtooth', 1200], [523, .45, .15, .4, 'triangle'], [659, .58, .15, .4, 'triangle'], [784, .71, .15, .4, 'triangle'], [1047, .84, 1.6, .45, 'triangle'], [1568, .84, 1.6, .2, 'sine'], [523, .84, 1.6, .25, 'sine']]],
  ['brama', 'Brama się otwiera', [[55, 0, 2.6, .55, 'sine'], [82, 0, 2.4, .35, 'sine'], [110, .1, 2, .25, 'triangle', 165], [1760, 1.2, 1.4, .18, 'sine'], [2637, 1.35, 1.2, .12, 'sine']]],
  ['powstan', 'Kowadło', [[73, 0, .5, .6, 'sine'], [73, .6, .5, .6, 'sine'], [73, 1.2, .5, .6, 'sine'], [147, 1.8, 1.4, .4, 'triangle', 294], [587, 1.8, 1.6, .2, 'sine']]],
  ['trzy-tony', 'Trzy tony w dół ×2', [0, 1.6].flatMap(o => [[880, o, .3, .5, 'square'], [660, o + .35, .3, .5, 'square'], [440, o + .7, .6, .5, 'square']])],
  ['dzwonek', 'Dzwonek szkolny', Array.from({ length: 14 }, (_, i) => [i % 2 ? 784 : 988, i * .12, .11, .4, 'square'])],
  ['budzik', 'Budzik bip-bip', [0, .9, 1.8].flatMap(o => [0, .15, .3, .45].map(d => [1000, o + d, .1, .45, 'square']))],
  ['gong', 'Gong', [[220, 0, 3, .5, 'sine'], [330, 0, 2.6, .3, 'sine'], [440, 0, 2.2, .25, 'sine'], [220, 1.6, 2.5, .4, 'sine']]],
  ['fanfara', 'Fanfara w górę', [[523, 0, .18, .4, 'triangle'], [659, .2, .18, .4, 'triangle'], [784, .4, .18, .4, 'triangle'], [1047, .6, .8, .45, 'triangle'], [784, .95, .15, .35, 'triangle'], [1047, 1.15, 1, .45, 'triangle']]],
  ['syrena', 'Syrena', [[600, 0, .8, .35, 'sawtooth', 1200], [1200, .8, .8, .35, 'sawtooth', 600], [600, 1.6, .8, .35, 'sawtooth', 1200]]],
  ['ping-pong', 'Ping-pong', Array.from({ length: 8 }, (_, i) => [i % 2 ? 880 : 1318, i * .22, .2, .45, 'sine'])],
  ['uderzenia', 'Trzy mocne uderzenia', [0, 1.4].flatMap(o => [0, .35, .7].map(d => [523, o + d, .28, .6, 'triangle']))],
];
export const SOUNDS_END = [
  ['system-ping', 'Kuźnia: iskra', [[1760, 0, .5, .22, 'sine'], [2637, .18, .9, .2, 'sine'], [1760, .18, .9, .06, 'triangle']]],
  ['mana', 'Żar odnowiony', [[1047, 0, .5, .2, 'sine'], [1319, .15, .5, .2, 'sine'], [1568, .3, .5, .2, 'sine'], [2093, .45, 1.4, .22, 'sine']]],
  ['gotowosc', 'Kuźnia: gotowość', [[659, 0, 2.2, .14, 'sine'], [988, .2, 2, .13, 'sine'], [1319, .4, 1.8, .12, 'sine'], [1976, .6, 1.6, .08, 'sine']]],
  ['dwa-tony', 'Dwa tony w górę', [[523, 0, .9, .3, 'sine'], [784, .45, 1.3, .3, 'sine']]],
  ['dzwoneczek', 'Dzwoneczek', [[1568, 0, 1.2, .25, 'sine'], [2093, .25, 1.6, .2, 'sine']]],
  ['kalimba', 'Kalimba', [[659, 0, .6, .3, 'sine'], [784, .25, .6, .3, 'sine'], [988, .5, 1.2, .3, 'sine']]],
  ['miekki-gong', 'Miękki gong', [[196, 0, 3, .35, 'sine'], [294, 0, 2.6, .2, 'sine']]],
  ['ptaszek', 'Ptaszek', [[2000, 0, .15, .15, 'sine', 3000], [2200, .25, .15, .15, 'sine', 3200], [2000, .6, .15, .15, 'sine', 3000]]],
  ['akord', 'Akord', [[523, 0, 2, .18, 'sine'], [659, .05, 2, .16, 'sine'], [784, .1, 2, .15, 'sine']]],
];
export const soundTones = (list, id) => (list.find(s => s[0] === id) || list[0])[2];
// Licznik przerwy: ile trwa i w jakiej fazie (krótka < 5 min, ok 5–15, koniec ≥ 15).
export function breakState(startMs, now, minMs = BREAK_MIN_MS, maxMs = BREAK_MAX_MS) {
  const ms = Math.max(0, now - startMs);
  return { ms, phase: ms < minMs ? 'krotka' : ms < maxMs ? 'ok' : 'koniec' };
}
const pad = n => String(n).padStart(2, '0');
export const fmtClock = ms => { const s = Math.floor(ms / 1000); return Math.floor(s / 3600) + ':' + pad(Math.floor(s / 60) % 60) + ':' + pad(s % 60); };
export const fmtHM = ms => { const m = Math.floor(ms / 60000); return Math.floor(m / 60) + ':' + pad(m % 60); };
export const isWorkday = s => { const d = new Date(s + 'T12:00:00Z').getUTCDay(); return d >= 1 && d <= 5; };
// „dziś 2:10 / 4:00 · tydzień 6:30 / 20:00” – cel dzienny tylko pon–pt, tygodniowy zawsze, Moje projekty bez celu.
export function workLine(kind, totals, targets, today) {
  const t = (targets || {})[kind] || {}, goal = min => min ? ' / ' + fmtHM(min * 60000) : '';
  return 'dziś ' + fmtHM(totals.day[kind]) + (isWorkday(today) ? goal(t.dzien) : '') + ' · tydzień ' + fmtHM(totals.week[kind]) + goal(t.tydzien);
}
export const workBrief = day => {
  const parts = WORK.filter(([k]) => day[k] >= 60000).map(([k, l]) => l + ' ' + fmtHM(day[k]));
  return 'Praca: ' + (parts.length ? parts.join(', ') : 'nic nie zmierzone');
};

// Tekst w days.training mówiący, że treningu NIE było („brak – wspinaczka odpuszczona”), nie liczy się jako trening.
export const isTrainingText = t => { const s = String(t || '').trim().toLowerCase(); return !!s && !/^(brak|nie |nie$|odpuszcz|odwoł|odwol|-|–)/.test(s); };

// ---------- Menu na dziś (tabela menu: układa automat o 5:00, Michał wybiera i klika „zjadłem”) ----------
export const MENU_SRC = { jak_ostatnio: 'jak ostatnio', z_planu: 'z planu', nowe: 'nowe', ustalone: 'ustalone' };
export const menuChosen = s => typeof s?.chosen === 'number' && s.options?.[s.chosen] ? s.options[s.chosen] : null;
const minsOf = t => { const m = String(t || '').match(/^(\d{1,2}):(\d{2})/); return m ? +m[1] * 60 + +m[2] : 1e4; };
export const nowMins = d => d.getHours() * 60 + d.getMinutes();
// Posiłek bez wyboru znika 2 h po swojej porze (decyzja Michała 14.10); na minionym dniu od razu.
// now = minuty od północy dla dziś, 'miniony' dla wcześniejszego dnia, null = nic nie chowamy.
export const MENU_HIDE_AFTER = 120;
export const slotGone = (s, now) => !menuChosen(s) && !s.eaten && (now === 'miniony' || (typeof now === 'number' && now >= minsOf(s.time) + MENU_HIDE_AFTER));
// Suma dnia z menu: stałe + wybrane opcje (albo „coś innego”); „open” = widoczne posiłki jeszcze bez wyboru.
export function menuTotals(menu, now = null) {
  const out = { kcal: 0, protein: 0, open: [] };
  if (!menu) return out;
  const add = x => { out.kcal += Number(x.kcal) || 0; out.protein += Number(x.protein) || 0; };
  for (const x of menu.stale || []) add(x);
  for (const s of menu.slots || []) { const o = s.inne || menuChosen(s); if (o) add(o); else if (!slotGone(s, now)) out.open.push(s.label || s.slot); }
  return out;
}
// Co z menu jeszcze przed Tobą: wybrane, niezjedzone posiłki + niezjedzone stałe (do „zjedzone + zostało w planie”).
export function menuLeft(menu) {
  const out = { kcal: 0, protein: 0 };
  if (!menu) return out;
  const add = x => { out.kcal += Number(x.kcal) || 0; out.protein += Number(x.protein) || 0; };
  for (const x of menu.stale || []) if (!x.eaten) add(x);
  for (const s of menu.slots || []) { const o = menuChosen(s); if (o && !s.eaten) add(o); }
  return out;
}
// „Wybierz menu →” na Dziś: któryś widoczny posiłek nie ma wyboru (zjedzony albo miniony nie wisi).
export const menuNeedsChoice = (menu, now = null) => !!menu && (menu.slots || []).some(s => !menuChosen(s) && !s.eaten && !slotGone(s, now));
// Wybór opcji: nowa tablica slots (zmienia tylko ten posiłek); zjedzonego nie zmieniamy → null.
export function chooseOption(slots, si, oi) {
  const s = slots?.[si];
  if (!s || s.eaten || !s.options?.[oi]) return null;
  return slots.map((x, i) => i === si ? { ...x, chosen: oi } : x);
}
// „Zjadłem”: posiłek do meals + zmiana w menu (eaten). kind 'slot' (indeks posiłku) albo 'stale' (indeks stałej).
// null, gdy już zjedzone albo nic nie wybrane – drugi klik nie robi drugiego wpisu.
export function eatItem(menu, kind, i) {
  const key = kind === 'slot' ? 'slots' : 'stale', list = menu?.[key], x = list?.[i];
  if (!x || x.eaten) return null;
  const o = kind === 'slot' ? menuChosen(x) : x;
  if (!o) return null;
  return { meal: { name: o.name, kcal: o.kcal ?? null, protein: o.protein ?? null }, patch: { [key]: list.map((y, j) => j === i ? { ...y, eaten: true } : y) } };
}
// „Jadłem coś innego” w posiłku si: wpis do meals (kalorie mogą być puste – policzy Claude) + posiłek zamknięty (eaten, inne).
export function eatOther(menu, si, { name, kcal = null, protein = null }) {
  const list = menu?.slots, x = list?.[si], n = String(name || '').trim();
  if (!x || x.eaten || !n) return null;
  const meal = { name: n, kcal: kcal || null, protein: kcal ? (protein ?? null) : null };
  return { meal, patch: { slots: list.map((y, j) => j === si ? { ...y, eaten: true, inne: meal } : y) } };
}
// Cofnięcie „zjadłem” / „coś innego” (po usunięciu posiłku z meals).
export function uneatItem(menu, kind, i) {
  const key = kind === 'slot' ? 'slots' : 'stale';
  return { [key]: (menu?.[key] || []).map((y, j) => { if (j !== i) return y; const { inne, ...rest } = y; return { ...rest, eaten: false, meal_id: null }; }) };
}
// Posiłki po godzinie; „9:30” i „09:30” tak samo, bez godziny na końcu. Stałe osobno (bez godzin – decyzja 14.10).
export function menuTimeline(menu) {
  if (!menu) return [];
  return (menu.slots || []).map((x, i) => ({ kind: 'slot', i, x })).sort((a, b) => minsOf(a.x.time) - minsOf(b.x.time));
}
// „Powiedz Claude” przy posiłku: Claude liczy kalorie i zamyka posiłek w menu jedną funkcją.
export const menuOtherMsg = (date, slot, label) =>
  'Menu ' + date + ', ' + String(label || slot).toLowerCase() + ': zjadłem coś innego niż w menu. Policz kalorie i białko i zapisz jednym wywołaniem: ' +
  "select public.menu_zjedzone('" + date + "', '" + slot + "', '<nazwa>', <kcal>, <białko>).\nZjadłem: ";

// ---------- Panel ustawień ----------
// Karty na „Dziś” i zakładki, które można wyłączyć (klucze w settings.ui.off; zakładki z przedrostkiem „tab-”).
export const PANEL_CARDS = [['propozycje', 'Propozycje asystenta'], ['obserwacje', 'Czego się nauczyłem (niedziela)'], ['rano', 'Rano – rzeczy do odhaczenia'], ['modlitwy', 'Modlitwy'], ['plan', 'Plan na dziś'], ['tydzien', 'Ten tydzień'], ['sen', 'Sen i trening'], ['wieczor', 'Wieczór (ściąga, check-in, zamknięcie dnia)'], ['praca', 'Stoper pracy']];
export const PANEL_TABS = [['jedzenie', 'Jedzenie'], ['zakupy', 'Zakupy'], ['trening', 'Trening'], ['asystent', 'Asystent'], ['coach', 'Coach']];
export const visibleViews = (views, off = []) => views.filter(v => v === 'dzis' || !off.includes('tab-' + v));
// Klucz nowej rzeczy porannej z jej nazwy (bez polskich znaków), bez powtórek.
export function itemKey(label, items = []) {
  const base = norm(label).replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '') || 'rzecz';
  const used = new Set(items.map(([k]) => k)); let k = base, n = 2;
  while (used.has(k)) k = base + '_' + n++;
  return k;
}
// Godziny wpisane w panelu („4”, „4,5”, „3:30”) → minuty; minuty → „4,5”.
export function parseHours(v) {
  const s = String(v ?? '').trim(); let m;
  if ((m = s.match(/^(\d+):(\d{1,2})$/))) return +m[1] * 60 + +m[2];
  const h = parseFloat(s.replace(',', '.'));
  return Number.isFinite(h) && h >= 0 && /^[\d.,]+$/.test(s) ? Math.round(h * 60) : null;
}
export const fmtHoursInput = min => String(Math.round(min / 6) / 10).replace('.', ',');

// Link do rozmowy z Claude z gotowym tekstem (?q=). Jeśli Claude nie wpisze go sam, tekst i tak jest w schowku.
export const claudeLink = (base, text) => {
  const b = base || 'https://claude.ai/new';
  return b + (b.includes('?') ? '&' : '?') + 'q=' + encodeURIComponent(text);
};

// ---------- Przegląd pamięci (okno nad apką) ----------
// Pozycje do pokazania: nowe, z pokaz_od ≤ dziś, od najstarszej. Daty jako tekst RRRR-MM-DD.
export const przegladDoPokazania = (rows, today) => (rows || [])
  .filter(r => r && r.status === 'nowe' && r.pokaz_od && r.pokaz_od <= today)
  .sort((a, b) => String(a.created_at || '').localeCompare(String(b.created_at || '')));
// „Później” = { date, t }: okno wraca następnego dnia albo przy ponownym uruchomieniu apki po 2 h.
export const PRZEGLAD_PRZERWA_MS = 2 * 3600e3;
export function przegladPozniej(later, today, now, coldStart) {
  if (!later || !later.date) return false; // nie odłożone
  if (later.date !== today) return false;  // nowy dzień – pokaż
  if (coldStart && now - (+later.t || 0) >= PRZEGLAD_PRZERWA_MS) return false;
  return true;
}
// Czy otworzyć okno teraz: są pozycje, nie odłożone, nikt nie pisze, nie jest otwarte inne okno.
export const przegladOtworzyc = ({ count, odlozone, pisze, inneOkno }) => count > 0 && !odlozone && !pisze && !inneOkno;
// Przyciski zależnie od rodzaju; „Tak” tylko, gdy jest co wykonać.
export function przegladPrzyciski(p) {
  if (p.rodzaj === 'poprawka') return [['ok', 'OK'], ['cofnij', 'Cofnij'], ['napisz', 'Napisz do Claude']];
  const akcja = Array.isArray(p.akcja) ? p.akcja : [];
  return [...(akcja.length ? [['tak', 'Tak, zrób to']] : []), ['zostaw', 'Zostaw'], ['napisz', 'Napisz do Claude']];
}
// Wynik funkcji przeglad_decyzja: 'ok' i 'już zdecydowane' / 'brak pozycji' = pozycja zamknięta, idziemy dalej.
export const przegladDalej = wynik => ['ok', 'już zdecydowane', 'brak pozycji'].includes(wynik);

// ---------- Kuźnia (gra): logika w bazie (kuznia_*), tu tylko to, co apka rysuje między odświeżeniami ----------
// Stoper chodzi co sekundę – godziny pracy na żywo z odcinków w apce (workTotals().day), reszta z kuznia_dzien_na_zywo.
// XP jak w bazie: godzina = 10, praca łącznie maks. 100/dzień; czysty dzień (wszystkie aktywne zrobione) +25.
const kzLiczba = (n, d = 1) => String(Math.round(n * 10 ** d) / 10 ** d).replace('.', ',');
export function kzNaZywo(dzien, workDayMs) {
  if (!dzien) return null;
  let praca = 0;
  const zadania = (dzien.zadania || []).map(z => {
    const kind = String(z.zrodlo || '').startsWith('praca:') ? z.zrodlo.slice(6) : null;
    if (!kind || !workDayMs || workDayMs[kind] == null) { if (kind) praca += z.xp || 0; return z; }
    const postep = Math.round(workDayMs[kind] / 36e3) / 100, xp = Math.min(Math.round(postep * 10), Math.max(0, 100 - praca));
    praca += xp;
    return { ...z, postep, xp, zrobione: postep >= z.cel };
  });
  const akt = zadania.filter(z => z.aktywne), czysty = akt.length > 0 && akt.every(z => z.zrobione);
  return { ...dzien, zadania, czysty, zaliczony: akt.some(z => z.zrobione), xp: zadania.reduce((s, z) => s + (z.xp || 0), 0) + (czysty ? 25 : 0) };
}
// Postęp zadania obok nazwy; zadania „zrobione / nie” bez liczby.
export function kzPostep(z) {
  const src = String(z.zrodlo || '');
  if (src.startsWith('praca:') || src === 'sen') return kzLiczba(z.postep || 0) + ' / ' + kzLiczba(z.cel) + ' h';
  if (src === 'kalorie') return (z.kcal ?? 0) + ' / ' + (z.kcal_cel ?? '?') + ' kcal';
  if (src === 'plan') return (z.postep || 0) + ' / ' + z.cel;
  return '';
}
// Na liście: zadania aktywne dziś + nieaktywne, które i tak dały punkty (premia, np. praca w sobotę).
export const kzWidoczne = zadania => (zadania || []).filter(z => z.aktywne || z.xp > 0).map(z => z.aktywne ? z : { ...z, premia: true });
// Co zyskało punkty od poprzedniego odświeżenia → animacja „+X”. Stoper: tylko pełne godziny (+10 za każdą).
export function kzZyski(prev, next) {
  if (!prev || !next) return [];
  const out = [];
  for (const z of next.zadania || []) {
    const p = (prev.zadania || []).find(x => x.k === z.k); if (!p) continue;
    const xp = String(z.zrodlo || '').startsWith('praca:') ? (Math.floor(z.postep || 0) - Math.floor(p.postep || 0)) * 10 : (z.xp || 0) - (p.xp || 0);
    if (xp > 0) out.push({ k: z.k, xp });
  }
  return out;
}
export const KZ_KAMIENIE = [7, 30, 100];
export const kzKamien = (przed, po) => [...KZ_KAMIENIE].reverse().find(m => przed < m && po >= m) ?? null;
export const kzDni = n => n + ' ' + (n === 1 ? 'dzień' : 'dni');
// Licznik w podsumowaniu dnia: t = część czasu animacji (0–1), wygaszanie wykładnicze – szybki start, miękki koniec.
export const kzLicznik = (cel, t) => t >= 1 ? cel : Math.round(cel * (1 - 2 ** (-10 * Math.max(0, t))));
export const kzPasek = s => s && s.prog > 0 ? Math.max(0, Math.min(1, s.w_poziomie / s.prog)) : 0;
// Po otwarciu apki (kuznia_zamknij_zalegle) – podsumowanie ostatniego dnia, jeśli nie było już pokazane (np. po „Zakończ dzień”).
export function kzDoPokazania(wyniki, widziane) {
  const last = (wyniki || []).at(-1);
  return last && (!widziane || last.date > widziane) ? last : null;
}
// Panel ☰: nowe własne zadanie (odhaczane ręcznie, zapis w kuznia_dni.reczne).
export function kzNoweZadanie(nazwa, lista = []) {
  const n = String(nazwa || '').trim(); if (!n) return null;
  return { k: itemKey(n, lista.map(z => [z.k])), nazwa: n, zrodlo: 'reczne', cel: 1, xp: 10, stat: 'Wiedza' };
}
const KZ_DNI = ['pn', 'wt', 'śr', 'cz', 'pt', 'sb', 'nd'];
export function kzDniTekst(dni) {
  if (!Array.isArray(dni) || dni.length === 7) return 'codziennie';
  if (!dni.length) return 'nigdy';
  const s = [...dni].sort((a, b) => a - b);
  if (s.join() === '1,2,3,4,5') return 'pn–pt';
  return s.map(d => KZ_DNI[d - 1]).join(', ');
}
// Przed zapisem do settings.kuznia_zadania: XP 0–100, cel > 0, wszystkie dni = bez pola „dni”.
export function kzZadaniaZapis(lista) {
  const ok = (n, lo, hi, d) => Number.isFinite(+n) && +n >= lo && +n <= hi ? +n : d;
  return (lista || []).map(z => {
    const t = { ...z, cel: ok(z.cel, 0.01, 1000, 1) };
    if ('xp' in t) t.xp = Math.min(100, Math.max(0, Math.round(+t.xp) || 0));
    if (Array.isArray(t.dni)) { t.dni = [...new Set(t.dni)].filter(d => d >= 1 && d <= 7).sort((a, b) => a - b); if (t.dni.length === 7) delete t.dni; }
    return t;
  });
}
// Statystyki postaci (0–99) w 4 obszarach – kolejność na ekranie.
export const KZ_STATY = [['Ciało', ['Siła', 'Zwinność', 'Zdrowie']], ['Praca', ['Pracowitość']], ['Głowa', ['Wiedza', 'Dyscyplina']], ['Duch i relacje', ['Duch', 'Relacje']]];

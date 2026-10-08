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
    training: w.filter(d => d.training && d.training.trim()).length + Math.round(sum('training_count')),
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
    const extra = days.filter(d => inW(d.date) && d.training && d.training.trim() && !doneDates.has(d.date));
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

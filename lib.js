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

const posilki = n => n === 1 ? 'posiłek' : (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) ? 'posiłki' : 'posiłków';

// Lista „Brakuje: …” – tylko rzeczy, które da się dziś jeszcze zrobić albo dopowiedzieć Claude.
export function missingToday(day, meals, cfg, hour) {
  const out = [];
  if (!day.rehab) out.push('rehab');
  if (!day.morning?.leki) out.push('leki rano');
  if ((hour >= 20 || hour < 4) && !day.evening?.leki_wieczor) out.push('leki wieczorem');
  const kcal = meals.reduce((a, m) => a + (m.kcal || 0), 0), target = day.kcal_target || cfg.kcal_target;
  if (target && kcal < target) out.push((target - kcal) + ' kcal');
  const bez = meals.filter(m => m.kcal == null).length;
  if (bez) out.push(bez + ' ' + posilki(bez) + ' bez kalorii');
  return out;
}

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

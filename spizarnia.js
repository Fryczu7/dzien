// Spiżarnia ze zużyciem – czyste funkcje (bez DOM i sieci), testy: test/spizarnia.test.mjs.
// Zużycie wynika z odstępów między zakupami; Michał niczego nie odhacza.

const dayNr = s => Date.parse(s + 'T00:00:00Z') / 864e5;
export const daysBetween = (a, b) => Math.round(dayNr(b) - dayNr(a));

// Progi stanu (część zwykłego odstępu, która minęła od ostatniego zakupu).
export const KONCZY = 0.8, BRAK = 1.2;
export const STAN = { mam: 'mam', konczy: 'pewnie się kończy', brak: 'pewnie brak', nieznany: 'brak danych' };

// Zwykły odstęp: średnia z ostatnich do 3 odstępów; 0 odstępów = start_days; 1 odstęp = średnia ze start_days i tego odstępu.
export function usualDays(startDays, dates) {
  const d = [...new Set(dates)].sort();
  const gaps = d.slice(1).map((x, i) => daysBetween(d[i], x)).slice(-3);
  if (!gaps.length) return startDays;
  if (gaps.length === 1) return (startDays + gaps[0]) / 2;
  return gaps.reduce((a, b) => a + b, 0) / gaps.length;
}

// Stan jednego produktu na dziś. Zakupy z przyszłości (pomyłka w dacie) są pomijane.
export function productState(product, purchases, today) {
  const dates = purchases.filter(p => p.product_id === product.id && p.date <= today).map(p => p.date);
  if (!dates.length) return { product, state: 'nieznany', last: null, since: null, usual: product.start_days, ratio: null };
  const last = dates.reduce((a, b) => (a > b ? a : b));
  const usual = usualDays(product.start_days, dates), since = daysBetween(last, today), ratio = since / usual;
  const state = ratio >= BRAK ? 'brak' : ratio >= KONCZY ? 'konczy' : 'mam';
  return { product, state, last, since, usual, ratio };
}

// Wszystkie aktywne produkty w kolejności sort, potem nazwa.
export function pantry(products, purchases, today) {
  return products.filter(p => p.active !== false)
    .sort((a, b) => (a.sort ?? 100) - (b.sort ?? 100) || a.name.localeCompare(b.name, 'pl'))
    .map(p => productState(p, purchases, today));
}

// „Do kupienia”: ≥ 80% odstępu, najbardziej zaległe na górze.
export const toBuy = (products, purchases, today) =>
  pantry(products, purchases, today).filter(s => s.ratio != null && s.ratio >= KONCZY)
    .sort((a, b) => b.ratio - a.ratio || a.product.name.localeCompare(b.product.name, 'pl'));

const dni = n => n === 1 ? '1 dzień' : n + ' dni';
export const agoTxt = n => n === 0 ? 'dziś' : n === 1 ? 'wczoraj' : dni(n) + ' temu';
export const everyTxt = u => { const n = Math.max(1, Math.round(u)); return n === 1 ? 'codziennie' : 'co ' + dni(n); };
// Dopisek pod produktem: „ostatnio 6 dni temu · zwykle co 7 dni”.
export const stateLine = s => s.last == null ? 'jeszcze nie kupione · zwykle ' + everyTxt(s.usual)
  : 'ostatnio ' + agoTxt(s.since) + ' · zwykle ' + everyTxt(s.usual);

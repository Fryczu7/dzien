import { test } from 'node:test';
import assert from 'node:assert/strict';
import { streakDays, counters, applyDecision, undoDecision, splitPropozycje, checkinPatch, checkinMsg } from '../lib.js';

// 2026-10-08 to czwartek; tydzień od poniedziałku 2026-10-05.
const T = '2026-10-08';

test('streakDays: dziś jeszcze trwa – seria liczy się od wczoraj, gdy dziś niezrobione', () => {
  assert.equal(streakDays(new Set(['2026-10-06', '2026-10-07']), T), 2);
  assert.equal(streakDays(new Set(['2026-10-06', '2026-10-07', T]), T), 3);
  assert.equal(streakDays(new Set(['2026-10-05', '2026-10-07']), T), 1);
  assert.equal(streakDays(new Set(['2026-10-05']), T), 0);
  assert.equal(streakDays(new Set(), T), 0);
});

test('counters: rehab w tygodniu i seria, kalorie ≥ celu, treningi', () => {
  const days = [
    { date: '2026-10-03', rehab: true },
    { date: '2026-10-04', rehab: true },
    { date: '2026-10-05', rehab: true, kcal_target: 3000 },
    { date: '2026-10-06', rehab: false, training: 'nogi' },
    { date: '2026-10-07', rehab: true },
    { date: T, rehab: true },
  ];
  const meals = [
    { date: '2026-10-05', kcal: 3100 },             // ≥ 3000 (cel dnia)
    { date: '2026-10-06', kcal: 2000 }, { date: '2026-10-06', kcal: 1400 }, // 3400 ≥ 3300
    { date: '2026-10-07', kcal: 3300 },             // równo celu też się liczy
    { date: T, kcal: 1200 }, { date: T, kcal: null },
  ];
  const workouts = [{ date: '2026-10-07', status: 'zrobiony' }, { date: '2026-10-07', status: 'zrobiony' }, { date: T, status: 'odwolany' }];
  const c = counters({ days, meals, catchups: [], workouts, today: T, kcalTarget: 3300 });
  assert.equal(c.rehabWeek, 3);       // pn, śr, cz
  assert.equal(c.rehabStreak, 2);     // śr + cz (wt przerwało)
  assert.equal(c.kcalWeek, 3);        // pn, wt, śr
  assert.equal(c.kcalStreak, 3);      // dziś 1200 jeszcze trwa → od wczoraj: śr, wt, pn
  assert.equal(c.daysSoFar, 4);
  assert.equal(c.trainingWeek, 3);    // 2 treningi w śr + tekst we wt; odwołane się nie liczą
});

test('counters: pełne nadrobienie przedłuża serie, częściowe je przerywa', () => {
  const days = [{ date: '2026-10-07', rehab: true }];
  const catchups = [{ from_date: '2026-10-04', to_date: '2026-10-06', rehab_count: 3, kcal_ok: 'tak' }];
  const c = counters({ days, meals: [{ date: '2026-10-07', kcal: 3500 }], catchups, workouts: [], today: T, kcalTarget: 3300 });
  assert.equal(c.rehabStreak, 4);
  assert.equal(c.kcalStreak, 4);
  const c2 = counters({ days, meals: [], catchups: [{ ...catchups[0], rehab_count: 2, kcal_ok: 'czesciowo' }], workouts: [], today: T, kcalTarget: 3300 });
  assert.equal(c2.rehabStreak, 1);
  assert.equal(c2.kcalStreak, 0);
});

const P = (extra = {}) => ({ id: 'p1', kind: 'dzien', date: T, title: 'Montaż GetMed – krok 4', status: 'nowa', ...extra });

test('applyDecision: Biorę dopisuje tytuł do planu z src asystent', () => {
  const r = applyDecision([{ text: 'Rehab', done: false }], P(), 'wez');
  assert.deepEqual(r.patch, { status: 'wzieta', reply: null });
  assert.deepEqual(r.plan.at(-1), { text: 'Montaż GetMed – krok 4', done: false, src: 'asystent', pid: 'p1' });
  assert.equal(r.plan.length, 2);
});

test('applyDecision: Zmień – do planu idzie wersja Michała; pusta wersja = błąd', () => {
  const r = applyDecision([], P(), 'zmien', '  Montaż tylko intro  ');
  assert.deepEqual(r.patch, { status: 'zmieniona', reply: 'Montaż tylko intro' });
  assert.equal(r.plan[0].text, 'Montaż tylko intro');
  assert.equal(applyDecision([], P(), 'zmien', '  ').error, 'pusto');
});

test('applyDecision: Nie – powód opcjonalny, plan bez zmian', () => {
  const plan = [{ text: 'X', done: false }];
  assert.deepEqual(applyDecision(plan, P(), 'nie', 'za dużo na dziś'), { plan, patch: { status: 'odrzucona', reply: 'za dużo na dziś' } });
  assert.deepEqual(applyDecision(plan, P(), 'nie', ' ').patch, { status: 'odrzucona', reply: null });
});

test('applyDecision: max 3 rzeczy w planie (rehab i leki się nie liczą), ponowna decyzja podmienia wpis', () => {
  const full = [{ text: 'A', done: true }, { text: 'B', done: false }, { text: 'C', done: false }, { text: 'Rehab', done: false }];
  assert.equal(applyDecision(full, P(), 'wez').error, 'max3');
  const once = applyDecision([{ text: 'A', done: false }], P(), 'wez').plan;
  const again = applyDecision(once, P(), 'zmien', 'Inaczej');
  assert.equal(again.plan.length, 2);
  assert.equal(again.plan[1].text, 'Inaczej');
});

test('applyDecision: pomysł nie trafia do planu dnia', () => {
  const r = applyDecision([], P({ kind: 'pomysl' }), 'wez');
  assert.deepEqual(r, { plan: [], patch: { status: 'wzieta', reply: null } });
});

test('undoDecision: usuwa z planu tylko wpis tej propozycji', () => {
  const plan = [{ text: 'A', done: false }, { text: 'M', done: false, src: 'asystent', pid: 'p1' }];
  assert.deepEqual(undoDecision(plan, P()), [{ text: 'A', done: false }]);
});

test('splitPropozycje: dzisiejsze do decyzji, zdecydowane osobno, pomysły z każdej daty', () => {
  const rows = [
    P({ id: 'a', created_at: '2026-10-08T02:00:00Z' }),
    P({ id: 'b', status: 'wzieta', created_at: '2026-10-08T02:01:00Z' }),
    P({ id: 'c', date: '2026-10-07' }),
    P({ id: 'd', kind: 'pomysl', date: '2026-10-01' }),
    P({ id: 'e', kind: 'pomysl', date: null, status: 'odrzucona' }),
  ];
  const s = splitPropozycje(rows, T);
  assert.deepEqual(s.open.map(x => x.id), ['a']);
  assert.deepEqual(s.decided.map(x => x.id), ['b']);
  assert.deepEqual(s.ideas.map(x => x.id), ['d']);
  assert.deepEqual(s.ideasDecided.map(x => x.id), ['e']);
});

test('checkinPatch: łączy z istniejącym wieczorem, zapisuje czas', () => {
  const ev = { leki_wieczor: true, doceniam: 'stare' };
  const p = checkinPatch(ev, { nastroj: 4, blokada: ' telefon ', doceniam: 'trening' }, new Date('2026-10-08T19:30:00Z'));
  assert.deepEqual(p, { leki_wieczor: true, doceniam: 'trening', nastroj: 4, blokada: 'telefon', checkin_at: '2026-10-08T19:30:00.000Z' });
});

test('checkinMsg: wiadomość do coacha z check-inu, z poleceniem zapisu odpowiedzi', () => {
  const m = checkinMsg('2026-10-08', { nastroj: 2, blokada: 'telefon', doceniam: '' });
  assert.match(m, /Nastrój: 2\/5 \(słabo\)/);
  assert.match(m, /Co blokowało: telefon/);
  assert.doesNotMatch(m, /Doceniam/);
  assert.match(m, /coach_evening_save\('2026-10-08'/);
});

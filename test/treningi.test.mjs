import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseRange, sortWorkouts, bestSet, nextTarget, exerciseProgress, progressFor, setCounts, fmtSet } from '../lib.js';

const S = (exercise, kg, reps, extra = {}) => ({ exercise, kg, reps, warmup: false, ...extra });

test('parseRange: zakres, jedna liczba, max', () => {
  assert.deepEqual(parseRange('6-10'), { min: 6, max: 10 });
  assert.deepEqual(parseRange('10'), { min: 10, max: 10 });
  assert.equal(parseRange('max'), null);
  assert.equal(parseRange(undefined), null);
});

test('sortWorkouts: najnowsze na górze, bez daty na końcu', () => {
  const r = sortWorkouts([{ date: null, name: 'a' }, { date: '2026-10-03', name: 'b' }, { date: '2026-10-07', name: 'c' }]);
  assert.deepEqual(r.map(w => w.name), ['c', 'b', 'a']);
});

test('bestSet: bez rozgrzewek, próba poniżej zakresu nie jest wynikiem', () => {
  const sets = [S('Ławka', 20, 11, { warmup: true }), S('Ławka', 40, 10, { warmup: true }), S('Ławka', 50, 8, { rir: '1-2' }), S('Ławka', 55, 5, { rir: '0' }), S('Ławka', 50, 6)];
  assert.equal(fmtSet(bestSet(sets, { min: 6, max: 10 })), '50 kg × 8');
  assert.equal(fmtSet(bestSet(sets, null)), '55 kg × 5');
  // Żadna seria w zakresie → najlepsza robocza.
  assert.equal(fmtSet(bestSet([S('Prostowanie', 30, 9)], { min: 12, max: 15 })), '30 kg × 9');
  assert.equal(fmtSet(bestSet([S('Dipy', null, 5), S('Dipy', null, 3)], null)), 'masa ciała × 5');
  assert.equal(bestSet([S('X', 20, 10, { warmup: true })], null), null);
});

test('nextTarget: najpierw powtórzenia do góry zakresu, potem ciężar', () => {
  assert.equal(nextTarget({ kg: 70, reps: 11 }, { min: 10, max: 12 }), '70 kg × 12');
  assert.equal(nextTarget({ kg: 70, reps: 12 }, { min: 10, max: 12 }), 'więcej kg × 10');
  assert.equal(nextTarget({ kg: 12.5, reps: 8 }, { min: 8, max: 12 }), '12,5 kg × 9');
  assert.equal(nextTarget({ kg: null, reps: 5 }, null), null);
});

test('exerciseProgress: ostatni i poprzedni wynik, kierunek', () => {
  const plans = [{ exercises: [{ name: 'Wyciskanie sztangi płasko', reps: '6-10' }] }];
  const ws = [
    { date: null, name: 'Klatka', workout_sets: [S('Wyciskanie sztangi płasko', 50, 8), S('Wyciskanie sztangi płasko', 55, 5)] },
    { date: '2026-10-10', name: 'Klatka', workout_sets: [S('wyciskanie sztangi płasko ', 50, 9)] },
    { date: '2026-10-07', name: 'Klatka', workout_sets: [] },
  ];
  const p = progressFor(exerciseProgress(ws, plans), 'Wyciskanie sztangi płasko');
  assert.equal(fmtSet(p.last), '50 kg × 9'); assert.equal(p.last.date, '2026-10-10');
  assert.equal(fmtSet(p.prev), '50 kg × 8'); assert.equal(p.prev.date, null);
  assert.equal(p.trend, 'up'); assert.equal(p.next, '50 kg × 10');
  const one = progressFor(exerciseProgress([ws[0]], plans), 'Wyciskanie sztangi płasko');
  assert.equal(one.prev, null); assert.equal(one.trend, null);
  assert.equal(progressFor(exerciseProgress(ws, plans), 'Dipy'), null);
});

test('exerciseProgress: spadek i bez zmian', () => {
  const ws = [{ date: '2026-10-01', name: 'N', workout_sets: [S('Hip thrust', 70, 11)] }, { date: '2026-10-05', name: 'N', workout_sets: [S('Hip thrust', 70, 10)] }];
  assert.equal(progressFor(exerciseProgress(ws), 'Hip thrust').trend, 'down');
  ws[1].workout_sets[0].reps = 11;
  assert.equal(progressFor(exerciseProgress(ws), 'Hip thrust').trend, 'same');
});

test('setCounts: robocze i rozgrzewkowe', () => {
  assert.deepEqual(setCounts({ workout_sets: [S('a', 1, 1, { warmup: true }), S('a', 1, 1)] }), { work: 1, warmup: 1 });
  assert.deepEqual(setCounts({}), { work: 0, warmup: 0 });
});

test('trendLabel: ciężar ważniejszy niż powtórzenia', async () => {
  const { trendLabel } = await import('../lib.js');
  assert.equal(trendLabel({ kg: 52.5, reps: 6 }, { kg: 50, reps: 8 }), '+2,5 kg');
  assert.equal(trendLabel({ kg: 50, reps: 9 }, { kg: 50, reps: 8 }), '+1 powt.');
  assert.equal(trendLabel({ kg: null, reps: 3 }, { kg: null, reps: 5 }), '−2 powt.');
  assert.equal(trendLabel({ kg: 50, reps: 8 }, { kg: 50, reps: 8 }), 'bez zmian');
  assert.equal(trendLabel({ kg: 50, reps: 8 }, null), null);
});

test('trainingWeeks: zrobione, odwołane, opuszczone; stary wpis tekstowy bez dublowania', async () => {
  const { trainingWeeks } = await import('../lib.js');
  // 8.10.2026 to czwartek → tydzień 5.10–11.10.
  const ws = [
    { date: '2026-10-07', kind: 'silownia', status: 'zrobiony' }, { date: '2026-10-06', kind: 'wspinaczka', status: 'odwolany' },
    { date: '2026-10-05', kind: 'kalistenika', status: 'odwolany' }, { date: '2026-10-03', kind: 'silownia' },
    { date: '2026-10-08', kind: 'wspinaczka', status: 'zrobiony' }, { date: '2026-10-09', kind: 'bieg' }, { date: null, kind: 'silownia' },
  ];
  const days = [{ date: '2026-10-07', training: 'klatka' }, { date: '2026-10-06', training: 'bieg 5 km' }, { date: '2026-10-01', training: '' }];
  const [w0, w1] = trainingWeeks(ws, days, '2026-10-08', 2);
  assert.equal(w0.from, '2026-10-05'); assert.equal(w0.to, '2026-10-11');
  // 7.10 siłownia (tekst w days nie dubluje), 8.10 wspinaczka; 9.10 to jutro – nie liczy się; 6.10 ma wpis w workouts (odwołany), więc tekst też nie.
  assert.equal(w0.done, 2); assert.equal(w0.cancelled, 2); assert.equal(w0.missed, 0);
  assert.deepEqual(w0.byKind, { silownia: 1, wspinaczka: 1 });
  assert.equal(w1.from, '2026-09-28'); assert.equal(w1.done, 1);
});

test('withWorkoutDays: dzień z treningiem w workouts liczy się w tygodniu na „Dziś”', async () => {
  const { withWorkoutDays, weekStats } = await import('../lib.js');
  const days = withWorkoutDays([{ date: '2026-10-07', training: '' }, { date: '2026-10-06', training: 'bieg' }],
    [{ date: '2026-10-07', status: 'zrobiony' }, { date: '2026-10-08' }, { date: '2026-10-05', status: 'odwolany' }]);
  assert.equal(weekStats(days, [], '2026-10-08').training, 3);
});

test('progressSummary: liczy kierunki, pierwsze zapisy osobno', async () => {
  const { progressSummary } = await import('../lib.js');
  const m = new Map([['a', { trend: 'up' }], ['b', { trend: null }], ['c', { trend: 'up' }], ['d', { trend: 'down' }]]);
  assert.deepEqual(progressSummary(m), { up: 2, same: 0, down: 1, first: 1 });
});

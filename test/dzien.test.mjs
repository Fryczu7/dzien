import { test } from 'node:test';
import assert from 'node:assert/strict';
import { findGap, weekStats, partOfDay, missingToday, weekStart } from '../lib.js';

test('findGap: luka kończąca się wczoraj, po ostatnim aktywnym dniu', () => {
  const active = new Set(['2026-10-01', '2026-10-02']);
  assert.deepEqual(findGap(active, [], '2026-10-06'), { from: '2026-10-03', to: '2026-10-05', days: 3 });
});

test('findGap: wczoraj aktywny = brak luki', () => {
  assert.equal(findGap(new Set(['2026-10-05']), [], '2026-10-06'), null);
});

test('findGap: luka pokryta nadrobieniem znika', () => {
  const active = new Set(['2026-10-02']);
  const catchups = [{ from_date: '2026-10-03', to_date: '2026-10-05' }];
  assert.equal(findGap(active, catchups, '2026-10-06'), null);
});

test('findGap: nowe konto bez żadnej historii – nie pytamy o nadrabianie', () => {
  assert.equal(findGap(new Set(), [], '2026-10-06'), null);
});

test('weekStart: poniedziałek tygodnia', () => {
  assert.equal(weekStart('2026-10-08'), '2026-10-05');
  assert.equal(weekStart('2026-10-05'), '2026-10-05');
  assert.equal(weekStart('2026-10-11'), '2026-10-05');
});

test('weekStats: dni z tego tygodnia + nadrobienie', () => {
  const days = [
    { date: '2026-10-04', rehab: true, training: 'x', morning: { leki: true }, sleep_h: 9 }, // poprzedni tydzień – pomijamy
    { date: '2026-10-05', rehab: true, training: 'siłownia', morning: { leki: true }, sleep_h: 7 },
    { date: '2026-10-06', rehab: false, training: '', morning: {}, sleep_h: 8 },
  ];
  const catchups = [{ from_date: '2026-10-07', to_date: '2026-10-08', rehab_count: 1, training_count: 1, meds_days: 2, sleep_h: 6 }];
  const s = weekStats(days, catchups, '2026-10-09');
  assert.deepEqual(s, { rehab: 2, training: 2, meds: 3, daysSoFar: 5, sleepAvg: 6.8 });
});

test('weekStats: nadrobienie zachodzące na poprzedni tydzień liczy się proporcjonalnie', () => {
  // luka czw 1.10 – pon 5.10 (5 dni), w tym tygodniu tylko poniedziałek = 1/5
  const catchups = [{ from_date: '2026-10-01', to_date: '2026-10-05', rehab_count: 5, training_count: 0, meds_days: 5, sleep_h: 7 }];
  const s = weekStats([], catchups, '2026-10-06');
  assert.deepEqual(s, { rehab: 1, training: 0, meds: 1, daysSoFar: 2, sleepAvg: 7 });
});

test('partOfDay: rano do 14 przed odhaczeniem, wieczór od 20', () => {
  assert.equal(partOfDay(10, false), 'rano');
  assert.equal(partOfDay(10, true), 'dzien');
  assert.equal(partOfDay(15, false), 'dzien');
  assert.equal(partOfDay(20, true), 'wieczor');
  assert.equal(partOfDay(1, true), 'wieczor');
});

test('missingToday: czego brakuje', () => {
  const day = { rehab: false, morning: { leki: true }, evening: {} };
  const meals = [{ kcal: 600, protein: 40 }, { kcal: null, protein: null }];
  const m = missingToday(day, meals, { kcal_target: 3300, protein_target: 150 }, 21);
  assert.deepEqual(m, ['rehab', 'leki wieczorem', '2700 kcal', '1 posiłek bez kalorii']);
  const full = missingToday({ rehab: true, morning: { leki: true }, evening: { leki_wieczor: true } }, [{ kcal: 3400, protein: 160 }], { kcal_target: 3300, protein_target: 150 }, 21);
  assert.deepEqual(full, []);
  // Przed 18:00 brak kalorii to plan, nie zaległość – nie ma ich w „Brakuje”.
  assert.deepEqual(missingToday(day, meals, { kcal_target: 3300 }, 11), ['rehab', '1 posiłek bez kalorii']);
  assert.ok(missingToday(day, meals, { kcal_target: 3300 }, 18).includes('2700 kcal'));
});

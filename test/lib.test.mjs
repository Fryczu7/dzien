import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ymd, hoursBetween, isFuture, mealTime, ruleState, dayOnResume } from '../lib.js';

test('ymd: data lokalna, także tuż przed północą', () => {
  assert.equal(ymd(new Date(2026, 9, 5, 23, 59)), '2026-10-05');
  assert.equal(ymd(new Date(2026, 9, 6, 0, 1)), '2026-10-06');
});

test('hoursBetween: przez północ, brak danych', () => {
  assert.equal(hoursBetween('23:30', '07:00'), 7.5);
  assert.equal(hoursBetween('01:00', '09:15'), 8.3);
  assert.equal(hoursBetween(null, '07:00'), null);
  assert.equal(hoursBetween('', ''), null);
});

test('isFuture', () => {
  assert.equal(isFuture('2026-10-06', '2026-10-05'), true);
  assert.equal(isFuture('2026-10-05', '2026-10-05'), false);
  assert.equal(isFuture('2026-10-04', '2026-10-05'), false);
});

test('mealTime: godzina tylko dla dzisiejszego dnia', () => {
  const now = new Date(2026, 9, 5, 8, 7);
  assert.equal(mealTime('2026-10-05', now), '08:07');
  assert.equal(mealTime('2026-10-04', now), null);
});

test('ruleState: złamana > zatwierdzona OK > nieustawiona', () => {
  assert.equal(ruleState(3, [3], false), 'broken');
  assert.equal(ruleState(3, [3], true), 'broken');
  assert.equal(ruleState(4, [3], true), 'ok');
  assert.equal(ruleState(4, [3], false), 'unset');
});

test('dayOnResume: po północy przeskakuje na nowy dzień tylko gdy patrzyliśmy na „dziś”', () => {
  const now = new Date(2026, 9, 6, 0, 30);
  assert.equal(dayOnResume('2026-10-05', true, now), '2026-10-06');
  assert.equal(dayOnResume('2026-10-02', false, now), '2026-10-02');
});

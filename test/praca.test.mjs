import { test } from 'node:test';
import assert from 'node:assert/strict';
import { workTotals, fmtClock, fmtHM, isWorkday, workLine, workBrief } from '../lib.js';

const H = 3600e3, M = 60e3;
// 2026-10-13 to wtorek; tydzień od poniedziałku 12.10.
const rows = [
  { date: '2026-10-11', kind: 'getmed', started_at: '2026-10-11T08:00:00Z', ended_at: '2026-10-11T10:00:00Z' }, // niedziela poprzedniego tygodnia
  { date: '2026-10-12', kind: 'getmed', started_at: '2026-10-12T08:00:00Z', ended_at: '2026-10-12T11:00:00Z' },
  { date: '2026-10-13', kind: 'getmed', started_at: '2026-10-13T08:00:00Z', ended_at: '2026-10-13T09:10:00Z' },
  { date: '2026-10-13', kind: 'zlap', started_at: '2026-10-13T09:10:00Z', ended_at: '2026-10-13T09:40:00Z' },
  { date: '2026-10-13', kind: 'getmed', started_at: '2026-10-13T10:00:00Z', ended_at: null },
];
const now = Date.parse('2026-10-13T11:00:00Z');

test('workTotals: dziś i tydzień, chodzący odcinek liczy się do teraz', () => {
  const t = workTotals(rows, '2026-10-13', now);
  assert.equal(t.day.getmed, 2 * H + 10 * M);
  assert.equal(t.day.zlap, 30 * M);
  assert.equal(t.day.projekty, 0);
  assert.equal(t.week.getmed, 5 * H + 10 * M);
  assert.equal(t.running.kind, 'getmed');
  assert.equal(t.runningMs, H);
});

test('formaty czasu', () => {
  assert.equal(fmtClock(H + 2 * M + 5e3), '1:02:05');
  assert.equal(fmtClock(65e3), '0:01:05');
  assert.equal(fmtHM(2 * H + 10 * M + 59e3), '2:10');
  assert.equal(fmtHM(0), '0:00');
});

test('isWorkday: pon–pt', () => {
  assert.equal(isWorkday('2026-10-13'), true);
  assert.equal(isWorkday('2026-10-17'), false);
  assert.equal(isWorkday('2026-10-18'), false);
});

test('workLine: cel dzienny tylko w dni robocze, tygodniowy zawsze; projekty bez celu', () => {
  const t = workTotals(rows, '2026-10-13', now), tg = { getmed: { dzien: 240, tydzien: 1200 }, zlap: { dzien: 60, tydzien: 300 } };
  assert.equal(workLine('getmed', t, tg, '2026-10-13'), 'dziś 2:10 / 4:00 · tydzień 5:10 / 20:00');
  assert.equal(workLine('projekty', t, tg, '2026-10-13'), 'dziś 0:00 · tydzień 0:00');
  assert.equal(workLine('getmed', workTotals([], '2026-10-17', now), tg, '2026-10-17'), 'dziś 0:00 · tydzień 0:00 / 20:00');
});

test('workBrief: linijka do wieczornej ściągi', () => {
  const t = workTotals(rows, '2026-10-13', now);
  assert.equal(workBrief(t.day), 'Praca: GetMed 2:10, Złap Termin 0:30');
  assert.equal(workBrief({ getmed: 0, zlap: 0, projekty: 0 }), 'Praca: nic nie zmierzone');
});

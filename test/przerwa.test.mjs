import { test } from 'node:test';
import assert from 'node:assert/strict';
import { workAutoStop, workChainStart, breakState, WORK_LIMIT_MS } from '../lib.js';

const M = 60e3, T = s => Date.parse('2026-10-14T' + s + 'Z');
const run = (start, kind = 'getmed') => ({ kind, started_at: '2026-10-14T' + start + 'Z', ended_at: null });
const done = (start, end, kind = 'getmed') => ({ kind, started_at: '2026-10-14T' + start + 'Z', ended_at: '2026-10-14T' + end + 'Z' });

test('przed upływem godziny nic się nie zamyka', () => {
  assert.equal(workAutoStop([run('08:00:00')], T('08:59:59')), null);
});

test('dokładnie po 60 min: koniec = start + 60 min', () => {
  assert.equal(workAutoStop([run('08:00:00')], T('09:00:00')), '2026-10-14T09:00:00.000Z');
});

test('powrót z tła po 3 h: koniec dalej na 60. minucie, nie „teraz”', () => {
  assert.equal(workAutoStop([run('08:00:00')], T('11:07:12')), '2026-10-14T09:00:00.000Z');
});

test('zmiana „do czego” w trakcie nie zeruje godziny', () => {
  const rows = [done('08:00:00', '08:40:00'), run('08:40:00', 'zlap')];
  assert.equal(workChainStart(rows, rows[1]), T('08:00:00'));
  assert.equal(workAutoStop(rows, T('08:59:00')), null);
  assert.equal(workAutoStop(rows, T('10:00:00')), '2026-10-14T09:00:00.000Z');
});

test('przerwa (luka > 1 min) zaczyna nową godzinę', () => {
  const rows = [done('08:00:00', '09:00:00'), run('09:10:00')];
  assert.equal(workChainStart(rows, rows[1]), T('09:10:00'));
  assert.equal(workAutoStop(rows, T('10:09:59')), null);
  assert.equal(workAutoStop(rows, T('10:30:00')), '2026-10-14T10:10:00.000Z');
});

test('łańcuch trzech odcinków bez luki', () => {
  const rows = [done('07:00:00', '07:20:00'), done('07:20:30', '07:50:00', 'zlap'), run('07:50:00', 'projekty')];
  assert.equal(workChainStart(rows, rows[2]), T('07:00:00'));
  assert.equal(workAutoStop(rows, T('08:05:00')), '2026-10-14T08:00:00.000Z');
});

test('koniec nigdy przed startem chodzącego odcinka', () => {
  // Stary łańcuch dawno przekroczył godzinę (np. apka była zamknięta) – odcinek kończy się najwcześniej na swoim starcie.
  const rows = [done('06:00:00', '07:30:00'), run('07:30:00')];
  assert.equal(workAutoStop(rows, T('07:31:00')), '2026-10-14T07:30:00.000Z');
});

test('bez chodzącego odcinka: null', () => {
  assert.equal(workAutoStop([done('08:00:00', '09:00:00')], T('12:00:00')), null);
});

test('limit skrócony (podgląd) działa tak samo', () => {
  assert.equal(workAutoStop([run('08:00:00')], T('08:00:20'), 20e3), '2026-10-14T08:00:20.000Z');
  assert.equal(WORK_LIMIT_MS, 60 * M);
});

test('breakState: fazy przerwy 5–15 min', () => {
  const s = T('09:00:00');
  assert.deepEqual(breakState(s, s + 2 * M), { ms: 2 * M, phase: 'krotka' });
  assert.equal(breakState(s, s + 5 * M).phase, 'ok');
  assert.equal(breakState(s, s + 14 * M + 59e3).phase, 'ok');
  assert.equal(breakState(s, s + 15 * M).phase, 'koniec');
  assert.equal(breakState(s, s - 1000).ms, 0);
});

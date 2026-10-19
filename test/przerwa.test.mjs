import { test } from 'node:test';
import assert from 'node:assert/strict';
import { workAlarm, workAlarmMsg, ALARM_EVERY_MS, workChainStart, breakState, WORK_LIMIT_MS, workBreakCfg, WORK_BREAK_DEFAULT, SOUNDS_STOP, SOUNDS_END, soundTones, workTotals, workUntilBreak } from '../lib.js';

const M = 60e3, T = s => Date.parse('2026-10-14T' + s + 'Z');
const run = (start, kind = 'getmed') => ({ kind, started_at: '2026-10-14T' + start + 'Z', ended_at: null });
const done = (start, end, kind = 'getmed') => ({ kind, started_at: '2026-10-14T' + start + 'Z', ended_at: '2026-10-14T' + end + 'Z' });
// Kiedy alarm „czas na przerwę” (ISO), gdy już minął; inaczej null. Stoper nie staje sam – to tylko chwila alarmu.
const alarmAt = (rows, now, lim, br) => { const a = workAlarm(rows, now, lim, br); return a?.due ? new Date(a.at).toISOString() : null; };

test('przed upływem godziny nie ma alarmu', () => {
  assert.equal(alarmAt([run('08:00:00')], T('08:59:59')), null);
});

test('dokładnie po 60 min: alarm = start + 60 min', () => {
  assert.equal(alarmAt([run('08:00:00')], T('09:00:00')), '2026-10-14T09:00:00.000Z');
});

test('powrót z tła po 3 h: alarm liczony od 60. minuty, nie od „teraz”', () => {
  assert.equal(alarmAt([run('08:00:00')], T('11:07:12')), '2026-10-14T09:00:00.000Z');
});

test('zmiana „do czego” w trakcie nie zeruje godziny', () => {
  const rows = [done('08:00:00', '08:40:00'), run('08:40:00', 'zlap')];
  assert.equal(workChainStart(rows, rows[1]), T('08:00:00'));
  assert.equal(alarmAt(rows, T('08:59:00')), null);
  assert.equal(alarmAt(rows, T('10:00:00')), '2026-10-14T09:00:00.000Z');
});

test('przerwa (luka > 1 min) zaczyna nową godzinę', () => {
  const rows = [done('08:00:00', '09:00:00'), run('09:10:00')];
  assert.equal(workChainStart(rows, rows[1]), T('09:10:00'));
  assert.equal(alarmAt(rows, T('10:09:59')), null);
  assert.equal(alarmAt(rows, T('10:30:00')), '2026-10-14T10:10:00.000Z');
});

test('łańcuch trzech odcinków bez luki', () => {
  const rows = [done('07:00:00', '07:20:00'), done('07:20:30', '07:50:00', 'zlap'), run('07:50:00', 'projekty')];
  assert.equal(workChainStart(rows, rows[2]), T('07:00:00'));
  assert.equal(alarmAt(rows, T('08:05:00')), '2026-10-14T08:00:00.000Z');
});

test('alarm nigdy przed startem chodzącego odcinka', () => {
  // Stary łańcuch dawno przekroczył godzinę (np. apka była zamknięta) – odcinek kończy się najwcześniej na swoim starcie.
  const rows = [done('06:00:00', '07:30:00'), run('07:30:00')];
  assert.equal(alarmAt(rows, T('07:31:00')), '2026-10-14T07:30:00.000Z');
});

test('bez chodzącego odcinka: null', () => {
  assert.equal(alarmAt([done('08:00:00', '09:00:00')], T('12:00:00')), null);
});

test('limit skrócony (podgląd) działa tak samo', () => {
  assert.equal(alarmAt([run('08:00:00')], T('08:00:20'), 20e3), '2026-10-14T08:00:20.000Z');
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

const brk = (start, end = null) => ({ started_at: '2026-10-14T' + start + 'Z', ended_at: end && '2026-10-14T' + end + 'Z' });

test('kliknięta przerwa (nawet 30 s) zaczyna nową godzinę', () => {
  const rows = [done('08:00:00', '08:50:00'), run('08:50:30')];
  const breaks = [brk('08:50:00', '08:50:30')];
  assert.equal(workChainStart(rows, rows[1]), T('08:00:00'));            // bez przerwy w tabeli: łączy
  assert.equal(workChainStart(rows, rows[1], 60e3, breaks), T('08:50:30')); // z przerwą: od nowa
  assert.equal(alarmAt(rows, T('09:10:00'), WORK_LIMIT_MS, breaks), null);
  assert.equal(alarmAt(rows, T('09:51:00'), WORK_LIMIT_MS, breaks), '2026-10-14T09:50:30.000Z');
});

test('przerwa sprzed łańcucha go nie urywa', () => {
  const rows = [done('08:00:00', '08:30:00'), run('08:30:00', 'zlap')];
  assert.equal(workChainStart(rows, rows[1], 60e3, [brk('07:40:00', '07:55:00')]), T('08:00:00'));
});

test('po zmianie na Złap Termin czas liczy się do Złap Termin, GetMed zostaje', () => {
  const rows = [done('08:00:00', '08:35:00'), run('08:35:00', 'zlap')].map(r => ({ ...r, date: '2026-10-14' }));
  const t = workTotals(rows, '2026-10-14', T('08:45:00'));
  assert.equal(t.day.getmed, 35 * M);
  assert.equal(t.day.zlap, 10 * M);
  assert.equal(t.running.kind, 'zlap');
});

test('workBreakCfg: domyślne i naprawa złych wartości', () => {
  assert.deepEqual(workBreakCfg(null), WORK_BREAK_DEFAULT);
  assert.equal(workBreakCfg({ limit_min: 50 }).limit_min, 50);
  assert.equal(workBreakCfg({ limit_min: 0 }).limit_min, 60);
  assert.equal(workBreakCfg({ break_min: 10, break_max: 5 }).break_max, 15);
  assert.equal(workBreakCfg({ sound_stop: 'nie-ma' }).sound_stop, 'trzy-tony');
});

test('dźwięki: unikalne id, domyślne istnieją, nieznane id → pierwszy', () => {
  for (const L of [SOUNDS_STOP, SOUNDS_END]) assert.equal(new Set(L.map(s => s[0])).size, L.length);
  assert.ok(SOUNDS_STOP.some(s => s[0] === WORK_BREAK_DEFAULT.sound_stop));
  assert.ok(SOUNDS_END.some(s => s[0] === WORK_BREAK_DEFAULT.sound_end));
  assert.equal(soundTones(SOUNDS_END, 'xyz'), SOUNDS_END[0][2]);
  for (const [, , tones] of [...SOUNDS_STOP, ...SOUNDS_END]) for (const t of tones) assert.ok(t[0] > 0 && t[2] > 0 && t[3] > 0 && t[3] <= 1);
});

test('workUntilBreak: ile do przerwy, liczone od startu łańcucha', () => {
  const rows = [done('08:00:00', '08:20:00'), run('08:20:00', 'zlap')];
  assert.equal(workUntilBreak(rows, T('08:30:00')), 30 * M);
  assert.equal(workUntilBreak(rows, T('08:30:00'), WORK_LIMIT_MS, [brk('08:20:00', '08:20:00')]), 50 * M);
  assert.equal(workUntilBreak([done('08:00:00', '08:10:00')], T('08:30:00')), null);
});

test('workBreakCfg: własny dźwięk zostaje', () => {
  assert.equal(workBreakCfg({ sound_stop: 'wlasny', sound_end: 'wlasny' }).sound_stop, 'wlasny');
  assert.equal(workBreakCfg({ sound_end: 'wlasny' }).sound_end, 'wlasny');
});

test('workAlarm: stoper nie staje – odcinek dalej chodzi, alarm co 15 min przez 2 h', () => {
  const rows = [run('08:00:00')];
  const a0 = workAlarm(rows, T('09:00:30'));
  assert.equal(a0.due, true); assert.equal(a0.slot, 0); assert.equal(a0.slotAt, T('09:00:00')); assert.equal(a0.quiet, false);
  assert.equal(rows[0].ended_at, null);
  const a1 = workAlarm(rows, T('09:16:00'));
  assert.equal(a1.slot, 1); assert.equal(a1.slotAt, T('09:15:00'));
  assert.equal(workAlarm(rows, T('10:59:59')).quiet, false); // slot 7 (10:45) jeszcze gra
  assert.equal(workAlarm(rows, T('11:00:00')).quiet, true);  // po 2 h cisza
  assert.equal(ALARM_EVERY_MS, 15 * M);
});

test('workAlarm: przed czasem – ile zostało, bez slotu', () => {
  const a = workAlarm([run('08:00:00')], T('08:45:00'));
  assert.deepEqual([a.due, a.left, a.slot, a.start], [false, 15 * M, null, T('08:00:00')]);
});

test('„Pracuję dalej” odkłada alarm o pełną porcję (snooze_until)', () => {
  const r = { ...run('08:00:00'), snooze_until: '2026-10-14T10:05:00Z' };
  assert.equal(workAlarm([r], T('09:30:00')).due, false);
  assert.equal(workAlarm([r], T('09:30:00')).left, 35 * M);
  assert.equal(workUntilBreak([r], T('10:00:00')), 5 * M);
  const a = workAlarm([r], T('10:21:00'));
  assert.deepEqual([a.due, a.at, a.slot], [true, T('10:05:00'), 1]);
  // snooze sprzed upływu godziny nie skraca godziny
  assert.equal(workAlarm([{ ...run('08:00:00'), snooze_until: '2026-10-14T08:10:00Z' }], T('08:30:00')).at, T('09:00:00'));
});

test('workAlarmMsg: zwykłe słowa, pierwszy alarm i przypomnienie', () => {
  assert.deepEqual(workAlarmMsg(60, 60 * M, 'GetMed', 0), { title: 'Minęła godzina pracy', body: 'Kliknij, żeby zrobić przerwę. Stoper liczy dalej (GetMed).' });
  assert.equal(workAlarmMsg(45, 45 * M, 'GetMed', 0).title, 'Minęło 45 min pracy');
  assert.equal(workAlarmMsg(60, 75 * M, '', 1).title, 'Czas na przerwę – pracujesz już 1:15');
  assert.equal(workAlarmMsg(60, 75 * M, '', 1).body, 'Kliknij, żeby zrobić przerwę. Stoper liczy dalej.');
});

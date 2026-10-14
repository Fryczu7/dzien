import { test } from 'node:test';
import assert from 'node:assert/strict';
import { przegladDoPokazania, przegladPozniej, przegladOtworzyc, przegladPrzyciski, przegladDalej, PRZEGLAD_PRZERWA_MS } from '../lib.js';

const r = (id, pokaz_od, created_at, status = 'nowe') => ({ id, pokaz_od, created_at, status });

test('do pokazania: tylko nowe, od dziś wstecz, od najstarszej', () => {
  const rows = [r('c', '2026-10-14', '2026-10-14T03:00:00Z'), r('a', '2026-10-13', '2026-10-13T02:00:00Z'),
    r('przyszla', '2026-10-19', '2026-10-14T01:00:00Z'), r('zdecydowana', '2026-10-14', '2026-10-14T01:00:00Z', 'tak'),
    r('b', '2026-10-14', '2026-10-14T02:00:00Z')];
  assert.deepEqual(przegladDoPokazania(rows, '2026-10-14').map(x => x.id), ['a', 'b', 'c']);
  assert.deepEqual(przegladDoPokazania(null, '2026-10-14'), []);
});

test('„Później”: ten sam dzień schowane, nowy dzień pokazuje', () => {
  const t = Date.parse('2026-10-14T10:00:00Z');
  assert.equal(przegladPozniej(null, '2026-10-14', t, true), false);
  assert.equal(przegladPozniej({ date: '2026-10-14', t }, '2026-10-14', t + 60e3, false), true);
  assert.equal(przegladPozniej({ date: '2026-10-13', t }, '2026-10-14', t, false), false);
});

test('„Później”: ponowne uruchomienie apki po 2 h pokazuje, wcześniej nie', () => {
  const t = Date.parse('2026-10-14T10:00:00Z');
  assert.equal(przegladPozniej({ date: '2026-10-14', t }, '2026-10-14', t + 30 * 60e3, true), true);
  assert.equal(przegladPozniej({ date: '2026-10-14', t }, '2026-10-14', t + PRZEGLAD_PRZERWA_MS, true), false);
  assert.equal(przegladPozniej({ date: '2026-10-14', t }, '2026-10-14', t + PRZEGLAD_PRZERWA_MS, false), true); // odświeżenie w tle – nie
});

test('otworzyć: tylko gdy są pozycje, nie odłożone, nie w trakcie pisania i bez innego okna', () => {
  const ok = { count: 3, odlozone: false, pisze: false, inneOkno: false };
  assert.equal(przegladOtworzyc(ok), true);
  assert.equal(przegladOtworzyc({ ...ok, count: 0 }), false);
  assert.equal(przegladOtworzyc({ ...ok, odlozone: true }), false);
  assert.equal(przegladOtworzyc({ ...ok, pisze: true }), false);
  assert.equal(przegladOtworzyc({ ...ok, inneOkno: true }), false);
});

test('przyciski: wątpliwość z akcją, bez akcji, poprawka', () => {
  const k = p => przegladPrzyciski(p).map(x => x[0]);
  assert.deepEqual(k({ rodzaj: 'watpliwosc', akcja: [{ memory_id: 'x', status: 'zrobione' }] }), ['tak', 'zostaw', 'napisz']);
  assert.deepEqual(k({ rodzaj: 'watpliwosc', akcja: [] }), ['zostaw', 'napisz']);
  assert.deepEqual(k({ rodzaj: 'watpliwosc', akcja: null }), ['zostaw', 'napisz']);
  assert.deepEqual(k({ rodzaj: 'poprawka', akcja: [] }), ['ok', 'cofnij', 'napisz']);
});

test('wynik zapisu: ok i już zamknięte idą dalej, inne nie', () => {
  assert.equal(przegladDalej('ok'), true);
  assert.equal(przegladDalej('już zdecydowane'), true);
  assert.equal(przegladDalej('brak pozycji'), true);
  assert.equal(przegladDalej(undefined), false);
});

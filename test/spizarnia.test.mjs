import { test } from 'node:test';
import assert from 'node:assert/strict';
import { daysBetween, usualDays, productState, pantry, toBuy, agoTxt, everyTxt, stateLine } from '../spizarnia.js';

const mleko = { id: 'm', name: 'Mleko b/l', start_days: 4, sort: 1 };
const platki = { id: 'p', name: 'Płatki owsiane', start_days: 14, sort: 2 };
const jajka = { id: 'j', name: 'Jajka', start_days: 5, sort: 3 };
const buy = (product_id, date) => ({ product_id, date });

test('daysBetween: pełne dni, także przez zmianę czasu (25.10)', () => {
  assert.equal(daysBetween('2026-10-14', '2026-10-20'), 6);
  assert.equal(daysBetween('2026-10-24', '2026-10-26'), 2);
});

test('usualDays: 0 odstępów = start_days', () => {
  assert.equal(usualDays(4, []), 4);
  assert.equal(usualDays(4, ['2026-10-14']), 4);
});

test('usualDays: 1 odstęp = średnia ze start_days i tego odstępu', () => {
  assert.equal(usualDays(4, ['2026-10-10', '2026-10-16']), 5);
});

test('usualDays: średnia z ostatnich 3 odstępów, starsze pomijane', () => {
  // odstępy: 10, 3, 4, 5 → ostatnie trzy 3, 4, 5 → 4
  assert.equal(usualDays(7, ['2026-09-01', '2026-09-11', '2026-09-14', '2026-09-18', '2026-09-23']), 4);
  // kolejność wejścia bez znaczenia, dwa zakupy tego samego dnia = jeden
  assert.equal(usualDays(7, ['2026-09-23', '2026-09-14', '2026-09-18', '2026-09-18', '2026-09-11', '2026-09-01']), 4);
});

test('productState: bez zakupów = brak danych', () => {
  const s = productState(mleko, [], '2026-10-14');
  assert.equal(s.state, 'nieznany'); assert.equal(s.ratio, null);
});

test('productState: progi 80% i 120%', () => {
  const p = [buy('p', '2026-10-01')]; // odstęp 14
  assert.equal(productState(platki, p, '2026-10-11').state, 'mam');      // 10/14 = 0,71
  assert.equal(productState(platki, p, '2026-10-13').state, 'konczy');   // 12/14 = 0,86
  assert.equal(productState(platki, [buy('p', '2026-10-01')], '2026-10-12').state, 'mam'); // 11/14 = 0,79
  assert.equal(productState(jajka, [buy('j', '2026-10-01')], '2026-10-05').state, 'konczy'); // 4/5 = dokładnie 0,8
  assert.equal(productState(jajka, [buy('j', '2026-10-01')], '2026-10-07').state, 'brak');   // 6/5 = dokładnie 1,2
});

test('productState: liczy od ostatniego zakupu, przyszłe daty pomija', () => {
  const s = productState(mleko, [buy('m', '2026-10-10'), buy('m', '2026-10-14'), buy('m', '2026-10-30')], '2026-10-16');
  assert.equal(s.last, '2026-10-14'); assert.equal(s.since, 2); assert.equal(s.usual, 4); // (4 + 4) / 2
});

test('toBuy: tylko ≥ 80%, najbardziej zaległe na górze, bez nieaktywnych i bez danych', () => {
  const products = [mleko, platki, jajka, { id: 'x', name: 'Łosoś', start_days: 14, active: false }, { id: 'n', name: 'Ryż', start_days: 14 }];
  const purchases = [buy('m', '2026-10-14'), buy('p', '2026-10-05'), buy('j', '2026-10-10'), buy('x', '2026-09-01')];
  const l = toBuy(products, purchases, '2026-10-17'); // mleko 3/4 = 0,75; płatki 12/14 = 0,86; jajka 7/5 = 1,4
  assert.deepEqual(l.map(s => s.product.name), ['Jajka', 'Płatki owsiane']);
  assert.deepEqual(l.map(s => s.state), ['brak', 'konczy']);
});

test('pantry: wszystkie aktywne po sort, z produktami bez danych', () => {
  const l = pantry([jajka, platki, mleko], [buy('m', '2026-10-14')], '2026-10-14');
  assert.deepEqual(l.map(s => [s.product.name, s.state]), [['Mleko b/l', 'mam'], ['Płatki owsiane', 'nieznany'], ['Jajka', 'nieznany']]);
});

test('teksty: „ostatnio 6 dni temu · zwykle co 7 dni”', () => {
  assert.equal(agoTxt(0), 'dziś'); assert.equal(agoTxt(1), 'wczoraj'); assert.equal(agoTxt(6), '6 dni temu');
  assert.equal(everyTxt(1), 'codziennie'); assert.equal(everyTxt(4.5), 'co 5 dni'); assert.equal(everyTxt(0.4), 'codziennie');
  const s = productState({ id: 'k', name: 'Pierś', start_days: 7 }, [buy('k', '2026-10-08')], '2026-10-14');
  assert.equal(stateLine(s), 'ostatnio 6 dni temu · zwykle co 7 dni');
  assert.equal(stateLine(productState(mleko, [], '2026-10-14')), 'jeszcze nie kupione · zwykle co 4 dni');
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { planWithoutToggles, parseCoach, quickFromHistory, matchesQuery, nextView } from '../lib.js';

test('planWithoutToggles: rehab i leki nie dublują przycisków, indeksy zostają', () => {
  const plan = [{ text: 'GetMed: film #1' }, { text: 'Rehab' }, { text: 'ZT: publikacja' }, { text: 'leki wieczorem' }, { text: 'Rehabilitacja 20 min' }];
  assert.deepEqual(planWithoutToggles(plan).map(x => [x.idx, x.p.text]), [[0, 'GetMed: film #1'], [2, 'ZT: publikacja']]);
});

test('parseCoach: punkty z „|”, linia „W nocy zrobiłem”', () => {
  const t = '1. Zadzwoń do Model–Ursynów | Pytał o cenę we wrześniu.\n2. Dobij kalorie | Brakuje 2250.\nW nocy zrobiłem: lista 10 szkół.';
  assert.deepEqual(parseCoach(t), {
    items: [{ what: 'Zadzwoń do Model–Ursynów', why: 'Pytał o cenę we wrześniu.' }, { what: 'Dobij kalorie', why: 'Brakuje 2250.' }],
    night: 'lista 10 szkół.',
  });
});

test('parseCoach: stary format bez „|” – pierwsze zdanie to „co”', () => {
  const t = '1. 16:00 jeden telefon: Model–Ursynów. Pytał o cenę 10.09.\nJedzenie: wczoraj 1000 kcal.';
  const r = parseCoach(t);
  assert.equal(r.items[0].what, '16:00 jeden telefon: Model–Ursynów');
  assert.equal(r.items[0].why, 'Pytał o cenę 10.09.');
  assert.equal(r.items[1].what, 'Jedzenie: wczoraj 1000 kcal');
  assert.equal(r.night, null);
  assert.deepEqual(parseCoach(''), { items: [], night: null });
});

test('quickFromHistory: wszystkie zjedzone posiłki, najczęstsze na górze, bez pustych kcal', () => {
  const rows = [
    { name: 'Owsianka', kcal: 500, protein: 20 }, { name: 'owsianka ', kcal: 520, protein: 22 },
    { name: 'Banan', kcal: 105, protein: 1 }, { name: 'Coś', kcal: null, protein: null },
  ];
  const q = quickFromHistory(rows, [['Shake (mleko)', 600, 40]]);
  assert.deepEqual(q.map(x => [x.name, x.kcal, x.n]), [['Owsianka', 500, 2], ['Banan', 105, 1], ['Shake (mleko)', 600, 0]]);
});

test('matchesQuery: bez wielkości liter i polskich znaków', () => {
  assert.equal(matchesQuery('Łosoś z ryżem', 'losos'), true);
  assert.equal(matchesQuery('Banan', 'jab'), false);
  assert.equal(matchesQuery('Banan', ''), true);
});

test('nextView: przesunięcie palcem po zakładkach, bez zawijania', () => {
  const v = ['dzis', 'jedzenie', 'zakupy', 'coach'];
  assert.equal(nextView(v, 'dzis', 1), 'jedzenie');
  assert.equal(nextView(v, 'coach', 1), 'coach');
  assert.equal(nextView(v, 'jedzenie', -1), 'dzis');
});

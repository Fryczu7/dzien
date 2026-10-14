import { test } from 'node:test';
import assert from 'node:assert/strict';
import { kzNaZywo, kzPostep, kzWidoczne, kzZyski, kzKamien, kzDni, kzLicznik, kzPasek, kzDoPokazania, kzNoweZadanie, kzDniTekst, kzZadaniaZapis, KZ_STATY } from '../lib.js';

const H = 3600e3;
const z = (k, o = {}) => ({ k, nazwa: k, zrodlo: 'reczne', postep: 0, cel: 1, zrobione: false, xp: 0, stat: 'Wiedza', aktywne: true, ...o });
const dzien = (zadania, o = {}) => ({ date: '2026-10-14', zadania, xp: zadania.reduce((s, x) => s + x.xp, 0), czysty: false, zaliczony: false, ...o });

test('kzNaZywo: godziny stopera z apki nadpisują postęp pracy (rosną na żywo)', () => {
  const d = dzien([z('getmed', { zrodlo: 'praca:getmed', postep: 1, cel: 4, jedn: 'h', xp: 10, stat: 'Pracowitość' })]);
  const r = kzNaZywo(d, { getmed: 1.5 * H });
  assert.equal(r.zadania[0].postep, 1.5);
  assert.equal(r.zadania[0].xp, 15);
  assert.equal(r.xp, 15);
  assert.equal(d.zadania[0].postep, 1, 'nie zmienia wejścia');
});

test('kzNaZywo: praca łącznie najwyżej 100 XP na dzień', () => {
  const d = dzien([z('getmed', { zrodlo: 'praca:getmed', cel: 4, jedn: 'h' }), z('zlap', { zrodlo: 'praca:zlap', cel: 1, jedn: 'h' }), z('modlitwa')]);
  const r = kzNaZywo(d, { getmed: 8 * H, zlap: 2 * H });
  assert.deepEqual(r.zadania.map(x => x.xp), [80, 20, 0]);
  assert.equal(r.xp, 100);
});

test('kzNaZywo: przekroczony cel = zrobione, czysty dzień dodaje 25 XP i zalicza dzień', () => {
  const d = dzien([z('getmed', { zrodlo: 'praca:getmed', cel: 1, jedn: 'h' }), z('modlitwa', { zrobione: true, xp: 10 })]);
  const r = kzNaZywo(d, { getmed: 1 * H });
  assert.equal(r.zadania[0].zrobione, true);
  assert.equal(r.czysty, true);
  assert.equal(r.zaliczony, true);
  assert.equal(r.xp, 10 + 10 + 25);
});

test('kzNaZywo: zadanie nieaktywne nie psuje czystego dnia', () => {
  const d = dzien([z('getmed', { zrodlo: 'praca:getmed', cel: 4, jedn: 'h', aktywne: false }), z('modlitwa', { zrobione: true, xp: 10 })]);
  const r = kzNaZywo(d, {});
  assert.equal(r.czysty, true);
  assert.equal(r.xp, 35);
});

test('kzNaZywo: bez danych stopera zostawia wynik z bazy', () => {
  const d = dzien([z('getmed', { zrodlo: 'praca:getmed', postep: 2, cel: 4, xp: 20 })]);
  assert.equal(kzNaZywo(d, null).zadania[0].postep, 2);
  assert.equal(kzNaZywo(null, {}), null);
});

test('kzPostep: godziny, kalorie, sen i plan po polsku; zadania tak/nie bez liczby', () => {
  assert.equal(kzPostep(z('g', { zrodlo: 'praca:getmed', postep: 1.5, cel: 4, jedn: 'h' })), '1,5 / 4 h');
  assert.equal(kzPostep(z('k', { zrodlo: 'kalorie', postep: 0.9, cel: 0.9, kcal: 2970, kcal_cel: 3300 })), '2970 / 3300 kcal');
  assert.equal(kzPostep(z('s', { zrodlo: 'sen', postep: 7.5, cel: 7 })), '7,5 / 7 h');
  assert.equal(kzPostep(z('p', { zrodlo: 'plan', postep: 1, cel: 2 })), '1 / 2');
  assert.equal(kzPostep(z('m', { zrodlo: 'modlitwa' })), '');
  assert.equal(kzPostep(z('t', { zrodlo: 'trening', postep: 0, cel: 1 })), '');
});

test('kzWidoczne: nieaktywne tylko, gdy dały punkty (np. praca w sobotę – premia)', () => {
  const lista = [z('a'), z('b', { aktywne: false }), z('c', { aktywne: false, xp: 20 })];
  assert.deepEqual(kzWidoczne(lista).map(x => [x.k, !!x.premia]), [['a', false], ['c', true]]);
});

test('kzZyski: +XP przy zadaniu, które zyskało punkty; pierwsze wczytanie bez animacji', () => {
  const a = dzien([z('modlitwa'), z('sen', { xp: 15, zrobione: true })]);
  const b = dzien([z('modlitwa', { xp: 10, zrobione: true }), z('sen', { xp: 15, zrobione: true })]);
  assert.deepEqual(kzZyski(a, b), [{ k: 'modlitwa', xp: 10 }]);
  assert.deepEqual(kzZyski(null, b), []);
});

test('kzZyski: stoper daje „+10” dopiero przy pełnej godzinie', () => {
  const g = p => dzien([z('getmed', { zrodlo: 'praca:getmed', postep: p, cel: 4, xp: Math.round(p * 10) })]);
  assert.deepEqual(kzZyski(g(0.9), g(0.95)), []);
  assert.deepEqual(kzZyski(g(0.95), g(1.01)), [{ k: 'getmed', xp: 10 }]);
  assert.deepEqual(kzZyski(g(0.5), g(2.1)), [{ k: 'getmed', xp: 20 }]);
});

test('kzKamien: 7 / 30 / 100 dni serii tylko przy przejściu progu', () => {
  assert.equal(kzKamien(6, 7), 7);
  assert.equal(kzKamien(7, 8), null);
  assert.equal(kzKamien(29, 30), 30);
  assert.equal(kzKamien(99, 100), 100);
  assert.equal(kzKamien(0, 0), null);
});

test('kzDni: 1 dzień, 2 dni, 5 dni', () => {
  assert.equal(kzDni(1), '1 dzień'); assert.equal(kzDni(2), '2 dni'); assert.equal(kzDni(0), '0 dni'); assert.equal(kzDni(22), '22 dni');
});

test('kzLicznik: licznik XP rośnie szybko na początku i kończy dokładnie na wyniku', () => {
  assert.equal(kzLicznik(120, 0), 0);
  assert.equal(kzLicznik(120, 1), 120);
  assert.equal(kzLicznik(120, 2), 120);
  assert.ok(kzLicznik(120, 0.3) > 120 * 0.5, 'po 30% czasu ponad połowa');
  assert.ok(kzLicznik(120, 0.9) <= 120);
  assert.equal(kzLicznik(-30, 1), -30, 'ujemne też (kara w Hard)');
});

test('kzPasek: część poziomu 0–1', () => {
  assert.equal(kzPasek({ w_poziomie: 75, prog: 150 }), 0.5);
  assert.equal(kzPasek({ w_poziomie: 0, prog: 0 }), 0);
  assert.equal(kzPasek(null), 0);
});

test('kzDoPokazania: podsumowanie ostatniego zamkniętego dnia, którego jeszcze nie widział', () => {
  const w = [{ date: '2026-10-12' }, { date: '2026-10-13' }];
  assert.equal(kzDoPokazania(w, null).date, '2026-10-13');
  assert.equal(kzDoPokazania(w, '2026-10-12').date, '2026-10-13');
  assert.equal(kzDoPokazania(w, '2026-10-13'), null, 'już pokazane (np. Zakończ dzień wczoraj)');
  assert.equal(kzDoPokazania([], null), null);
  assert.equal(kzDoPokazania(null, null), null);
});

test('kzNoweZadanie: własne zadanie do odhaczania z unikalnym kluczem', () => {
  const t = kzNoweZadanie('Czytanie 20 min', [{ k: 'czytanie_20_min' }]);
  assert.deepEqual(t, { k: 'czytanie_20_min_2', nazwa: 'Czytanie 20 min', zrodlo: 'reczne', cel: 1, xp: 10, stat: 'Wiedza' });
  assert.equal(kzNoweZadanie('  ', []), null);
});

test('kzDniTekst: dni tygodnia po ludzku', () => {
  assert.equal(kzDniTekst(undefined), 'codziennie');
  assert.equal(kzDniTekst([1, 2, 3, 4, 5, 6, 7]), 'codziennie');
  assert.equal(kzDniTekst([1, 2, 3, 4, 5]), 'pn–pt');
  assert.equal(kzDniTekst([1, 3]), 'pn, śr');
  assert.equal(kzDniTekst([]), 'nigdy');
});

test('kzZadaniaZapis: zła liczba XP albo celu wraca do rozsądnej, dni 7/7 = brak pola', () => {
  const r = kzZadaniaZapis([{ k: 'a', nazwa: 'A', zrodlo: 'reczne', cel: 1, xp: 500, dni: [1, 2, 3, 4, 5, 6, 7] }, { k: 'g', nazwa: 'G', zrodlo: 'praca:getmed', cel: -2, xp_jedn: 10 }]);
  assert.equal(r[0].xp, 100);
  assert.equal('dni' in r[0], false);
  assert.equal(r[1].cel, 1);
});

test('KZ_STATY: 8 statystyk w 4 obszarach', () => {
  assert.equal(KZ_STATY.flatMap(([, s]) => s).length, 8);
  assert.deepEqual(KZ_STATY.map(([o]) => o), ['Ciało', 'Praca', 'Głowa', 'Duch i relacje']);
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { kalorieRozliczenie, KCAL_PYTAJ_OD } from '../lib.js';

// Wiersz „Kalorie dziś: Dobite / Nie” w zakładce Jedzenie – tylko gdy dzień nie jest rozliczony.
const dzis = '2026-10-18';
const baza = { zjedzone: 900, cel: 3200, ok: null, dzien: dzis, dzis, godzina: 19 };

test('nierozliczony wieczór: pytaj', () => {
  assert.equal(kalorieRozliczenie(baza), 'pytaj');
  assert.equal(kalorieRozliczenie({ ...baza, zjedzone: 0 }), 'pytaj');
});

test('posiłki ≥ 90% celu: wiersza nie ma', () => {
  assert.equal(kalorieRozliczenie({ ...baza, zjedzone: 2880 }), 'ukryj');
  assert.equal(kalorieRozliczenie({ ...baza, zjedzone: 2879 }), 'pytaj');
});

test('odpowiedź już jest: zwinięty wiersz (z cofnięciem)', () => {
  assert.equal(kalorieRozliczenie({ ...baza, ok: true }), 'dobite');
  assert.equal(kalorieRozliczenie({ ...baza, ok: false }), 'niedobite');
  // nawet gdy posiłki później przekroczą 90% – zostaje, żeby dało się cofnąć
  assert.equal(kalorieRozliczenie({ ...baza, ok: true, zjedzone: 3300 }), 'dobite');
});

test('dziś przed wieczorem: nie pytaj (jeszcze nie ma czego rozliczać)', () => {
  assert.equal(kalorieRozliczenie({ ...baza, godzina: KCAL_PYTAJ_OD - 1 }), 'ukryj');
  assert.equal(kalorieRozliczenie({ ...baza, godzina: KCAL_PYTAJ_OD }), 'pytaj');
  // odpowiedź z rozmowy widać od razu, o każdej porze
  assert.equal(kalorieRozliczenie({ ...baza, godzina: 10, ok: true }), 'dobite');
});

test('wczorajszy dzień: pytaj o każdej porze; przyszły: nigdy', () => {
  assert.equal(kalorieRozliczenie({ ...baza, dzien: '2026-10-17', godzina: 8 }), 'pytaj');
  assert.equal(kalorieRozliczenie({ ...baza, dzien: '2026-10-19' }), 'ukryj');
});

test('brak celu: pytaj (nie dzielimy przez zero)', () => {
  assert.equal(kalorieRozliczenie({ ...baza, cel: null }), 'pytaj');
});

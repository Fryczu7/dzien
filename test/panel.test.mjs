import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isTrainingText, trainingWeeks, weekStats, applyDecision, PANEL_CARDS, PANEL_TABS, visibleViews, itemKey, parseHours, fmtHoursInput } from '../lib.js';

test('isTrainingText: „brak – wspinaczka odpuszczona” to nie trening', () => {
  assert.equal(isTrainingText('siłownia OK'), true);
  assert.equal(isTrainingText('klatka + triceps'), true);
  for (const t of ['brak – wspinaczka odpuszczona', 'nie byłem', 'odpuszczone', 'odwołane', 'Brak', '-', '', null]) assert.equal(isTrainingText(t), false, String(t));
});

test('tydzień nie liczy dnia z tekstem „brak …” jako treningu', () => {
  const days = [{ date: '2026-10-12', training: 'brak – wspinaczka odpuszczona' }, { date: '2026-10-13', training: 'siłownia' }];
  assert.equal(trainingWeeks([], days, '2026-10-13', 1)[0].done, 1);
  assert.equal(weekStats(days, [], '2026-10-13').training, 1);
});

test('applyDecision: limit planu z ustawień', () => {
  const plan = [{ text: 'a' }, { text: 'b' }, { text: 'c' }], P = { id: 'p', kind: 'dzien', title: 'd' };
  assert.equal(applyDecision(plan, P, 'wez').error, 'max3');
  assert.equal(applyDecision(plan, P, 'wez', '', 4).plan.length, 4);
});

test('panel: karty i zakładki, wyłączone zakładki znikają z kolejności', () => {
  assert.ok(PANEL_CARDS.some(([k]) => k === 'modlitwy'));
  assert.ok(PANEL_TABS.every(([k]) => k !== 'dzis'));
  assert.deepEqual(visibleViews(['dzis', 'jedzenie', 'zakupy', 'trening'], ['tab-zakupy', 'modlitwy']), ['dzis', 'jedzenie', 'trening']);
});

test('itemKey: klucz z nazwy, bez powtórek', () => {
  assert.equal(itemKey('Łóżko pościelone', []), 'lozko_poscielone');
  assert.equal(itemKey('Woda', [['woda', 'Woda']]), 'woda_2');
});

test('parseHours / fmtHoursInput: godziny w panelu celów', () => {
  assert.equal(parseHours('4'), 240);
  assert.equal(parseHours('4,5'), 270);
  assert.equal(parseHours('3:30'), 210);
  assert.equal(parseHours('abc'), null);
  assert.equal(fmtHoursInput(270), '4,5');
  assert.equal(fmtHoursInput(1200), '20');
});

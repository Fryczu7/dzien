import { test } from 'node:test';
import assert from 'node:assert/strict';
import { menuTotals, menuNeedsChoice, chooseOption, eatItem, uneatItem, menuTimeline, menuChosen } from '../lib.js';

const opt = (name, kcal, protein, src) => ({ name, kcal, protein, src, detail: name + ' – skład' });
const menu = () => ({
  slots: [
    { slot: 'sniadanie', label: 'Śniadanie', time: '11:00', chosen: null, eaten: false, options: [opt('Jajecznica', 550, 31, 'jak_ostatnio'), opt('Owsianka', 785, 52, 'z_planu'), opt('Omlet', 625, 37, 'nowe')] },
    { slot: 'obiad', label: 'Obiad', time: '15:30', chosen: null, eaten: false, options: [opt('Kurczak z blachy', 700, 50, 'jak_ostatnio'), opt('Kurczak z ryżem', 747, 45, 'z_planu'), opt('Łosoś', 775, 39, 'nowe')] },
    { slot: 'kolacja', label: 'Kolacja', time: '20:00', chosen: null, eaten: false, options: [opt('Kanapki', 450, 26, 'jak_ostatnio'), opt('Kanapki z jajkiem', 585, 30, 'z_planu'), opt('Skyr', 567, 28, 'nowe')] },
  ],
  stale: [{ name: 'Shake', kcal: 730, protein: 48, time: '13:30' }, { name: 'Banan', kcal: 105, protein: 1, time: '18:00' }, { name: 'Mieszanka studencka 100 g', kcal: 500, protein: 15, time: '17:30' }],
  kupic: ['ogórek'], note: 'Środa, wspinaczka.',
});

test('menuTotals: bez wyboru liczą się tylko stałe, posiłki bez wyboru w „open”', () => {
  assert.deepEqual(menuTotals(menu()), { kcal: 1335, protein: 64, open: ['Śniadanie', 'Obiad', 'Kolacja'] });
  assert.deepEqual(menuTotals(null), { kcal: 0, protein: 0, open: [] });
});

test('menuTotals: stałe + wybrane opcje (indeks 0 też się liczy)', () => {
  const m = menu(); m.slots[0].chosen = 1; m.slots[1].chosen = 0;
  assert.deepEqual(menuTotals(m), { kcal: 1335 + 785 + 700, protein: 64 + 52 + 50, open: ['Kolacja'] });
});

test('menuNeedsChoice: „Wybierz menu” widoczne, dopóki któryś posiłek nie ma wyboru', () => {
  const m = menu();
  assert.equal(menuNeedsChoice(null), false);
  assert.equal(menuNeedsChoice(m), true);
  m.slots[0].chosen = 0; m.slots[1].chosen = 2;
  assert.equal(menuNeedsChoice(m), true);
  m.slots[2].chosen = 0;
  assert.equal(menuNeedsChoice(m), false);
  // indeks spoza listy to nie wybór
  m.slots[2].chosen = 7;
  assert.equal(menuNeedsChoice(m), true);
});

test('chooseOption: zmienia tylko ten posiłek; zjedzonego nie zmienia', () => {
  const m = menu(), s = chooseOption(m.slots, 1, 2);
  assert.equal(s[1].chosen, 2);
  assert.equal(s[0], m.slots[0]);
  assert.equal(m.slots[1].chosen, null, 'bez mutacji wejścia');
  assert.equal(chooseOption(s, 1, 0)[1].chosen, 0, 'zmiana wyboru przed zjedzeniem');
  assert.equal(chooseOption(m.slots, 1, 5), null);
  const z = chooseOption(m.slots, 0, 0); z[0].eaten = true;
  assert.equal(chooseOption(z, 0, 1), null);
});

test('eatItem: wybrany posiłek → wpis do meals + eaten; drugi klik nic nie robi', () => {
  const m = menu();
  assert.equal(eatItem(m, 'slot', 0), null, 'bez wyboru nie ma czego zapisać');
  m.slots[0].chosen = 1;
  const r = eatItem(m, 'slot', 0);
  assert.deepEqual(r.meal, { name: 'Owsianka', kcal: 785, protein: 52 });
  assert.equal(r.patch.slots[0].eaten, true);
  assert.equal(r.patch.slots[0].chosen, 1);
  assert.equal(m.slots[0].eaten, false, 'bez mutacji wejścia');
  m.slots = r.patch.slots;
  assert.equal(eatItem(m, 'slot', 0), null);
});

test('eatItem: stała pozycja → wpis + stale[i].eaten; cofnięcie zdejmuje eaten', () => {
  const m = menu(), r = eatItem(m, 'stale', 2);
  assert.deepEqual(r.meal, { name: 'Mieszanka studencka 100 g', kcal: 500, protein: 15 });
  assert.deepEqual(r.patch.stale.map(x => !!x.eaten), [false, false, true]);
  m.stale = r.patch.stale;
  assert.equal(eatItem(m, 'stale', 2), null);
  assert.deepEqual(uneatItem(m, 'stale', 2).stale.map(x => !!x.eaten), [false, false, false]);
  assert.equal(eatItem(m, 'stale', 9), null);
});

test('menuChosen i menuTimeline: kolejność po godzinie, stałe między posiłkami', () => {
  const m = menu(); m.slots[2].chosen = 0;
  assert.equal(menuChosen(m.slots[2]).name, 'Kanapki');
  assert.equal(menuChosen(m.slots[0]), null);
  m.stale.push({ name: 'Bez godziny', kcal: 1 }); m.slots[0].time = '9:30';
  assert.deepEqual(menuTimeline(m).map(r => r.x.name || r.x.label), ['Śniadanie', 'Shake', 'Obiad', 'Mieszanka studencka 100 g', 'Banan', 'Kolacja', 'Bez godziny']);
  assert.deepEqual(menuTimeline(null), []);
});

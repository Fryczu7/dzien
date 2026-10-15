import { test } from 'node:test';
import assert from 'node:assert/strict';
import { menuLeft, menuTotals, menuNeedsChoice, slotGone, otherSuggestions } from '../lib.js';

// „Powiem Claude”: posiłek zjedzony inaczej, kalorie dopisze Claude – nie wisi jako do wyboru i nie liczy się do „zostało w planie”.
const opt = { name: 'Jajecznica z 4 jajek na boczku', kcal: 550, protein: 31 };
const menu = { slots: [{ slot: 'sniadanie', time: '11:00', chosen: 0, options: [opt], pending: 'claude' }, { slot: 'kolacja', time: '20:00', chosen: null, options: [opt, opt] }], stale: [] };

test('pending: nie liczy się do zostało w planie ani do sumy', () => {
  assert.deepEqual(menuLeft(menu), { kcal: 0, protein: 0 });
  assert.equal(menuTotals(menu, 600).kcal, 0);
  assert.deepEqual(menuTotals(menu, 600).open, ['kolacja']);
});

test('pending: nie wymaga wyboru i nie znika z listy', () => {
  const m = { slots: [menu.slots[0]], stale: [] };
  assert.equal(menuNeedsChoice(m, 600), false);
  assert.equal(slotGone(menu.slots[0], 900), false);
});

test('podpowiedzi „coś innego”: tylko to, co naprawdę jadł, bez szablonów i bez dubli', () => {
  const hist = [{ name: 'Jajecznica z 4 jajek na boczku', kcal: 550, protein: 31 }, { name: 'jajecznica z 4 jajek na boczku ', kcal: 560, protein: 31 }, { name: 'Bigos', kcal: 690, protein: 30 }];
  const s = otherSuggestions(hist, '');
  assert.deepEqual(s.map(x => x.name), ['Jajecznica z 4 jajek na boczku', 'Bigos']);
  assert.deepEqual(otherSuggestions(hist, 'big').map(x => x.name), ['Bigos']);
});

test('podpowiedzi „coś innego”: najpierw to, co jadł o podobnej porze (±3 h od posiłku)', () => {
  const hist = [
    { name: '100 g ryżu + porcja obiadu', kcal: 650, protein: 40, time: '15:00' },
    { name: '100 g ryżu + porcja obiadu', kcal: 650, protein: 40, time: '16:10' },
    { name: 'Jajecznica z 3 jajek z boczkiem', kcal: 480, protein: 26, time: '11:57' },
    { name: 'Owsianka', kcal: 500, protein: 20, time: '09:30' },
    { name: 'Bułki z pasztetem', kcal: 400, protein: 12, time: null },
  ];
  assert.deepEqual(otherSuggestions(hist, '', '11:00').map(x => x.name), ['Jajecznica z 3 jajek z boczkiem', 'Owsianka']);
  assert.equal(otherSuggestions(hist, 'ryż', '11:00')[0].name, '100 g ryżu + porcja obiadu', 'szukanie obejmuje całą historię');
});

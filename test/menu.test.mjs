import { test } from 'node:test';
import assert from 'node:assert/strict';
import { menuTotals, menuNeedsChoice, chooseOption, eatItem, uneatItem, menuTimeline, menuChosen, slotGone, menuLeft, eatOther, menuOtherMsg, MENU_SRC, menuPage, menuRecipe, MENU_PAGE, menuLastSlot, menuSuggest, menuSlotForNow, chooseSuggested, menuNeed } from '../lib.js';

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

test('menuChosen i menuTimeline: posiłki po godzinie, stałe osobno', () => {
  const m = menu(); m.slots[2].chosen = 0;
  assert.equal(menuChosen(m.slots[2]).name, 'Kanapki');
  assert.equal(menuChosen(m.slots[0]), null);
  m.slots[0].time = '21:30';
  assert.deepEqual(menuTimeline(m).map(r => r.x.label), ['Obiad', 'Kolacja', 'Śniadanie']);
  assert.ok(menuTimeline(m).every(r => r.kind === 'slot'));
  assert.deepEqual(menuTimeline(null), []);
});

test('slotGone: posiłek bez wyboru znika 2 h po swojej porze, na minionym dniu od razu', () => {
  const m = menu(), sn = m.slots[0]; // 11:00
  assert.equal(slotGone(sn, 12 * 60 + 59), false);
  assert.equal(slotGone(sn, 13 * 60), true);
  assert.equal(slotGone(sn, 'miniony'), true);
  assert.equal(slotGone(sn, null), false);
  sn.chosen = 0; assert.equal(slotGone(sn, 16 * 60), false, 'wybrany zostaje, żeby kliknąć „Zjadłem”');
  sn.chosen = null; sn.eaten = true; assert.equal(slotGone(sn, 16 * 60), false);
});

test('menuNeedsChoice i menuTotals.open o 16:00: śniadanie z 11:00 już nie wisi', () => {
  const m = menu(), o16 = 16 * 60;
  assert.deepEqual(menuTotals(m, o16).open, ['Obiad', 'Kolacja']);
  m.slots[1].chosen = 0; m.slots[2].chosen = 0;
  assert.equal(menuNeedsChoice(m, o16), false);
  assert.equal(menuNeedsChoice(m), true, 'bez godziny – śniadanie dalej czeka');
});

test('menuLeft: zostało w planie = wybrane niezjedzone + niezjedzone stałe', () => {
  const m = menu(); m.slots[1].chosen = 0; m.slots[2].chosen = 1; m.slots[2].eaten = true; m.stale[0].eaten = true;
  assert.deepEqual(menuLeft(m), { kcal: 700 + 105 + 500, protein: 50 + 1 + 15 });
  assert.deepEqual(menuLeft(null), { kcal: 0, protein: 0 });
});

test('eatOther: „coś innego” zamyka posiłek, bez kalorii też; drugi raz nic', () => {
  const m = menu(), r = eatOther(m, 1, { name: ' Bigos + 2 bułki ', kcal: 690, protein: 30 });
  assert.deepEqual(r.meal, { name: 'Bigos + 2 bułki', kcal: 690, protein: 30 });
  assert.deepEqual([r.patch.slots[1].eaten, r.patch.slots[1].inne.name, r.patch.slots[1].chosen], [true, 'Bigos + 2 bułki', null]);
  assert.deepEqual(eatOther(m, 0, { name: 'Pasztet z bułką' }).meal, { name: 'Pasztet z bułką', kcal: null, protein: null });
  assert.equal(eatOther(m, 0, { name: '  ' }), null);
  m.slots = r.patch.slots;
  assert.equal(eatOther(m, 1, { name: 'X' }), null);
  // suma liczy „coś innego”; cofnięcie zdejmuje inne
  assert.equal(menuTotals(m).kcal, 1335 + 690);
  const u = uneatItem(m, 'slot', 1).slots[1];
  assert.deepEqual([u.eaten, 'inne' in u, u.meal_id], [false, false, null]);
});

test('menuOtherMsg i etykieta „ustalone”', () => {
  const t = menuOtherMsg('2026-10-14', 'obiad', 'Obiad');
  assert.match(t, /menu_zjedzone\('2026-10-14', 'obiad', '<nazwa>', <kcal>, <białko>\)/);
  assert.match(t, /Zjadłem: $/);
  assert.equal(MENU_SRC.ustalone, 'ustalone');
});

test('menuPage: po 3 opcje, w kółko; 3 opcje = jedna strona', () => {
  const s = n => ({ options: Array.from({ length: n }, (_, i) => ({ name: 'o' + i })) });
  assert.equal(MENU_PAGE, 3);
  assert.deepEqual(menuPage(s(3), 0), { idx: [0, 1, 2], page: 0, pages: 1 });
  assert.deepEqual(menuPage(s(3), 5).idx, [0, 1, 2]);
  assert.deepEqual(menuPage(s(7), 1), { idx: [3, 4, 5], page: 1, pages: 3 });
  assert.deepEqual(menuPage(s(7), 2).idx, [6]);
  assert.deepEqual(menuPage(s(7), 3).idx, [0, 1, 2]);
  assert.deepEqual(menuPage(s(1), 1), { idx: [0], page: 0, pages: 1 });
  assert.deepEqual(menuPage({}, 0), { idx: [], page: 0, pages: 1 });
});

test('menuRecipe: tablica albo tekst, puste kroki wypadają, brak = []', () => {
  assert.deepEqual(menuRecipe({ przepis: ['Krok 1', ' ', 'Krok 2 '] }), ['Krok 1', 'Krok 2']);
  assert.deepEqual(menuRecipe({ przepis: 'a\n\nb' }), ['a', 'b']);
  assert.deepEqual(menuRecipe({ name: 'x', detail: 'y' }), []);
  assert.deepEqual(menuRecipe(null), []);
});

test('ostatni posiłek dnia nie znika po godzinie (decyzja 26.10), wcześniejsze tak', () => {
  const m = menu(), o23 = 23 * 60;
  assert.equal(menuLastSlot(m), 2);
  assert.equal(menuLastSlot({ slots: [] }), -1);
  assert.equal(slotGone(m.slots[2], o23, true), false);
  assert.equal(slotGone(m.slots[2], 'miniony', true), true, 'miniony dzień – bez zmian');
  assert.deepEqual(menuTotals(m, o23).open, ['Kolacja']);
  assert.equal(menuNeedsChoice(m, o23), true);
  m.slots[2].chosen = 0; assert.equal(menuNeedsChoice(m, o23), false);
});

test('menuSuggest: bez dubli, najbliższe brakującym kaloriom i białku na górze', () => {
  const m = menu(); m.slots[2].options.push(opt('Jajecznica', 550, 31, 'nowe'));
  const r = menuSuggest(m, { kcal: 700, protein: 50 });
  assert.equal(r.length, 9);
  assert.deepEqual([r[0].si, r[0].oi, r[0].o.name], [1, 0, 'Kurczak z blachy']);
  assert.equal(menuSuggest(m, { kcal: 450, protein: 26 })[0].o.name, 'Kanapki');
  assert.equal(menuSuggest(m, { kcal: -500, protein: -10 })[0].o.name, 'Kanapki', 'cel przekroczony → najlżejsze');
  assert.deepEqual(menuSuggest(null, { kcal: 1 }), []);
});

test('menuSlotForNow: otwarty posiłek najbliżej godziny; zamknięte pomija', () => {
  const m = menu();
  assert.equal(menuSlotForNow(m, 19 * 60 + 40), 2);
  assert.equal(menuSlotForNow(m, 10 * 60), 0);
  m.slots[2].eaten = true; assert.equal(menuSlotForNow(m, 21 * 60), 1);
  m.slots[0].eaten = m.slots[1].pending = true; assert.equal(menuSlotForNow(m, 21 * 60), -1);
});

test('chooseSuggested: ta sama nazwa → wybór, inna → dopisana opcja i wybrana; zjedzony → null', () => {
  const m = menu();
  assert.equal(chooseSuggested(m.slots, 2, { name: 'kanapki ' })[2].chosen, 0);
  const s = chooseSuggested(m.slots, 2, { ...opt('Kurczak z blachy', 700, 50, 'jak_ostatnio'), domyslne: true });
  assert.equal(s[2].options.length, 4); assert.equal(s[2].chosen, 3); assert.equal(s[2].options[3].domyslne, undefined);
  assert.equal(m.slots[2].options.length, 3, 'bez mutacji');
  m.slots[2].eaten = true; assert.equal(chooseSuggested(m.slots, 2, { name: 'Kanapki' }), null);
});

test('menuNeed: cel − zjedzone − niezjedzone stałe, dzielone na otwarte posiłki', () => {
  const m = menu(); // stałe 1335 / 64
  assert.deepEqual(menuNeed(m, { kcal: 1000, protein: 40 }, { kcal: 3300, protein: 150 }, 10 * 60), { kcal: 965, protein: 46, per: { kcal: 322, protein: 15 } });
  m.stale[0].eaten = true; m.slots[0].eaten = m.slots[1].eaten = true;
  assert.deepEqual(menuNeed(m, { kcal: 2000, protein: 90 }, { kcal: 3300, protein: 150 }, 23 * 60), { kcal: 695, protein: 44, per: { kcal: 695, protein: 44 } });
});

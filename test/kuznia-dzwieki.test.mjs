import { test } from 'node:test';
import assert from 'node:assert/strict';
import { KZ_DZWIEKI, kzDzwiekDnia, kzDzwiekiWlaczone } from '../lib.js';

const dlugosc = tony => Math.max(...tony.map(([, at, dur]) => at + dur));

test('KZ_DZWIEKI: cztery krótkie dźwięki z poprawnymi tonami', () => {
  assert.deepEqual(Object.keys(KZ_DZWIEKI).sort(), ['braki', 'dzien', 'poziom', 'xp']);
  for (const [k, tony] of Object.entries(KZ_DZWIEKI)) {
    assert.ok(tony.length > 0, k);
    for (const [hz, at, dur, vol, typ] of tony) {
      assert.ok(hz > 20 && hz < 8000 && at >= 0 && dur > 0 && vol > 0 && vol <= 0.5, k + ': ton w zakresie');
      assert.ok(['sine', 'triangle', 'square', 'sawtooth'].includes(typ), k + ': kształt fali');
    }
  }
});

test('KZ_DZWIEKI: „+XP” to iskra poniżej 0,4 s, podsumowanie najwyżej 1,8 s', () => {
  assert.ok(dlugosc(KZ_DZWIEKI.xp) <= 0.4);
  for (const k of ['dzien', 'braki', 'poziom']) assert.ok(dlugosc(KZ_DZWIEKI[k]) <= 1.8, k);
});

test('kzDzwiekDnia: awans albo pokonany boss > czysty dzień > braki', () => {
  assert.equal(kzDzwiekDnia({ czysty: false, poziom_w_gore: true }), 'poziom');
  assert.equal(kzDzwiekDnia({ czysty: true, boss: { pokonany: true } }), 'poziom');
  assert.equal(kzDzwiekDnia({ czysty: true, boss: { pokonany: false } }), 'dzien');
  assert.equal(kzDzwiekDnia({ czysty: false, zaliczony: true }), 'braki');
  assert.equal(kzDzwiekDnia(null), null);
});

test('kzDzwiekiWlaczone: domyślnie tak, wyłącznik w settings.ui.kz_dzwieki', () => {
  assert.equal(kzDzwiekiWlaczone({}), true);
  assert.equal(kzDzwiekiWlaczone({ ui: { off: [] } }), true);
  assert.equal(kzDzwiekiWlaczone({ ui: { kz_dzwieki: false } }), false);
  assert.equal(kzDzwiekiWlaczone(null), true);
});

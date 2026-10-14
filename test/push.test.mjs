import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { VAPID_PUBLIC, keyBytes, subscriptionRow, isIOS, isStandalone, supported, pushTest } from '../push.js';

const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1';
const WIN = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36';
const win = (ua, standalone = false, extra = {}) => ({
  navigator: { userAgent: ua, serviceWorker: {}, standalone, maxTouchPoints: /iPhone/.test(ua) ? 5 : 0 },
  matchMedia: () => ({ matches: standalone }),
  PushManager: function () {}, Notification: function () {}, ...extra,
});

test('klucz VAPID: 65 bajtów, nieskompresowany punkt P-256 (0x04)', () => {
  const k = keyBytes(VAPID_PUBLIC);
  assert.equal(k.length, 65);
  assert.equal(k[0], 4);
});

test('iPhone w Safari (nie z ekranu głównego) = brak obsługi', () => {
  assert.equal(isIOS(win(IPHONE).navigator), true);
  assert.equal(isStandalone(win(IPHONE)), false);
  assert.equal(supported(win(IPHONE)), false);
});

test('iPhone z ekranu głównego i komputer = obsługa', () => {
  assert.equal(supported(win(IPHONE, true)), true);
  assert.equal(supported(win(WIN)), true);
});

test('iPad udający Maca (dotyk) traktowany jak iOS', () => {
  assert.equal(isIOS({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 5 }), true);
  assert.equal(isIOS({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 0 }), false);
});

test('przeglądarka bez PushManager = brak', () => {
  const w = win(WIN); delete w.PushManager;
  assert.equal(supported(w), false);
});

test('wiersz subskrypcji: endpoint i klucze z toJSON, bez user_id (ustawia baza)', () => {
  const sub = { toJSON: () => ({ endpoint: 'https://push.example/abc', keys: { p256dh: 'P', auth: 'A' } }) };
  assert.deepEqual(subscriptionRow(sub, 'UA'), { endpoint: 'https://push.example/abc', p256dh: 'P', auth: 'A', user_agent: 'UA' });
  assert.throws(() => subscriptionRow({ endpoint: 'x', keys: {} }));
});

const sbWith = res => ({ functions: { invoke: async (name, opts) => { assert.equal(name, 'push-wyslij'); assert.deepEqual(opts.body, { test: true }); return res; } } });

test('pushTest: wysłane → true', async () => {
  assert.equal(await pushTest(sbWith({ data: { ok: true, subs: 2, sent: 2 }, error: null })), true);
});

test('pushTest: brak urządzeń / odrzucone / błąd serwera → wyjątek z opisem', async () => {
  await assert.rejects(pushTest(sbWith({ data: { subs: 0, sent: 0 }, error: null })), /Włącz powiadomienia/);
  await assert.rejects(pushTest(sbWith({ data: { subs: 1, sent: 0, errors: ['403 bad jwt'] }, error: null })), /403/);
  await assert.rejects(pushTest(sbWith({ data: null, error: new Error('500') })), /nie odpowiedział/);
});

test('sw.js: zdarzenie push pokazuje powiadomienie z tytułem i treścią, tag praca, requireInteraction', async () => {
  const src = readFileSync(new URL('../sw.js', import.meta.url), 'utf8');
  const handlers = {}, shown = [], posted = [];
  const self = {
    addEventListener: (t, f) => { handlers[t] = f; },
    registration: { scope: 'https://x/dzien/', showNotification: async (t, o) => shown.push([t, o]) },
    clients: { matchAll: async () => [{ postMessage: m => posted.push(m) }] }, skipWaiting() {},
  };
  new Function('self', 'caches', 'location', 'fetch', src)(self, {}, { origin: 'https://x' }, () => {});
  let p;
  handlers.push({ data: { json: () => ({ title: 'Koniec przerwy', body: 'Minęło 15 min – wracasz do GetMed?', tag: 'praca' }) }, waitUntil: x => { p = x; } });
  await p;
  assert.equal(shown.length, 1);
  assert.equal(shown[0][0], 'Koniec przerwy');
  assert.equal(shown[0][1].body, 'Minęło 15 min – wracasz do GetMed?');
  assert.equal(shown[0][1].tag, 'praca');
  assert.equal(shown[0][1].requireInteraction, true);
  assert.equal(posted.length, 1);
  assert.equal(posted[0].type, 'push');
  assert.equal(posted[0].title, 'Koniec przerwy');
  assert.ok(handlers.notificationclick, 'notificationclick zostaje');
  assert.match(src, /const CACHE = 'dzien-v\d+'/);
});

// Prosty cache powłoki apki; dane zawsze z sieci (Supabase).
const CACHE = 'dzien-v29';
const SHELL = ['./', './index.html', './lib.js', './spizarnia.js', './push.js', './vendor/supabase.js', './manifest.webmanifest', './icon-192.png', './icon-512.png', './icon-180.png'];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  // network-first, żeby poprawki docierały od razu; cache tylko offline
  e.respondWith(
    fetch(e.request).then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; })
      .catch(() => caches.match(e.request).then(r => r || caches.match('./index.html')))
  );
});
// Kliknięcie w powiadomienie (przerwa w pracy) – pokaż otwartą apkę albo ją otwórz.
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    const c = cs.find(x => x.url.startsWith(self.registration.scope));
    return c ? c.focus() : self.clients.openWindow('./');
  }));
});
// Powiadomienie z serwera (Web Push: koniec godziny pracy, koniec przerwy) – działa też przy zablokowanym telefonie.
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Dzień', {
    body: d.body || '', tag: d.tag || 'praca', renotify: true, requireInteraction: true,
    icon: './icon-192.png', badge: './icon-192.png', data: { url: d.url || './' },
  }).then(() => self.clients.matchAll({ type: 'window', includeUncontrolled: true }))
    // Otwarta apka dostaje znać (np. żeby odświeżyć stoper zamknięty przez serwer).
    .then(cs => cs.forEach(c => c.postMessage({ type: 'push', title: d.title || '', body: d.body || '', at: Date.now() }))));
});

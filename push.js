// Powiadomienia Web Push (stoper pracy): alarm przychodzi z serwera, więc działa też przy zablokowanym telefonie.
// Serwer: pg_cron co 30 s (praca_tick) → edge function push-wyslij. Klucz prywatny jest tylko w bazie (vault).
// API dla panelu ☰: pushStatus(), pushEnable(sb), pushTest(sb).

// Klucz publiczny VAPID (publiczny z definicji – prywatny para jest w vault, nie w repo).
export const VAPID_PUBLIC = 'BHhWe1JDRUL5S_5jgYt2VzO_JEW_E9QImJHiw67yu3N85KbS_k-xlJwe5NJmpL-lQYikfQw4shsYpa8Jh2pkh1s';

// iPhone/iPad: Web Push tylko w apce dodanej do ekranu głównego (iOS 16.4+).
export function isIOS(nav = globalThis.navigator) {
  const ua = nav?.userAgent || '';
  return /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && (nav?.maxTouchPoints || 0) > 1);
}
export function isStandalone(win = globalThis) {
  return !!(win.navigator?.standalone || win.matchMedia?.('(display-mode: standalone)')?.matches);
}
export function supported(win = globalThis) {
  if (!win.navigator?.serviceWorker || !('PushManager' in win) || !('Notification' in win)) return false;
  if (isIOS(win.navigator) && !isStandalone(win)) return false;
  return true;
}

// base64url → Uint8Array (applicationServerKey).
export function keyBytes(b64) {
  const s = (b64 + '='.repeat((4 - b64.length % 4) % 4)).replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(s);
  return Uint8Array.from(bin, c => c.charCodeAt(0));
}

// Wiersz do push_subscriptions z obiektu PushSubscription (user_id ustawia baza: auth.uid()).
export function subscriptionRow(sub, ua = globalThis.navigator?.userAgent) {
  const j = typeof sub.toJSON === 'function' ? sub.toJSON() : sub;
  if (!j?.endpoint || !j.keys?.p256dh || !j.keys?.auth) throw new Error('Niepełna subskrypcja push');
  return { endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth, user_agent: (ua || '').slice(0, 300) };
}

// 'brak' | 'zablokowane' | 'wylaczone' | 'wlaczone'
export async function pushStatus() {
  if (!supported()) return 'brak';
  if (Notification.permission === 'denied') return 'zablokowane';
  if (Notification.permission !== 'granted') return 'wylaczone';
  try {
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = reg && await reg.pushManager.getSubscription();
    return sub ? 'wlaczone' : 'wylaczone';
  } catch { return 'wylaczone'; }
}

// Wołać z kliknięcia (iOS wymaga gestu). Prosi o zgodę, subskrybuje, zapisuje do bazy. → true/false
export async function pushEnable(sb) {
  if (!supported()) return false;
  // Zgoda jako pierwsze await – żeby iOS widział to jako reakcję na dotknięcie.
  const perm = Notification.permission === 'granted' ? 'granted' : await Notification.requestPermission();
  if (perm !== 'granted') return false;
  try {
    const reg = await navigator.serviceWorker.ready;
    let sub = await reg.pushManager.getSubscription();
    // Subskrypcja z innym kluczem (np. stara) – wymień.
    const cur = sub?.options?.applicationServerKey;
    if (sub && cur && btoaUrl(cur) !== VAPID_PUBLIC) { await sub.unsubscribe(); sub = null; }
    if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(VAPID_PUBLIC) });
    const { error } = await sb.from('push_subscriptions').upsert(subscriptionRow(sub), { onConflict: 'endpoint' });
    if (error) { console.warn('push_subscriptions', error); return false; }
    return true;
  } catch (e) {
    console.warn('pushEnable', e);
    return false;
  }
}

// Próbne powiadomienie przez serwer na wszystkie urządzenia zalogowanego. Sukces → true, błąd → wyjątek z opisem.
export async function pushTest(sb) {
  const { data, error } = await sb.functions.invoke('push-wyslij', { body: { test: true } });
  if (error) throw new Error('Serwer powiadomień nie odpowiedział: ' + (error.message || error));
  if (!data?.subs) throw new Error('Brak włączonych powiadomień na żadnym urządzeniu – najpierw „Włącz powiadomienia”.');
  if (!data.sent) throw new Error('Nie udało się wysłać (' + (data.errors?.[0] || 'urządzenie odrzuciło') + ').');
  return true;
}

function btoaUrl(buf) {
  const s = btoa(String.fromCharCode(...new Uint8Array(buf)));
  return s.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

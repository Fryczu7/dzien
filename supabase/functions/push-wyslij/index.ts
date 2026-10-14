// Edge function „push-wyslij”: wysyła Web Push na wszystkie urządzenia użytkownika.
// Trzy wejścia:
//  1) z bazy (pg_net, praca_tick): nagłówek x-push-secret + { user_id, title, body }
//  2) z apki (pushTest): Authorization: Bearer <JWT użytkownika> + { test: true } – próbne na własne urządzenia
//  3) jednorazowo z bazy: x-push-secret + { init: true } – generuje klucze VAPID i zapisuje do vault
// Sekrety (klucz prywatny VAPID, sekret wywołań) czyta z vault przez RPC push_config (tylko service_role).
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const admin = createClient(URL_, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

let cfg: { secret: string; public: string | null; private: string | null } | null = null;
async function config(fresh = false) {
  if (!cfg || fresh) {
    const { data, error } = await admin.rpc('push_config');
    if (error) throw new Error('push_config: ' + error.message);
    cfg = data;
  }
  return cfg!;
}

// Stały czas porównania sekretu.
function same(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function sendToUser(userId: string, title: string, body: string) {
  const c = await config();
  if (!c.public || !c.private) throw new Error('brak kluczy VAPID');
  webpush.setVapidDetails('https://fryczu7.github.io/dzien/', c.public, c.private);
  const { data: subs, error } = await admin.from('push_subscriptions').select('id, endpoint, p256dh, auth').eq('user_id', userId);
  if (error) throw new Error(error.message);
  const payload = JSON.stringify({ title, body, tag: 'praca', url: './' });
  let sent = 0, removed = 0;
  const errors: string[] = [];
  await Promise.all((subs ?? []).map(async s => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload,
        { TTL: 600, urgency: 'high', topic: 'praca' });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) {
        await admin.from('push_subscriptions').delete().eq('id', s.id);
        removed++;
      } else errors.push(String(code ?? '') + ' ' + String((e as Error).message ?? e).slice(0, 200));
    }
  }));
  return { subs: subs?.length ?? 0, sent, removed, errors };
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'method' }, 405);
  let input: Record<string, unknown> = {};
  try { input = await req.json(); } catch { /* puste ciało */ }

  try {
    const secret = req.headers.get('x-push-secret');
    if (secret) {
      const c = await config();
      if (!same(secret, c.secret)) return json({ error: 'forbidden' }, 403);
      if (input.init) {
        if (c.private) return json({ ok: true, created: false });
        const k = webpush.generateVAPIDKeys();
        const { data, error } = await admin.rpc('push_vapid_save', { pub: k.publicKey, priv: k.privateKey });
        if (error) throw new Error(error.message);
        await config(true);
        return json({ ok: true, created: data });
      }
      if (typeof input.user_id !== 'string') return json({ error: 'user_id' }, 400);
      const r = await sendToUser(input.user_id, String(input.title ?? 'Dzień'), String(input.body ?? ''));
      return json({ ok: true, ...r });
    }

    // Próbne z apki: tylko zalogowany, tylko na własne urządzenia.
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    if (!jwt || !input.test) return json({ error: 'unauthorized' }, 401);
    const { data: u, error } = await admin.auth.getUser(jwt);
    if (error || !u?.user) return json({ error: 'unauthorized' }, 401);
    const r = await sendToUser(u.user.id, 'Próbne powiadomienie', 'Działa – tak przyjdzie alarm stopera.');
    return json({ ok: r.sent > 0, ...r });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});

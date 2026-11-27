// Edge function „gmail-most” – most Gmail ↔ automaty (tor B, 27.11.2026).
// Woła ją co minutę Apps Script w koncie frycz.wideo@gmail.com (zespol/automaty/gmail-most/Kod.gs).
// Uwierzytelnienie bez sekretów: nagłówek Authorization: Bearer <token tożsamości Google>
// (ScriptApp.getIdentityToken). Sprawdzamy podpis Google, e-mail konta i przypięty client id skryptu.
// Wejście (JSON): { maile?: [...], wyniki?: [{id, ok, wynik}], akcje?: true }
// Wyjście: { nowe, wyniki_przyjete, akcje: [{id, typ, dane}] }
import { createClient } from 'npm:@supabase/supabase-js@2';
import { createRemoteJWKSet, jwtVerify } from 'npm:jose@5.9.6';

const KONTO = 'frycz.wideo@gmail.com';
const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});
const JWKS = createRemoteJWKSet(new URL('https://www.googleapis.com/oauth2/v3/certs'));
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });

async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ blad: 'tylko POST' }, 405);

  // 1) Kto woła: tylko token Google konta frycz.wideo, wydany dla przypiętego skryptu.
  const tok = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let aud = '';
  try {
    const { payload } = await jwtVerify(tok, JWKS, { issuer: ['https://accounts.google.com', 'accounts.google.com'] });
    if (payload.email !== KONTO || payload.email_verified !== true) return json({ blad: 'złe konto' }, 403);
    aud = String(payload.aud ?? '');
  } catch (_e) {
    return json({ blad: 'zły token' }, 401);
  }
  if (!(await rpc('gmail_most_aud', { p_aud: aud }))) return json({ blad: 'obcy skrypt' }, 403);

  let body: { maile?: unknown[]; wyniki?: { id: number; ok: boolean; wynik?: unknown }[]; akcje?: boolean };
  try {
    body = await req.json();
  } catch (_e) {
    return json({ blad: 'zły JSON' }, 400);
  }

  try {
    // 2) Najpierw wyniki poprzednich akcji, potem nowe maile, na końcu nowe akcje.
    let przyjete = 0;
    for (const w of body.wyniki ?? []) {
      if (await rpc('gmail_most_wynik', { p_akcja_id: w.id, p_ok: !!w.ok, p_wynik: w.wynik ?? {} })) przyjete++;
    }
    const nowe = await rpc('gmail_most_maile', { p_maile: body.maile ?? [] });
    const akcje = body.akcje ? await rpc('gmail_most_akcje', { p_limit: 10 }) : [];
    return json({ nowe, wyniki_przyjete: przyjete, akcje });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await admin.rpc('gmail_most_blad', { p_blad: msg });
    return json({ blad: msg }, 500);
  }
});

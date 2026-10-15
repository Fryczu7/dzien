#!/usr/bin/env node
// Zrzuty ekranu apki „Dzień” na atrapie bazy – powtarzalne (stała skala 2×, cała strona, aktualny kod).
// Bez zależności: Node 22+ (wbudowany WebSocket) + Edge albo Chrome w trybie headless, sterowane przez
// Chrome DevTools Protocol. Uruchom z katalogu dzien-app:
//   node tools/podglad/zrzuty.mjs
//   node tools/podglad/zrzuty.mjs --sceny dzis,jedzenie --szerokosci 375 --dane moje-dane.json
// Wynik: tools/podglad/zrzuty/<scena>-<szerokość>.png (w .gitignore) + raport w konsoli.
// Kod wyjścia: 0 = ok; 1 = błąd techniczny / atrapa nieaktywna / żądanie do prawdziwej bazy;
//              2 = poziome przewijanie (scrollWidth > szerokość) na którejś scenie.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const TU = path.dirname(fileURLToPath(import.meta.url));
const APKA = path.resolve(TU, '..', '..');

// ---------- argumenty ----------
const arg = (nazwa, dom) => { const i = process.argv.indexOf('--' + nazwa); return i > 0 ? process.argv[i + 1] : dom; };
if (process.argv.includes('--pomoc') || process.argv.includes('-h')) {
  console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1, 9).join('\n').replace(/^\/\/ ?/gm, ''));
  process.exit(0);
}
const SCENY = arg('sceny', 'dzis,jedzenie,zakupy,trening,asystent,coach').split(',').map((s) => s.trim()).filter(Boolean);
const SZEROKOSCI = arg('szerokosci', '375,1440').split(',').map(Number).filter(Boolean);
const WYJSCIE = path.resolve(arg('wyjscie', path.join(TU, 'zrzuty')));
const PLIK_DANYCH = arg('dane', null);
const SKALA = Number(arg('skala', '2'));
const ZEWN_URL = arg('url', null); // np. http://localhost:5173/ – inaczej własny serwer plików

// ---------- przeglądarka ----------
function znajdzPrzegladarke() {
  const kand = [arg('przegladarka', null), process.env.PRZEGLADARKA,
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', 'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/microsoft-edge'].filter(Boolean);
  const p = kand.find((k) => fs.existsSync(k));
  if (!p) throw new Error('Nie znalazłem Edge ani Chrome – podaj --przegladarka <ścieżka>');
  return p;
}

// ---------- serwer plików (bez cache, tylko katalog apki) ----------
const TYPY = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.mp3': 'audio/mpeg' };
function serwer() {
  return new Promise((ok) => {
    const s = http.createServer((req, res) => {
      const p = path.normalize(path.join(APKA, decodeURIComponent(new URL(req.url, 'http://x').pathname)));
      if (!p.startsWith(APKA)) { res.writeHead(403).end(); return; }
      const plik = fs.existsSync(p) && fs.statSync(p).isDirectory() ? path.join(p, 'index.html') : p;
      if (!fs.existsSync(plik)) { res.writeHead(404).end('404'); return; }
      res.writeHead(200, { 'content-type': TYPY[path.extname(plik)] || 'application/octet-stream', 'cache-control': 'no-store' });
      fs.createReadStream(plik).pipe(res);
    });
    s.listen(0, '127.0.0.1', () => ok(s));
  });
}

// ---------- CDP ----------
function polacz(wsUrl) {
  return new Promise((ok, zle) => {
    const ws = new WebSocket(wsUrl);
    let id = 0; const czeka = new Map(); const sluchacze = [];
    ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      if (m.id && czeka.has(m.id)) { const [a, b] = czeka.get(m.id); czeka.delete(m.id); m.error ? b(new Error(m.error.message)) : a(m.result); }
      else if (m.method) sluchacze.forEach((fn) => fn(m));
    };
    ws.onerror = () => zle(new Error('Nie połączyłem się z DevTools'));
    ws.onopen = () => ok({
      wyslij: (method, params = {}, sessionId) => new Promise((a, b) => { const i = ++id; czeka.set(i, [a, b]); ws.send(JSON.stringify({ id: i, method, params, sessionId })); }),
      na: (fn) => sluchacze.push(fn),
      zamknij: () => ws.close(),
    });
  });
}
const czekaj = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const dane = PLIK_DANYCH ? fs.readFileSync(path.resolve(PLIK_DANYCH), 'utf8') : null;
  if (dane) JSON.parse(dane); // walidacja zanim cokolwiek ruszy
  const atrapa = fs.readFileSync(path.join(TU, 'atrapa-bazy.js'), 'utf8');
  const cialoAtrapy = (dane ? `window.__ATRAPA_DANE = ${dane};\n` : '') + atrapa;

  const srv = ZEWN_URL ? null : await serwer();
  const baza = ZEWN_URL || `http://127.0.0.1:${srv.address().port}/`;
  const profil = fs.mkdtempSync(path.join(os.tmpdir(), 'dzien-zrzuty-'));
  const przegl = spawn(znajdzPrzegladarke(), ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profil}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--hide-scrollbars', '--mute-audio', 'about:blank'], { stdio: 'ignore' });

  const sprzataj = () => { try { przegl.kill(); } catch {} srv?.close(); setTimeout(() => { try { fs.rmSync(profil, { recursive: true, force: true }); } catch {} }, 500); };
  try {
    // port DevTools przeglądarka zapisuje w profilu
    let port; for (let i = 0; i < 100 && !port; i++) { await czekaj(100); try { port = fs.readFileSync(path.join(profil, 'DevToolsActivePort'), 'utf8').split('\n')[0]; } catch {} }
    if (!port) throw new Error('Przeglądarka nie wystartowała (brak DevToolsActivePort)');
    const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    const cdp = await polacz(ver.webSocketDebuggerUrl);
    const { targetId } = await cdp.wyslij('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.wyslij('Target.attachToTarget', { targetId, flatten: true });
    const s = (m, p) => cdp.wyslij(m, p, sessionId);

    const doBazy = []; const bledy = [];
    cdp.na((m) => {
      if (m.sessionId !== sessionId) return;
      if (m.method === 'Fetch.requestPaused') {
        const { requestId, request } = m.params;
        if (/\.supabase\.co\b/i.test(request.url)) { doBazy.push(request.url); s('Fetch.failRequest', { requestId, errorReason: 'BlockedByClient' }); }
        else if (/\/vendor\/supabase\.js(\?|$)/.test(request.url)) {
          s('Fetch.fulfillRequest', { requestId, responseCode: 200, responseHeaders: [{ name: 'Content-Type', value: 'text/javascript; charset=utf-8' }, { name: 'Cache-Control', value: 'no-store' }], body: Buffer.from(cialoAtrapy, 'utf8').toString('base64') });
        } else s('Fetch.continueRequest', { requestId });
      }
      if (m.method === 'Runtime.exceptionThrown') bledy.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
      if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') bledy.push(m.params.args.map((a) => a.value ?? a.description ?? '').join(' '));
    });
    await s('Runtime.enable'); await s('Page.enable'); await s('Network.enable');
    await s('Network.setBypassServiceWorker', { bypass: true }); // Service Worker apki nie przeładowuje strony i nie podaje starego kodu
    await s('Network.setCacheDisabled', { cacheDisabled: true });
    await s('Fetch.enable', { patterns: [{ urlPattern: '*supabase.co*' }, { urlPattern: '*/vendor/supabase.js*' }] });
    await s('Emulation.setFocusEmulationEnabled', { enabled: true }); // focus/focusout działają mimo braku okna

    const wyn = []; let porazka = false;
    fs.mkdirSync(WYJSCIE, { recursive: true });
    for (const szer of SZEROKOSCI) {
      const wys = szer < 768 ? 812 : 900;
      await s('Emulation.setDeviceMetricsOverride', { width: szer, height: wys, deviceScaleFactor: SKALA, mobile: szer < 768 });
      await s('Page.navigate', { url: baza });
      // czekamy, aż apka wstanie na atrapie
      let stan;
      for (let i = 0; i < 100; i++) {
        await czekaj(150);
        stan = (await s('Runtime.evaluate', { expression: `({ atrapa: !!window.__atrapa, app: !!document.querySelector('#app') && !document.querySelector('#app').classList.contains('hidden') })`, returnByValue: true })).result.value;
        if (stan?.atrapa && stan?.app) break;
      }
      if (!stan?.atrapa) throw new Error('Atrapa NIEAKTYWNA – przerwane przed jakąkolwiek akcją (apka mogłaby łączyć się z prawdziwą bazą)');
      if (!stan?.app) throw new Error(`Apka nie pokazała #app przy ${szer} px (sprawdź błędy niżej): ${bledy.slice(-3).join(' | ')}`);
      await czekaj(400);

      for (const scena of SCENY) {
        const kl = (await s('Runtime.evaluate', { expression: `(() => { const b = document.querySelector('nav button[data-v="${scena}"]'); if (!b) return false; b.click(); return true; })()`, returnByValue: true })).result.value;
        if (!kl) { wyn.push({ scena, szer, uwaga: 'brak przycisku w nawigacji – pominięta' }); continue; }
        await czekaj(500);
        const m = (await s('Runtime.evaluate', { expression: `({ sw: document.documentElement.scrollWidth, iw: window.innerWidth, h: Math.ceil(document.documentElement.scrollHeight) })`, returnByValue: true })).result.value;
        const { cssContentSize: c } = await s('Page.getLayoutMetrics');
        const shot = await s('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width: szer, height: Math.max(wys, Math.ceil(c.height)), scale: 1 } });
        const plik = path.join(WYJSCIE, `${scena}-${szer}.png`);
        fs.writeFileSync(plik, Buffer.from(shot.data, 'base64'));
        const przewija = m.sw > szer;
        if (przewija) porazka = porazka || 'przewijanie';
        wyn.push({ scena, szer, plik: path.relative(APKA, plik), scrollWidth: m.sw, wysokosc: m.h, przewija });
      }
    }
    const zablokowaneWStronie = (await s('Runtime.evaluate', { expression: 'window.__atrapa ? window.__atrapa.zablokowane.length : -1', returnByValue: true })).result.value;
    cdp.zamknij();

    // ---------- raport ----------
    for (const w of wyn) console.log(w.uwaga ? `  ${w.scena} @${w.szer}: ${w.uwaga}` : `${w.przewija ? '✗' : '✓'} ${w.scena} @${w.szer}px  scrollWidth=${w.scrollWidth}${w.przewija ? ' > ' + w.szer + ' (POZIOME PRZEWIJANIE)' : ''}  → ${w.plik}`);
    if (bledy.length) { console.log(`\nBłędy w konsoli strony (${bledy.length}):`); [...new Set(bledy)].slice(0, 10).forEach((b) => console.log('  - ' + String(b).split('\n')[0])); }
    console.log(`\nŻądania do *.supabase.co: sieć=${doBazy.length}, zablokowane w stronie=${zablokowaneWStronie} (musi być 0)`);
    if (doBazy.length || zablokowaneWStronie > 0) { console.error('BŁĄD: apka próbowała łączyć się z prawdziwą bazą:', doBazy.slice(0, 3)); process.exitCode = 1; }
    else if (porazka) process.exitCode = 2;
  } finally { sprzataj(); }
}

main().catch((e) => { console.error('BŁĄD:', e.message); process.exit(1); });

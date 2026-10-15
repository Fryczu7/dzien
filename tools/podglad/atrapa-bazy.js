// Atrapa klienta Supabase dla apki „Dzień” – do zrzutów ekranu i testów bez prawdziwej bazy.
// Skrypt klasyczny (nie moduł). Ładuj go ZAMIAST vendor/supabase.js, zanim ruszy skrypt apki:
//   - zrzuty.mjs robi to sam (podmienia odpowiedź na vendor/supabase.js),
//   - ręcznie: otwórz tools/podglad/podglad.html (czysta strona, apka nigdy nie łączy się tam z bazą).
// Dane: window.__ATRAPA_DANE = { tabela: [wiersze…], __rpc: { nazwa: wynik | (args, dane) => wynik } }
// ustawione PRZED tym skryptem; bez tego bierze dane przykładowe z dołu pliku (fikcyjne, bez danych prywatnych).
// Po załadowaniu: window.__atrapa = { dane, log, zablokowane, uid } – testy zaczynają od
//   if (!window.__atrapa) throw new Error('atrapa nieaktywna');
// Każde żądanie do *.supabase.co (fetch / XHR / WebSocket) jest blokowane i liczone w __atrapa.zablokowane.
(function () {
  'use strict';
  const UID = 'atrapa-uzytkownik';
  const dzis = (() => { const d = new Date(); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); })();
  const dzienPlus = (n) => { const d = new Date(dzis + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

  // Własne dane zastępują przykładowe tabela po tabeli; wiersz settings jest scalany pole po polu
  // (apka wymaga m.in. morning_items, więc niepełne ustawienia biorą resztę z przykładu).
  const wlasne = window.__ATRAPA_DANE || {};
  const dane = Object.assign(danePrzykladowe(), wlasne);
  if (wlasne.settings) dane.settings = [{ ...danePrzykladowe().settings[0], ...(wlasne.settings[0] || {}) }];
  const rpc = dane.__rpc || {};
  delete dane.__rpc;
  // Każdy wiersz dostaje user_id i id, bo apka filtruje po user_id i usuwa po id.
  let licznik = 0;
  const noweId = () => 'atrapa-' + (++licznik);
  for (const [t, wiersze] of Object.entries(dane)) {
    if (!Array.isArray(wiersze)) continue;
    wiersze.forEach((w) => { if (w.user_id === undefined) w.user_id = UID; if (w.id === undefined && t !== 'settings') w.id = noweId(); });
  }

  const log = [];
  const zablokowane = [];
  window.__atrapa = { dane, log, zablokowane, uid: UID, dzis };

  // ---------- blokada prawdziwej bazy ----------
  const toBaza = (u) => /\.supabase\.co\b/i.test(String(u && (u.url || u)));
  const zablokuj = (rodzaj, u) => { zablokowane.push({ rodzaj, url: String(u && (u.url || u)) }); console.error('[atrapa] zablokowane żądanie do bazy:', rodzaj, String(u && (u.url || u))); };
  const fetchOrg = window.fetch.bind(window);
  window.fetch = (u, o) => { if (toBaza(u)) { zablokuj('fetch', u); return Promise.reject(new TypeError('atrapa: żądanie do bazy zablokowane')); } return fetchOrg(u, o); };
  const xhrOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u, ...r) { if (toBaza(u)) { zablokuj('xhr', u); throw new Error('atrapa: żądanie do bazy zablokowane'); } return xhrOpen.call(this, m, u, ...r); };
  const WsOrg = window.WebSocket;
  window.WebSocket = function (u, p) { if (toBaza(u)) { zablokuj('websocket', u); throw new Error('atrapa: websocket do bazy zablokowany'); } return new WsOrg(u, p); };
  window.WebSocket.prototype = WsOrg.prototype;

  // ---------- zapytania ----------
  const cmp = (a, b) => (a === b ? 0 : a == null ? 1 : b == null ? -1 : a < b ? -1 : 1);
  const kopia = (x) => (x == null ? x : JSON.parse(JSON.stringify(x)));
  const wynik = (data, error = null) => ({ data, error, count: Array.isArray(data) ? data.length : null, status: error ? 400 : 200 });

  function zapytanie(tabela) {
    const st = { op: 'select', filtry: [], kolejnosc: [], limit: null, od: null, single: null, payload: null, opcje: {}, zwroc: false };
    const f = (fn) => { st.filtry.push(fn); return b; };
    const b = {
      select() { if (st.op !== 'select') st.zwroc = true; return b; },
      eq: (k, v) => f((r) => r[k] === v),
      neq: (k, v) => f((r) => r[k] !== v),
      gt: (k, v) => f((r) => r[k] != null && r[k] > v),
      gte: (k, v) => f((r) => r[k] != null && r[k] >= v),
      lt: (k, v) => f((r) => r[k] != null && r[k] < v),
      lte: (k, v) => f((r) => r[k] != null && r[k] <= v),
      in: (k, lista) => f((r) => (lista || []).includes(r[k])),
      is: (k, v) => f((r) => (v === null ? r[k] == null : r[k] === v)),
      like: (k, w) => f((r) => new RegExp('^' + String(w).replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/%/g, '.*') + '$').test(r[k] ?? '')),
      ilike: (k, w) => f((r) => new RegExp('^' + String(w).replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/%/g, '.*') + '$', 'i').test(r[k] ?? '')),
      contains: (k, v) => f((r) => (Array.isArray(v) ? v.every((x) => (r[k] || []).includes(x)) : Object.entries(v || {}).every(([a, c]) => (r[k] || {})[a] === c))),
      match: (obj) => f((r) => Object.entries(obj).every(([k, v]) => r[k] === v)),
      not(k, op, v) {
        const t = { eq: (r) => r[k] === v, is: (r) => (v === null ? r[k] == null : r[k] === v), in: (r) => String(v).replace(/[()]/g, '').split(',').includes(String(r[k])) }[op] || (() => false);
        return f((r) => !t(r));
      },
      filter(k, op, v) { return (b[op] || (() => b))(k, v); },
      or() { console.warn('[atrapa] .or() nieobsługiwane – filtr pominięty'); return b; },
      order(k, o = {}) { st.kolejnosc.push([k, o.ascending !== false]); return b; },
      limit(n) { st.limit = n; return b; },
      range(a, z) { st.od = a; st.limit = z - a + 1; return b; },
      single() { st.single = 'single'; return b; },
      maybeSingle() { st.single = 'maybe'; return b; },
      insert(p, o) { st.op = 'insert'; st.payload = p; st.opcje = o || {}; return b; },
      upsert(p, o) { st.op = 'upsert'; st.payload = p; st.opcje = o || {}; return b; },
      update(p) { st.op = 'update'; st.payload = p; return b; },
      delete() { st.op = 'delete'; return b; },
      then(ok, err) { return Promise.resolve().then(wykonaj).then(ok, err); },
      catch(err) { return b.then(undefined, err); },
    };
    function wykonaj() {
      const rows = (dane[tabela] = dane[tabela] || []);
      const pasuje = (r) => st.filtry.every((fn) => fn(r));
      log.push({ tabela, op: st.op, payload: kopia(st.payload), czas: new Date().toISOString() });
      let out;
      if (st.op === 'select') {
        out = rows.filter(pasuje);
        for (const [k, rosn] of [...st.kolejnosc].reverse()) out = [...out].sort((a, c) => (rosn ? 1 : -1) * cmp(a[k], c[k]));
        if (st.od != null) out = out.slice(st.od);
        if (st.limit != null) out = out.slice(0, st.limit);
      } else if (st.op === 'insert' || st.op === 'upsert') {
        const lista = Array.isArray(st.payload) ? st.payload : [st.payload];
        const klucze = String(st.opcje.onConflict || 'id').split(',').map((s) => s.trim());
        out = lista.map((p) => {
          const w = { user_id: UID, created_at: new Date().toISOString(), ...p };
          const ist = st.op === 'upsert' && rows.find((r) => klucze.every((k) => w[k] !== undefined && r[k] === w[k]));
          if (ist) { Object.assign(ist, p); return ist; }
          if (w.id === undefined && tabela !== 'settings') w.id = noweId();
          rows.push(w); return w;
        });
      } else if (st.op === 'update') {
        out = rows.filter(pasuje); out.forEach((r) => Object.assign(r, st.payload));
      } else if (st.op === 'delete') {
        out = rows.filter(pasuje); dane[tabela] = rows.filter((r) => !pasuje(r));
      }
      if (st.op !== 'select' && !st.zwroc && !st.single) return wynik(null);
      if (st.single) {
        if (out.length === 1 || (st.single === 'maybe' && out.length <= 1)) return wynik(kopia(out[0] ?? null));
        return wynik(null, { message: 'atrapa: oczekiwano jednego wiersza, jest ' + out.length, code: 'PGRST116' });
      }
      return wynik(kopia(out));
    }
    return b;
  }

  const sesja = { user: { id: UID, email: 'atrapa@przyklad.test' }, access_token: 'atrapa' };
  const klient = {
    from: zapytanie,
    rpc(nazwa, args) {
      log.push({ rpc: nazwa, args: kopia(args), czas: new Date().toISOString() });
      const r = rpc[nazwa];
      return Promise.resolve(wynik(typeof r === 'function' ? r(args, dane) : r === undefined ? null : kopia(r)));
    },
    functions: { invoke: async (nazwa, o) => { log.push({ funkcja: nazwa, body: kopia(o && o.body) }); return wynik(null); } },
    channel: () => { const k = { on: () => k, subscribe: () => k, unsubscribe: async () => 'ok' }; return k; },
    removeChannel: async () => 'ok',
    auth: {
      getSession: async () => ({ data: { session: sesja }, error: null }),
      getUser: async () => ({ data: { user: sesja.user }, error: null }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signInWithPassword: async () => ({ data: { session: sesja }, error: null }),
      signUp: async () => ({ data: {}, error: null }),
      signOut: async () => ({ error: null }),
      resetPasswordForEmail: async () => ({ data: {}, error: null }),
      updateUser: async () => ({ data: { user: sesja.user }, error: null }),
    },
  };
  window.supabase = { createClient: () => klient };

  // ---------- dane przykładowe (fikcyjne; nie wpisuj tu prawdziwych danych – repo jest publiczne) ----------
  function danePrzykladowe() {
    return {
      settings: [{ onboarded: true, kcal_target: 2500, protein_target: 130,
        morning_items: [['lozko', 'Łóżko pościelone'], ['woda', 'Szklanka wody'], ['spacer', 'Krótki spacer']],
        evening_items: [['ekran', 'Bez ekranu po 23:00'], ['spac', 'Spać przed 0:00']],
        quick_meals: [['Owsianka z owocami', 550, 20], ['Kanapki (3 kromki)', 500, 22], ['Kurczak z ryżem', 700, 50], ['Jogurt naturalny', 150, 8]],
        weight_start: 70, weight_mid: 72, weight_goal: 75, claude_url: 'https://claude.ai/' }],
      rules: [1, 2, 3].map((nr) => ({ nr, text: 'Przykładowa zasada ' + nr, why: 'Przykładowy powód ' + nr })),
      days: [
        { date: dzienPlus(-1), bed: '23:30', wake: '07:30', sleep_h: 8, plan: [{ text: 'Zadanie z wczoraj', done: true }], morning: { lozko: true }, evening: {}, rules_broken: [] },
        { date: dzis, bed: '23:50', wake: '07:40', sleep_h: 7.8, plan: [{ text: 'Przykładowe zadanie 1', done: false }, { text: 'Przykładowe zadanie 2', done: true }], morning: { lozko: true, woda: true }, evening: {}, rules_broken: [], coach_morning: null, coach_evening: null },
      ],
      meals: [
        { date: dzis, time: '08:30', name: 'Owsianka z owocami', kcal: 550, protein: 20 },
        { date: dzis, time: '13:15', name: 'Kurczak z ryżem', kcal: 700, protein: 50 },
        { date: dzienPlus(-1), time: '19:00', name: 'Makaron z sosem', kcal: 650, protein: 25 },
      ],
      items: [
        { kind: 'zakupy', name: 'Przykładowa rzecz', done: false },
        { kind: 'spizarnia', name: 'Mleko', done: false },
      ],
      products: [{ name: 'Mleko', start_days: 4, usual_qty: '2 l' }, { name: 'Chleb', start_days: 3, usual_qty: '1 szt.' }],
      purchases: [],
      coach: [{ date: dzis, kind: 'noc', morning: '1. Przykładowa propozycja | Przykładowe uzasadnienie', report: 'Przykładowy raport', work: [] }],
      goals: [{ id: 'C1', title: 'Przykładowy cel', metric: 'sztuki', deadline: dzienPlus(60), where_now: '3', next_step: 'Następny krok' }],
      weights: [{ date: dzienPlus(-14), kg: 70.5 }, { date: dzienPlus(-7), kg: 71 }],
      workouts: [], workout_sets: [], workout_plans: [], catchups: [], notes: [], menu: [], propozycje: [],
      praca: [], przerwy: [], przeglad: [], kuznia_dni: [], modlitwy: [], dzwieki: [],
    };
  }
})();

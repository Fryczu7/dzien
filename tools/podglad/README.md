# Podgląd apki na atrapie bazy

Narzędzia do oglądania i testowania apki „Dzień” **bez prawdziwej bazy** (Supabase). Żadne dane nie wychodzą do `*.supabase.co` – każde takie żądanie jest blokowane i liczone.

| Plik | Do czego |
|---|---|
| `atrapa-bazy.js` | Atrapa klienta Supabase (`window.supabase.createClient`). Tabele w pamięci, filtry `eq/neq/gt/gte/lt/lte/in/is/not/match/like`, `order`, `limit`, `range`, `single/maybeSingle`, `insert/upsert/update/delete`, `rpc`, `auth`. Blokuje fetch/XHR/WebSocket do bazy. |
| `zrzuty.mjs` | Zrzuty ekranu każdej zakładki w 375 i 1440 px, skala 2×, cała strona; sprawdza poziome przewijanie. |
| `podglad.html` | Ręczny podgląd w przeglądarce (np. panel przeglądarki Claude). |

## Zrzuty ekranu (główny sposób)

Z katalogu `dzien-app`:

```
node tools/podglad/zrzuty.mjs
```

Potrzebne: Node 22+ i Edge albo Chrome (szuka sam; inaczej `--przegladarka <ścieżka>`). Skrypt sam stawia serwer plików, nie trzeba nic instalować.

Wynik: `tools/podglad/zrzuty/<zakładka>-<szerokość>.png` (folder w `.gitignore`) i raport w konsoli:

```
✓ dzis @375px  scrollWidth=375  → tools\podglad\zrzuty\dzis-375.png
…
Żądania do *.supabase.co: sieć=0, zablokowane w stronie=0 (musi być 0)
```

Kod wyjścia: `0` ok · `1` błąd, atrapa nieaktywna albo próba połączenia z bazą · `2` poziome przewijanie na którejś scenie.

Opcje:

- `--sceny dzis,jedzenie` – które zakładki (`data-v` z paska nawigacji). Domyślnie wszystkie sześć.
- `--szerokosci 375,768,1440` – szerokości w px. Domyślnie 375 i 1440.
- `--dane plik.json` – własne dane zamiast przykładowych (format niżej).
- `--wyjscie <folder>`, `--skala 2`, `--url http://localhost:5173/` (zamiast własnego serwera).

Jak to działa: przeglądarka headless sterowana przez Chrome DevTools Protocol. Odpowiedź na `vendor/supabase.js` jest podmieniana na atrapę, więc apka od pierwszej linii działa na atrapie (bez `document.write` na stronie, na której ruszył prawdziwy klient). Service Worker jest pomijany, fokus emulowany (`focusout` działa w tle), rozmiar ustawiany przez `setDeviceMetricsOverride` – `--window-size` w trybie headless renderuje szerzej niż podano.

Uwaga: na zrzucie pełnej strony w 375 px dolny pasek nawigacji (przyklejony do dołu ekranu) wypada w połowie obrazu – to skutek zrzutu całej wysokości, nie błąd układu.

## Ręczny podgląd

Uruchom podgląd „dzien” z `.claude/launch.json` projektu CEO i otwórz:

```
http://localhost:5173/tools/podglad/podglad.html
```

To czysta strona: najpierw ładuje atrapę, sprawdza ją, a dopiero potem kod apki (bez prawdziwego klienta i bez Service Workera). Nie wstrzykuj atrapy na stronie `/`, na której apka już połączyła się z bazą – jej timery dalej wołałyby prawdziwą bazę.

Przed pierwszym kliknięciem czegoś, co zapisuje:

```js
if (!window.__atrapa) throw new Error('atrapa nieaktywna');
```

Po teście: `read_network_requests` z filtrem `supabase.co` musi dać 0 żądań (oraz `window.__atrapa.zablokowane.length === 0`).

## Dane

Bez `--dane` atrapa bierze fikcyjne dane przykładowe z dołu `atrapa-bazy.js` (dzisiejsza data liczona na bieżąco). Własne dane – JSON z tabelami jako tablicami wierszy, opcjonalnie wyniki funkcji w `__rpc`:

```json
{
  "settings": [{ "onboarded": true, "kcal_target": 2500, "protein_target": 130 }],
  "meals": [{ "date": "2026-10-15", "time": "16:00", "name": "Obiad", "kcal": 800, "protein": 40 }],
  "__rpc": { "kuznia_stan_teraz": null }
}
```

Podane tabele zastępują przykładowe, pozostałe zostają z przykładu; wiersz `settings` jest scalany pole po polu (apka bez np. `morning_items` się wywraca). `user_id` i `id` atrapa dopisuje sama. W przeglądarce te same dane można podać jako `window.__ATRAPA_DANE = {…}` przed załadowaniem `atrapa-bazy.js`.

Podgląd stanu w trakcie: `window.__atrapa.dane` (tabele), `window.__atrapa.log` (każde zapytanie i zapis), `window.__atrapa.zablokowane`.

**Repo jest publiczne (GitHub Pages).** Prawdziwe dane (waga, leki, sen, zasady, nazwiska) trzymaj w pliku poza repo albo w `tools/podglad/dane-*.json` – ten wzór jest w `.gitignore`.

# Reaudit po d2a5944 — zakres i dowody

Punkt odniesienia: `d2a5944508301ac41ca3fad7415a3547081bdbac`.
Przed zmianami wykonano fetch: lokalny HEAD i origin/develop były zgodne.
Jedynymi zastanymi nieśledzonymi plikami były `.codemap/` i `.opencode/`;
pozostawiono je poza commitami. Poprzedni raport: [AUDIT-FIXES.md](AUDIT-FIXES.md).

## Potwierdzone problemy i semantyka po poprawce

1. **keep_last traciło własność pauzowanego timera.** Nowe testy przed poprawką:
   7 porażek na 9 scenariuszy, m.in. `aux_timer_in_use` po odzyskaniu telemetrii.
   Teraz podczas zaniku telemetrii pauzujemy własny slot raz, zachowując własność,
   sygnaturę i journal. Odzyskanie MPS synchronizuje lub wznawia ten sam slot;
   zgodna pauza nie wymaga ponownego start/pause. Polityka `stop` nadal zatrzymuje
   i zwalnia slot. Normalne zamknięcie zatrzymuje własny timer także po keep_last,
   a dopiero sukces usuwa journal. Restart/zmiana konfiguracji korzystają z tego
   cleanupu starej instancji. Nieudany stop pozostawia journal. SIGKILL nie wykonuje
   cleanupu: nowa instancja nadal blokuje nieustaloną własność i wymaga operatora.
   To samo dotyczy zmiany slotu, URL albo wyłączenia mediów po awarii.
2. **Rozłączenie OBS pozostawiało oczekujące przejścia przerw.** Callback przejścia
   ze stanu connected do dowolnego niepołączonego odrzuca teraz tylko pending.
   Nie zeruje current ani generacji aktywnego HTTP, nie anuluje go i nie zakłada
   cofnięcia akcji Ontime. Spóźniona odpowiedź może zakończyć bieżące żądanie,
   lecz nie uruchomi odrzuconej historii. Po reconnect istniejąca maszyna OBS
   pobiera nowy baseline; dopiero nowe przejścia trafiają do kolejki. Jeżeli nowy
   poprawny transition wystąpi przed zakończeniem starego HTTP, czeka w zwykłej
   kolejności. Reset całej kolejki przy zmianie konfiguracji pozostaje bez zmian.
3. **Release pomijał regresje Swift.** `test.sh` zawiera wszystkie wcześniejsze
   polecenia testów Python i 15 zestawów Swift, w tym UI, Media Bridge, OBS,
   migrację i automatyzację. Oba workflow uruchamiają go przed buildem. `set -euo
   pipefail` blokuje dalsze kroki po błędzie; testy wykonania sprawdzają przerwanie
   po awarii Python i Swift. Zachowano limit 120 s testu lifecycle oraz dodano
   limit 15 min kroku pełnego zestawu. Ścieżki triggerów release, uprawnienia,
   publikowanie DMG/ZIP i warunki artefaktów develop pozostają bez zmian.
4. **Develop nie identyfikował źródłowego commita w aplikacji.** Domyślna wersja
   pochodzi teraz z `.github/RELEASE_VERSION` (nadal `v0.2.0`). CI przekazuje pełny
   testowany SHA do builda develop; lokalny domyślny build na develop odczytuje HEAD.
   `CFBundleShortVersionString` zawiera wyłącznie numeryczny rdzeń semver,
   `CFBundleVersion` pozostaje poprawnym `1`. Pełny SHA zapisuje `VENDevelopCommit`;
   etykieta `CFBundleGetInfoString`, menu oraz startup log wskazują develop i SHA.
   `VERSION=1.2.3` nadal ustawia wersję produkcyjną; prerelease trafia do etykiety,
   zachowując numeryczny rdzeń w polu Apple. Bundle ID i podpisywanie bez zmian.

Formaty wersji sprawdzono w dokumentacji Apple:
[CFBundleShortVersionString](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring),
[CFBundleVersion](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion).

## Ustalenia niewymagające zmiany

- README już jednoznacznie opisuje POST + Bearer + localhost oraz to, że token GUI
  jest losowy przy każdym uruchomieniu i nie zapewnia stałego dostępu Companion.
  Nie zmieniono tokenów ani endpointów. GET nie został przywrócony.
- Maszyna połączenia OBS już resetuje baseline po reconnect. Nie zmieniano jej;
  nowe testy kolejki używają jej rzeczywistej implementacji.
- Pozostałe zgłoszone problemy zostały potwierdzone, żaden nie był już naprawiony.

## Zmienione pliki i testy

| Plik | Powód |
| --- | --- |
| `services/media_bridge.py` | Własność keep_last, cleanup na close, brak zbędnej pauzy zgodnego runtime. |
| `tests/test_keep_last.py` | 9 regresji: utrata/wznowienie, stop, close/restart, failed stop, crash z journalem, zmiana konfiguracji, obcy timer. |
| `app/Sources/AutomationRequestSequence.swift` | Odrzucanie wyłącznie pending. |
| `app/Sources/ApplicationMain.swift` | Podłączenie discard do utraty OBS oraz etykieta/log buildu. |
| `app/Tests/AutomationRequestSequenceTests.swift` | Deterministyczna kolejka, late completion, reconnect i nowy baseline. |
| `test.sh` | Wspólna bramka wszystkich testów, osobny katalog tymczasowy, cleanup i limity. |
| `.github/workflows/test.yml` | Użycie wspólnej bramki, SHA dla develop, zachowane artefakty. |
| `.github/workflows/release.yml` | Ta sama pełna bramka przed buildem/publikacją. |
| `build_app.sh` | Poprawne numery Apple i osobna identyfikacja SHA. |
| `tests/test_build_pipeline.py` | 6 kontroli: semver/SHA/plist, błędne metadane, pełne pokrycie zestawów Swift, wspólny gate, fail-fast Python/Swift. |
| `README.md`, `MEDIA-BRIDGE.md`, `AUDIT-FOLLOWUP.md` | Wyłącznie zmienione zachowanie, uruchamianie testów i ten raport. |

## Weryfikacja lokalna i jej granice

- Wszystkie **95 testów Python: OK**, 14.924 s, z atrapami HTTP na loopback.
- Nowe keep_last: przed poprawką 7/9 porażek; po poprawce 9/9 OK.
- Pipeline/metadata: przed poprawką 5/5 nie przechodziło; po dodaniu obu testów
  fail-fast 6/6 OK. Stuby kompilatora służą wyłącznie do testu skryptu/plist,
  **nie są dowodem kompilacji macOS**.
- `python3 -m py_compile services/*.py tests/*.py`, `bash -n test.sh build_app.sh`,
  parsowanie YAML i `git diff --check`: OK.
- Zweryfikowano triggery push/pull_request w Tests, niezmienione triggery release
  i obowiązkową kolejność gate → build → publish bez continue-on-error.
- Nowe przypadki Swift zapisano przed poprawką; lokalnie nie można wykonać ich
  na czerwono ani zielono: Linux bez swiftc/xcrun. `./build_app.sh` uruchomiono
  rzeczywiście i zakończył się błędem braku xcrun. Dowód Swift/AppKit/build: CI niżej.
- Nie wywoływano release ani nie tworzono PR/tagów do sprawdzania triggerów.
  Kontrola release jest strukturalna oraz przez wykonanie tego samego test.sh
  w CI develop; nie jest próbą rzeczywistej publikacji.

## Commity implementacji

- `693cca8` — keep_last i własność/journal, testy i opis shutdownu.
- `5d168ef` — pending kolejki po rozłączeniu OBS i testy reconnect.
- `f267174` — wspólna bramka CI/release, metadane buildu, testy i README.

## Pozostałe ryzyka i testy ręczne

Nie wykonano testów prawdziwej instalacji OBS/MPS/Ontime. Na testowym rundownie:

1. Włącz keep_last, rozpocznij odtwarzanie i odłącz OBS. Oczekuj pauzy wybranego
   slotu, potem reconnect/resume bez aux_timer_in_use. Powtórz dla MPS paused.
2. Powtórz ze stop: zatrzymanie i zwolnienie własności. Po keep_last zamknij
   normalnie/restartuj helper lub zmień konfigurację: stary własny slot ma zostać
   zatrzymany. Oddzielnie wykonaj SIGKILL: journal i operator-assisted recovery
   mają pozostać; obcy aktywny slot nie może być przejmowany ani zatrzymywany.
3. Podczas opóźnionego HTTP wyślij enter/leave i rozłącz OBS: oczekujący leave
   ma zostać odrzucony. Reconnect sam nie przełącza rundownu; nowe przejścia działają.
4. Sprawdź SHA w menu/logu/metadanych otrzymanej paczki. Pełny SHA ma odpowiadać
   GitHub Actions, a wersja produkcyjna i Bundle ID nie mogą się zmienić.
5. Powtórz testy automatyzacji, HTTP auth, mediów i eksportów osobno w Dry Run
   oraz live na testowym rundownie; nigdy podczas produkcyjnej realizacji.

Ontime 4.14 nadal nie oferuje wyłącznego owner/CAS. Slot musi być zarezerwowany
wyłącznie dla VOS. Akcja HTTP już przyjęta przez serwer nie daje się cofnąć przez
lokalne anulowanie. Uszkodzony journal lub nieudany cleanup wymaga operatora.
Lokalne niezacommitowane zmiany nie są identyfikowane przez SHA HEAD; do audytu
konkretnego buildu używaj artefaktu CI. Bez merge, tagów i publikacji release.

## Potwierdzone CI macOS implementacji

[Tests — run 43838650013](https://github.com/Vencite/ven-obs-utils/actions/runs/43838650013)
dla `f26717455124763c81564456684b5b82fbe7e000`: **SUCCESS**, jedyny job `tests`
przeszedł w 2m41s. Sprawdzono wszystkie jego kroki oraz pełny log:

- 95 testów Python: OK w 50.383 s na runnerze macOS.
- Wszystkie 15 zestawów Swift: PASS, w tym nowe kolejka/reconnect,
  MediaBridgeController, MPSState, UI/AppKit, konfiguracja/migracja i OBS WebSocket.
- Pełny build macOS, ad-hoc codesign, pakowanie i upload ZIP: OK.
- [Artefakt implementacji](https://github.com/Vencite/ven-obs-utils/actions/runs/43838650013/artifacts/14212650767)
  został pobrany. CRC ZIP, obecność executable oraz Info.plist: OK.
  Pełny VENDevelopCommit = `f26717455124763c81564456684b5b82fbe7e000`,
  CFBundleShortVersionString = `0.2.0`, CFBundleVersion = `1`,
  CFBundleGetInfoString = `0.2.0 (develop f26717455124)`, Bundle ID bez zmian.
- Ostrzeżenia AppKit o izolacji aktora/deprecacji oraz adnotacje wersji Node
  używanych actions nie blokują CI; dotyczą zachowanych fragmentów poza zakresem.

Raport i końcowy test oczekiwanej wersji odczytujący RELEASE_VERSION zamiast
utrwalać 0.2.0 są wysyłane osobnym commitem. Dzięki temu przyszła zmiana wersji
produkcyjnej nie wymaga aktualizowania stałej w teście. Wynik CI jego HEAD oraz
odpowiadający artefakt należy sprawdzić w
[workflow Tests na develop](https://github.com/Vencite/ven-obs-utils/actions/workflows/test.yml?query=branch%3Adevelop).
Bieżące zadanie obejmuje oczekiwanie także na ten wynik; końcowy link i HEAD
są przekazane w raporcie użytkownikowi. Wszystkie kontrole na prawdziwym
OBS/MPS/Ontime pozostają ręczne i niepotwierdzone.

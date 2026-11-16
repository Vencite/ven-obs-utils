# Wynik weryfikacji audytu 98bc30e → da3e051

Prace wykonano na `develop`, zaczynając od `90c901a` (dodatkowy commit
porządkował dokumentację). Zastane nieśledzone `.codemap/` i `.opencode/`
pozostawiono poza zmianą. Nie zmieniono wersji ani architektury aplikacji.

## Ustalenia i poprawki

| Ustalenie | Wynik |
| --- | --- |
| Pauza bez Vendor Events powoduje stale po 6 s | Przyczyna niepotwierdzona: kontroler już powtarzał snapshot w pauzie co 2 s. Potwierdzono brak niezależnego sprawdzania OBS i odświeżanie ważności historycznych danych. |
| Heartbeat MPS | Osobny autoryzowany heartbeat IPC; monotoniczny zegar; GetPlaylistState po ciszy także w paused/stopped/unknown, bez zerowania snapshotu przy każdym probe. Brak ponownych zapisów niezmienionych eksportów. |
| Restart helpera gubi własność | Potwierdzone. Trwały atomowy rejestr przed pierwszą mutacją, weryfikacja starego slotu także po wyłączeniu mediów lub zmianie konfiguracji. Niejednoznaczny aktywny timer blokuje mutacje i pokazuje recovery. |
| Przejmowanie cudzego timera | Dodatkowo odtworzone testem: aktywny nieposiadany slot był zatrzymywany i nadpisywany. Teraz pozostaje nietknięty. |
| Niespójność walidacji | Potwierdzona. Wyłączone media ignorują wyłącznie nieużywane ustawienia zagnieżdżone, zachowując je na dysku. Aktywne pola, typy, tryb źródła i numer slotu są sprawdzane w obu językach. Migracja v2→v3 pozostaje. |
| Historyczny sukces UI | Potwierdzony. Utrata helpera zastępuje status wyjścia przez unavailable/disabled. Spóźnione odpowiedzi sprzed zmiany konfiguracji lub nowszego zapytania są ignorowane. Brak danych media w odpowiedzi również unieważnia stary sukces. |
| Utrata Ontime podczas pauzy | Status przestaje przedstawiać historyczny sukces; heartbeat ponawia nieudane wyjście, w tym wiadomość i wybór źródła secondary. |
| GET bez autoryzacji | Potwierdzone dla wszystkich trzech endpointów przerw. Teraz POST, Bearer z istniejącego sekretu IPC i loopback; alias /break pozostaje. Migracja klientów opisana w README. |
| Publiczne sterowanie mediami | Już usunięte wcześniej. Nie przywracano go ani nie zmieniano tej decyzji. Repozytorium nie zawiera konfiguracji zewnętrznego Companion; nie można potwierdzić braku takich klientów u użytkownika. |
| Wyścigi async | Dodano generację sesji IPC, odrzucanie spóźnionej starej sesji i testy zmiany źródła/rozłączenia podczas probe. Anulowane przejęcie nie oznacza już własności i nie wysyła późniejszego nieuzasadnionego stop. Zmiana konfiguracji zeruje istniejącą kolejkę przerw i unieważnia stare odpowiedzi, aby nie przenosić przejść Program do nowego targetu. |

Nie modyfikowano `OBSWebSocketClient.swift` ani `ServiceController.swift`:
istniejące timeouty, unieważnianie żądań przy rozłączeniu i oczekiwanie na
zakończenie starego procesu pozostają. Nowe zabezpieczenia działają na granicy
kontrolera mediów oraz helpera. Trwającego żądania zaakceptowanego przez Ontime
nie można cofnąć; kolejne mutacje sprawdzają aktualność generacji.

## Polityka recovery i jej ograniczenie

Zapis slotu nie jest dowodem wyłącznej własności. W
[API Ontime v4.14.0](https://github.com/cpvalente/ontime/blob/v4.14.0/apps/server/src/api-integration/integration.controller.ts)
nie ma tokenu właściciela ani warunkowej mutacji timera. Z tego powodu aktywny
orphan po SIGKILL **nie jest automatycznie zatrzymywany**. Wymaga sprawdzenia i
jawnej decyzji operatora w Ontime; helper wykrywa stop, usuwa rejestr i wraca do
synchronizacji. To celowa bezpieczna polityka dla nieustalonej własności,
a nie gwarancja bezobsługowego usuwania aktywnego timera po awarii.

Zarezerwowany slot musi należeć wyłącznie do VOS. Ontime nie potrafi atomowo
zablokować przejęcia przez innego klienta między poll i komendą. Zmiana URL,
uszkodzony rejestr albo niedostępny stary target pozostają widocznym błędem do
rozstrzygnięcia przez operatora. Nie zatrzymujemy innych slotów ani rundownu.

## Zmienione pliki

| Pliki | Uzasadnienie |
| --- | --- |
| app/Sources/MediaBridgeController.swift | Probe OBS, oddzielny heartbeat, zegar i sesje. |
| app/Sources/AppConfig.swift | Spójna walidacja mediów i wymóg loopback. |
| app/Sources/ApplicationMain.swift | Autoryzowany POST, unieważnianie i kolejność statusów. |
| app/Sources/StatusPresentation.swift | Zwięzłe statusy unavailable/connected/recovery i błędy. |
| services/media_bridge.py | Heartbeat, journal/recovery, odmowa przejęcia, retry i anulowanie. |
| services/ontime_break_sync.py | Transport heartbeat, generacja sesji, autoryzacja i loopback. |
| app/Tests/MediaBridgeControllerTests.swift | Nowy test kontrolera z fałszywym OBS/IPC i kontrolowanym zegarem. |
| app/Tests/AppConfigMigrationTests.swift | Aktywne/wyłączone błędne media i domyślne brakujące pola. |
| app/Tests/StatusPresentationTests.swift | Utrata/odzyskanie stanu wyjścia. |
| tests/test_audit_regressions.py | Deterministyczna pauza 300 s, resume, journal/crash/recovery, obcy timer, błędy i sesje. |
| tests/test_media_http.py | Autoryzacja, metody i spóźniona sesja. |
| tests/test_media_bridge.py | Aktywna walidacja i zaostrzenie asercji braku nieuprawnionego stop. |
| tests/test_action_serialization.py, tests/test_leave_break_sync.py, tests/test_ontime_break_sync.py | Dotychczasowe scenariusze przerw korzystają z POST+Bearer; asercje funkcjonalne zachowane. |
| .github/workflows/test.yml | Dodatkowy zestaw Swift, pozostałe testy i build zachowane. |
| README.md, MEDIA-BRIDGE.md, AUDIT-FIXES.md | Zmienione zachowanie, migracja, recovery i ten raport. |

Lokalny ignorowany `LOCAL-TESTING.md` zawiera wyniki oraz otwarte testy ręczne.

## Weryfikacja

- Przed zmianami: wszystkie 64 testy Python przeszły poza sandboxem.
- Po zmianach: wszystkie 80 testów Python przeszły (15.176 s).
- Python py_compile, bash -n build_app.sh, parsowanie YAML workflow oraz
  git diff --check: OK.
- Swift/AppKit i nowy test kontrolera: dodane do CI, **nieuruchomione lokalnie**.
- `./build_app.sh`: uruchomiony, błąd braku xcrun; środowisko Linux bez Swift.
- Nie wykonano pushu, więc nie ma wyniku Actions dla nowych commitów.
- Nie wykonywano realnych akcji na OBS/Ontime. Restart/crash w testach backendu
  odtwarza nowe instancje nad zachowanym fake runtime i journalem; nie jest to
  fizyczny test SIGKILL instalacji użytkownika.

Pełna instrukcja ręczna: [MEDIA-BRIDGE.md](MEDIA-BRIDGE.md#pause-heartbeat-and-helper-recovery).
Obejmuje długą pauzę/resume, OBS/helper/Ontime reconnect, zmianę źródła,
normalny restart i SIGKILL, obcy timer, sloty 1/2/3, secondary, TXT/JSON,
Program/Preview oraz osobne próby Dry Run i live na testowym rundownie.
Migracja Companion/HTTP: [README.md](README.md#manual-http-triggers).

Testy macOS i ręczna akceptacja pozostają wymagane przed użyciem produkcyjnym.
Nie tworzono release, tagów ani merge do main.

Commit implementacji i regresji: `512a0c2`.

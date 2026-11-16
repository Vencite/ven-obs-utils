# Multi Auxiliary Timers — zakres do niezależnego audytu

Punkty odniesienia:
- VEN: `3eb61fa923ce2952628a7f6dbfaba99c6b8de61a`, develop.
- MPS: `c1db64bf5cbcc4f9a60ea67e881821d96fca08fb`, develop, **bez zmian**.

Oba HEAD-y i working trees sprawdzono przed pracą. VEN miał tylko zastane
nieśledzone `.codemap/` i `.opencode/`, pozostawione poza commitami; MPS był czysty.
Przeczytano AUDIT-FIXES.md, AUDIT-FOLLOWUP.md i MEDIA-BRIDGE.md.

## Kontrakt MPS: potwierdzony kodem, bez ponownego obliczania czasu w VEN

W [schema v1](https://github.com/Vencite/media-playlist-source/blob/c1db64bf5cbcc4f9a60ea67e881821d96fca08fb/docs/playlist-telemetry.md)
już istnieją obie pary `remaining_known/remaining_ms` oraz
`playlist_remaining_known/playlist_remaining_ms`. Unknown oznacza brak wartości,
a nie zero. Obie wartości są efektywnym czasem rzeczywistym uwzględniającym speed.

- `playlist-telemetry.c`: calculate_at_speeds sumuje bieżący remainder i przyszłe
  wpisy bieżącego pass; Loop nie dodaje kolejnego przebiegu. Shuffle korzysta z
  aktualnej kolejki cyklu, bez zmiany jej przy odczycie. Foldery i duplikaty są
  osobnymi wpisami. Brak długości któregokolwiek przyszłego wpisu unieważnia sumę.
- `duration-inventory.c`: asynchroniczny, ograniczony inventory lokalnych plików;
  cache lookup telemetrii nie wykonuje I/O. Ograniczenia discovery/cache mogą
  pozostawić długość nieznaną. Przyszłym URL/streamom nie ufa się jako plikom.
- `media-playlist-source.c`: odczyt aktywnego dekodera z kontrolą generacji;
  pauza zamraża jego zegar, seek aktualizuje go bez cache wall-time. Lokalne
  media korzystają z ustawionej prędkości, URL z 100%.
- `telemetry_observe`: snapshot_revision zmienia się przy zmianie znaczenia lub
  discontinuity, nie od samego postępu zegara. Equal revision może nieść nowszy czas.

Nie potwierdzono błędu wymagającego zmiany MPS. To audyt kodu i jego istniejących
testów, nie nowy runtime test pluginu ani deklaracja nowego buildu MPS.
VEN przesyła gotowe liczby MPS; nie sumuje długości, nie ekstrapoluje czasu.

## Konfiguracja i GUI

Nowe addytywne pola config v3: `media_bridge.auxiliary_timers` (maksymalnie trzy
wiersze) i `media_bridge.stage_timer_source` (off/aux1/aux2/aux3/secondary).
Każdy wiersz ma enabled, aux_timer_index, media_timer_source i inactive_policy.
Aktywne przypisania slotów muszą być unikalne; aktywne błędne wartości są
odrzucane przez Swift i Python przed uruchomieniem automatyzacji. Wyłączony bridge
oraz nieużywane pola wyłączonych wyjść nie blokują automatyzacji przerw.

Settings ma Add timer, enable, slot, Current file/Whole playlist — current pass,
Stop/Keep last, Remove i status per wiersz. Secondary Message pozostaje niezależne,
z tym samym szablonem, zmiennymi, polityką i podglądem. Stage Timer wybiera tylko
jedno źródło prezentacji. Nieaktywne stare ustawienia nie włączają go przypadkowo.

Brak tablicy oznacza legacy pojedyncze wyjście; pusta tablica oznacza jawnie brak
Aux. Stare pole timer nadal obsługuje Secondary Message. GUI przenosi stary Aux
na jeden wiersz i zachowuje slot/source/policy oraz wybrany Stage source. Pierwszy
save listy tworzy dokładny `.backup`, jeśli nie istnieje; wcześniejszy backup jest
zachowany. Odczyt konfiguracji v3 jej nie przepisuje. Nie podnoszono config_version
ani wersji produkcyjnej; migracja v2→v3 i pozostałe klucze pozostają zachowane.

Przykład Aux1=current + Aux2=playlist i kroki ręczne: [MEDIA-BRIDGE.md](MEDIA-BRIDGE.md#two-simultaneous-countdowns).
Shipped example zachowuje bridge i oba wiersze wyłączone.

## Synchronizacja i własność

- Jeden dotychczasowy bounded worker i połączenie OBS; maksymalnie jeden poll
  Ontime na batch wyjściowy. Każdy slot ma osobne owned/signature/state/error.
  Stabilny postęp czasu nie restartuje liczników i nie zapisuje ponownie journalu.
- HTTP/error jednego slotu nie blokuje drugiego. Nieznana suma playlisty nie
  blokuje znanego Current file. Retry błędu nie restartuje zdrowego slotu.
  Wspólna awaria poll/transportu może dotyczyć wszystkich; serial timeouty mogą
  opóźnić następne wyjście, ale nie tworzą dodatkowych workerów.
- Journal zapisuje target hash i `indices` wszystkich owned/uncertain slotów.
  Stary pojedynczy `index` jest czytany. Przed pierwszą mutacją nowego slotu
  atomowy zapis, fsync pliku i katalogu muszą zakończyć się sukcesem. Intencja
  niepewnego zapisu zostaje w pamięci, by zapis następnego slotu jej nie utracił.
- Usuwanie jednej własności zachowuje pozostałe wpisy. Failed stop/cleanup
  pozostawia journal. keep_last pauzuje, zachowując własność; normalne close
  zatrzymuje wszystkie własne sloty. Nigdy nie zatrzymuje slotu nieposiadanego.
- Po SIGKILL aktywne lub paused wpisy journalu wymagają operator-assisted recovery.
  W modelu multi blokują tylko swoje sloty; stopped można idempotentnie zwolnić
  i ponownie zsynchronizować. Inny healthy slot zachowuje diagnostykę i działanie.
  Zmieniony target lub uszkodzony journal blokuje nowe mutacje. Legacy model
  zachowuje dawną, bardziej konserwatywną globalną blokadę recovery.
- Odtworzono dodatkowy wyścig: ingest podczas close mógł zastąpić shutdown i
  uniemożliwić zatrzymanie kolejnego slotu. Przed poprawką test przyjął spóźniony
  snapshot; teraz close atomowo ustawia closed i stan shutdown. Ingest, heartbeat
  i reset sesji odrzucają nowe dane po closed; już przyjętej akcji HTTP nie cofa się.

Ontime 4.14 nie ma wyłącznego owner/CAS. Sloty muszą być zarezerwowane dla VOS.
Sam journal nie dowodzi, że po awarii nadal steruje nimi ta sama integracja.
Nie automatyzujemy zatrzymywania aktywnych orphanów ani przełączania rundownu.

## Zmienione pliki

| Pliki | Zakres |
| --- | --- |
| services/media_bridge.py | Walidacja, niezależne sloty, współdzielony poll, journal/recovery, shutdown. |
| services/ontime_break_sync.py | Walidacja media config przy load, przed startup health/akcjami. |
| app/Sources/AppConfig.swift | Addytywna walidacja, odczyt legacy i backup zapisu listy. |
| app/Sources/SettingsWindowController.swift | Wiersze timerów, niezależna wiadomość i jeden Stage source. |
| app/Sources/StatusPresentation.swift, ApplicationMain.swift | Statusy per slot i przekazanie ich do Settings. |
| tests/test_multi_timers.py | 19 scenariuszy wielokrotnych wyjść i awarii. |
| tests/fixtures/media_timer_configs.json | 13 wspólnych przypadków walidacji Swift/Python. |
| tests/test_keep_last.py | Te same asercje własności odwołują się teraz do stanu slotu 1. |
| app/Tests/AppConfigMigrationTests.swift | Wspólne fixtures, legacy/multi/backup/duplikaty/disabled. |
| app/Tests/SettingsWindowLayoutTests.swift | Faktyczne Add/Remove/limit/duplikaty/save Aux1+Aux2, Secondary migration i zrzuty. |
| app/Tests/StatusPresentationTests.swift | Jednoczesne synced/unknown/disabled. |
| config/config.example.json, README.md, MEDIA-BRIDGE.md | Przykład i rzeczywiste zachowanie/migracja/recovery. |
| MULTI-TIMERS-AUDIT.md | Ten raport. |

Nie zmieniono kolejki automatyzacji OBS, kontrolera telemetrii/epochs, endpointów
POST/Bearer ani workflow/build/version/signing. Ich istniejące regresje pozostają
w obowiązkowym wspólnym test.sh; testów nie usunięto ani nie osłabiono.

## Walidacja i commity

- Pierwsze 10 nowych multi-testów nie przechodziło przed implementacją.
- Nowy test close/ingest odtworzył konkretną akceptację snapshotu podczas cleanup;
  po poprawce odrzuca oba spóźnione ingesty i potwierdza stop obu slotów.
- Lokalnie 114/114 Python OK (16.101 s), w tym 19 multi-scenariuszy. Atrapy
  Ontime/loopback oraz kontrolowany zegar 300 s; bez prawdziwych mutacji.
- py_compile services/tests, bash -n test.sh/build_app.sh, git diff --check: OK.
- [Pierwsze CI implementacji](https://github.com/Vencite/ven-obs-utils/actions/runs/43865701969):
  SUCCESS, job tests 2m17s; 109 Python OK (51.231 s), wszystkie 15 zestawów Swift
  PASS, AppKit, build macOS, package/upload OK. Obejrzano natywne zrzuty GUI.
- Kolejny commit domyka shutdown, legacy display/mode i dodaje 5 scenariuszy
  Python oraz kontrolę zachowania starej wiadomości w GUI. Jego testy natywne
  oraz końcowy artefakt są w CI ostatniego HEAD:
  [Tests na develop](https://github.com/Vencite/ven-obs-utils/actions/workflows/test.yml?query=branch%3Adevelop).
  Zadanie obejmuje oczekiwanie na ten wynik; finalny run/artefakt podajemy użytkownikowi.

Commity implementacji:
- `75ce3882b39d85f7c0d830b1c2090948f9f557ac`
- `8f41670d03ed4eae687941f48f39e41649ba0d79`
- `d238fe017f31fca1e2e8fa5f5409c329aef63168`

MPS nie był modyfikowany, kompilowany ani wysyłany. Bez merge do main, tagów,
release oraz zmiany 0.2.0. Zielone CI nie zastępuje ręcznych prób OBS/MPS/Ontime.
Przed live trzeba wykonać opisane w MEDIA-BRIDGE.md scenariusze Aux1+Aux2,
next/seek/speed/Shuffle/Loop, długa pauza, unknown/URL, niezależne błędy,
keep_last/stop, close/SIGKILL/recovery, reconnect, Dry Run i regresję przerw.

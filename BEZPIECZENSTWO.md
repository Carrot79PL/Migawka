# Migawka – zabezpieczenia danych

Opis tego, jak aplikacja chroni przeglądane dane i czego nie jest w stanie zagwarantować.

## Co robi aplikacja

**Brak komunikacji sieciowej (z jednym wyjątkiem do włączenia)**
- Aplikacja sama nie łączy się z siecią: nie używa URLSession, gniazd ani Network.framework. Pliki, ich nazwy i zawartość nigdy nie są wysyłane poza komputer.
- Biblioteki mpv i ffmpeg potrafią obsługiwać sieć, ale aplikacja przekazuje im tylko ścieżki plików lokalnych i blokuje im wszystkie protokoły poza plikami.
- **Wyjątek: mapa lokalizacji zdjęcia** (domyślnie wyłączona). Włącza się ją klawiszem M, ikoną mapy albo z menu Widok, a przy pierwszym włączeniu aplikacja prosi o zgodę. Mapa pobiera fragmenty z serwerów Apple, więc Apple dowiaduje się, jaki obszar jest pokazywany, czyli w przybliżeniu, gdzie zrobiono zdjęcie. macOS może też zachować te fragmenty w swojej pamięci podręcznej na dysku. Dopóki mapa jest wyłączona, panel informacji nie pokazuje współrzędnych, a tylko informuje, że są w pliku.

**Drukowanie**
- Przed pierwszym wydrukiem aplikacja ostrzega, że wydruk opuszcza pamięć RAM. macOS przekazuje każdy wydruk przez systemową kolejkę drukowania, która zapisuje go na dysku do czasu wydrukowania, a „Zachowaj jako PDF” tworzy zwykły plik. Przy danych objętych RODO drukuj tylko na zaufanej drukarce i usuwaj zapisane PDF-y.

**Zawartość archiwów nigdy nie trafia na dysk**
- Archiwa (zip, rar, 7z…) są rozpakowywane wyłącznie na dysk w pamięci RAM. Jest on ukryty w Finderze i wyłączony z indeksowania Spotlight.
- Zanim aplikacja cokolwiek rozpakuje, sprawdza, że folder docelowy naprawdę jest dyskiem RAM. Jeśli dysku RAM nie da się utworzyć, archiwum nie jest rozpakowywane. Aplikacja nigdy nie zapisuje tych danych na dysk SSD zamiast do RAM.
- Pojemność dysku RAM ustawia się w menu Bezpieczeństwo › Pojemność dysku RAM: 25%, 50% (domyślnie) lub 75% pamięci Maca. Pamięć jest zajmowana dopiero przy rozpakowywaniu. Gdy dysk RAM się zapełni, rozpakowywanie się zatrzymuje, a aplikacja pokazuje komunikat o braku miejsca. Nic nie jest wtedy zapisywane na dysk SSD. Przy 75% i dużych archiwach macOS może przenieść część pamięci do pliku wymiany, który jest zaszyfrowany kluczem kasowanym przy restarcie.
- Dysk RAM jest usuwany przy otwarciu nowego źródła, przy czyszczeniu danych, przy zamknięciu aplikacji, a po awarii przy następnym uruchomieniu. Restart komputera także go usuwa.

**Hasła do archiwów**
- Hasło jest przekazywane narzędziu rozpakowującemu bezpośrednio, nigdy w wierszu poleceń, gdzie mogłyby je odczytać inne programy.
- Hasła są przechowywane tylko w pamięci, do czasu wyczyszczenia danych lub zamknięcia aplikacji.

**Blokada aplikacji Touch ID lub hasłem Maca (menu Bezpieczeństwo)**
- Po bezczynności (domyślnie 3 minuty, do wyboru 1, 3, 5, 10 minut lub nigdy), na żądanie (⇧⌘L) i, jeśli włączone, po przejściu do innej aplikacji, okno zostaje całkowicie zakryte, a odtwarzany film zatrzymany. Odblokowanie wymaga Touch ID albo hasła konta macOS.
- Dane zostają w pamięci, więc po odblokowaniu można pracować dalej. Dłuższa bezczynność nadal kasuje wszystko, zgodnie z ustawieniem czyszczenia.
- Aplikacja nie ma własnego hasła ani konta i niczego w związku z blokadą nie zapisuje. Odcisk palca i hasło sprawdza sam macOS.

**Automatyczne czyszczenie (menu Bezpieczeństwo)**
Usuwa listę plików, miniatury, hasła i dysk RAM:
- po zablokowaniu ekranu, uruchomieniu wygaszacza, uśpieniu Maca lub przełączeniu użytkownika (domyślnie włączone),
- po okresie bezczynności, liczonym dla całego komputera (domyślnie 10 minut, do wyboru 2, 5, 10, 30 minut lub nigdy),
- ręcznie, przez „Zamknij i wyczyść dane teraz” (⇧⌘W).

**Blokada zrzutów i udostępniania ekranu** (domyślnie włączona)
- Okna aplikacji są oznaczone jako niedostępne do przechwytywania. Utrudnia to zrobienie zrzutu, nagranie ekranu albo przypadkowe pokazanie danych w Teams, Zoomie itp.

**Brak śladów w systemie**
- Aplikacja nie zapisuje stanu okien, który macOS normalnie zapisuje na dysk, czasem razem z obrazem okna.
- Po każdym użyciu okna wyboru plików, oraz przy starcie i zamknięciu aplikacji, usuwana jest ścieżka ostatnio otwartego folderu, którą macOS zapisuje w ustawieniach.
- Miniatury i obrazy po korektach są tylko w pamięci. Korekty obrazu nie zmieniają plików i niczego nie zapisują.
- Plików z archiwów nie da się przekazać do Findera, Podglądu ani innych aplikacji, bo one tworzą własne miniatury i listy ostatnich plików na dysku.
- „Edytuj w programie” (Photoshop, Pixelmator…) działa tylko dla zwykłych plików z folderów. Edytor zapisuje zmiany w oryginalnym pliku i może zachować własne kopie, autozapis i listę ostatnich plików. Dla plików z archiwów ta opcja jest zablokowana.
- Odtwarzacz wideo nie publikuje nazwy pliku w Centrum sterowania („Teraz odtwarzane”).
- W ustawieniach aplikacji zapisywane są tylko: rozmiar miniatur, widoczność nazw plików, czas i przejście slajdu w pokazie, tryb paska miniatur, widoczność panelu informacji i opcje z menu Bezpieczeństwo. Żadne z nich nie dotyczy przeglądanych plików.
- Ulubione, wyszukiwana fraza i filtry są tylko w pamięci i znikają razem z resztą danych przy czyszczeniu.
- Ustawienie mapy lokalizacji i zgoda na nią są zapisywane w ustawieniach aplikacji (bez żadnych współrzędnych).
- **Biblioteka Zdjęć** (także iCloud) jest dostępna dopiero po zgodzie użytkownika w systemowym okienku macOS. Zdjęcia są odczytywane przez systemową bibliotekę PhotoKit prosto do pamięci, a filmy odtwarzane z oryginału w bibliotece. Aplikacja niczego z biblioteki nie kopiuje, nie zmienia ani nie usuwa. Dla elementów biblioteki są zablokowane: „Edytuj w programie”, „Pokaż w Finderze” i otwieranie w innych aplikacjach.
- „Wszystkie metadane” są odczytywane na żądanie i trzymane tylko w pamięci, póki panel jest otwarty. Współrzędne GPS są wtedy widoczne, ale nigdzie nie są wysyłane.

**Ochrona samej aplikacji**
- Aplikacja jest podpisana w trybie „hardened runtime”. Blokuje to wstrzykiwanie obcego kodu przez zmienne systemowe i podłączanie debuggera przez inne programy.
- **Świadomie wyłączona jest weryfikacja bibliotek** (za zgodą użytkownika), żeby aplikacja mogła wczytać odtwarzacz mpv z Homebrew. Skutek: program, który już działa na koncie użytkownika i może zmieniać pliki w `/opt/homebrew`, mógłby podmienić bibliotekę mpv i wykonać swój kod wewnątrz aplikacji. Taki program ma jednak i tak dostęp do plików użytkownika. Aby to wykluczyć, trzeba by podpisać aplikację płatnym certyfikatem Apple Developer i dołączyć mpv do aplikacji.
- Filmy w formatach spoza Apple (AVI, MKV, WMV, FLV i inne) odtwarza bezpośrednio z pliku mpv (zainstalowany z Homebrew), bez konwersji i bez kopii na dysku. mpv działa z wyłączonymi skryptami, plikami konfiguracji, zapisem pozycji, zrzutami ekranu i dostępem do sieci: otwiera tylko pliki lokalne.
- Miniatury filmów robi ffmpeg (zainstalowany z Homebrew w `/opt/homebrew/bin`) prosto do pamięci. Gdy mpv nie jest dostępny, ffmpeg przygotowuje film do odtwarzania wyłącznie na dysku RAM. ffmpeg ma dostęp tylko do plików lokalnych: spreparowany plik nie zmusi go do połączenia z siecią.
- Narzędzia rozpakowujące są uruchamiane bez terminala, z blokadą ścieżek typu `../` i dowiązań prowadzących poza dysk RAM (domyślne zachowanie bsdtar). Archiwa w archiwach są rozpakowywane maksymalnie do 3 poziomów.

## Czego aplikacja nie może zagwarantować (obowiązki po stronie komputera)

1. **FileVault musi być włączony.** Na tym Macu jest włączony. Chroni wszystko, czego aplikacja nie kontroluje, w tym oryginalne pliki i ewentualne dane z wersji sprzed zmian.
2. **Zwykłe foldery (nie archiwa)** to oryginalne pliki użytkownika. Aplikacja ich nie kopiuje, ale:
   - okno wyboru plików, tak jak Finder, może wygenerować miniatury przeglądanych plików w systemowej pamięci podręcznej QuickLook,
   - opcje „Pokaż w Finderze” i „Otwórz w Podglądzie” przekazują plik do tych aplikacji, które mogą zapisać własne miniatury i listę ostatnich plików.
3. **Pamięć wymiany (swap).** Przy braku RAM macOS może przenieść część pamięci na dysk. Zawsze szyfruje ją jednak kluczem, który znika po restarcie.
4. **Dziennik systemowy.** Biblioteki systemowe (np. dekodery obrazu) mogą w razie błędu zapisać ścieżkę pliku do dziennika macOS. macOS domyślnie ukrywa takie dane jako `<private>`.
5. **Blokada zrzutów ekranu** jest respektowana przez macOS i typowe aplikacje do wideokonferencji. Nie chroni przed zrobieniem zdjęcia ekranu telefonem ani przed oprogramowaniem z uprawnieniami administratora.
6. **Złośliwe oprogramowanie** działające na koncie użytkownika ma dostęp do tego samego co użytkownik, w tym do dysku RAM, dopóki ten jest podłączony. Konieczne są aktualizacje macOS i ochrona konta.
7. **Biblioteka Zdjęć to dane, które już leżą na dysku i w iCloud.** Migawka nie dokłada im śladów, ale też nie daje im ochrony archiwów w RAM. Jeśli w Zdjęciach jest włączone „Optymalizuj pamięć Maca”, a oryginał jest tylko w iCloud, aplikacja Zdjęcia sama pobiera go z iCloud do swojej biblioteki na dysku (tak jak przy oglądaniu w Zdjęciach). Danych objętych RODO lepiej nie trzymać w bibliotece Zdjęć zsynchronizowanej z iCloud.
8. **Archiwa 7z z hasłem** obsługuje 7-Zip (zainstalowany z Homebrew). RAR z hasłem jest obsługiwany przez `unrar`, ale nie był testowany.

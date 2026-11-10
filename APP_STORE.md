# Migawka w Mac App Store – co trzeba zrobić

Stan na wersję 0.5. Aplikacja działa dziś jako program spoza sklepu. Mac App Store ma wymagania, których obecna budowa nie spełnia. Poniżej opisuję je od najważniejszych, z propozycją rozwiązania.

## 1. Piaskownica (App Sandbox) – największa zmiana

Każda aplikacja w Mac App Store musi działać w piaskownicy. Program widzi wtedy tylko pliki, które użytkownik sam wskazał, i nie może uruchamiać dowolnych narzędzi systemowych. Trzy fundamenty Migawki tego nie przechodzą:

| Dziś | Problem w piaskownicy | Rozwiązanie |
|---|---|---|
| Dysk RAM tworzony przez `diskutil` / `hdiutil` / `newfs_hfs` | Piaskownica nie pozwala tworzyć ani montować dysków | Rozpakowywanie **w pamięci aplikacji**, bez żadnego dysku: zawartość archiwów jako bufory w RAM, zdjęcia dekodowane prosto z pamięci, filmy odtwarzane z pamięci (AVFoundation przez własny „resource loader”, mpv przez swoje API strumieni). Dla RODO to nawet lepiej: nie ma żadnego woluminu, który mógłby zostać po awarii. |
| Archiwa rozpakowywane przez `bsdtar`, `7zz`, `unrar` uruchamiane jako osobne programy | Nie wolno uruchamiać narzędzi spoza pakietu aplikacji | Biblioteki wbudowane w aplikację: **libarchive** (licencja BSD: zip, 7z, tar, gz, rar do odczytu), kod **unrar** (licencja RARLAB pozwala na darmowe użycie do rozpakowywania), ewentualnie biblioteka 7-Zip (LGPL) dla rzadkich odmian 7z. |
| mpv i ffmpeg z Homebrew | Biblioteki spoza pakietu nie wczytają się, a Homebrew nie wolno zakładać | Wbudowanie mpv i ffmpeg do aplikacji, zbudowanych w wersji **LGPL** (bez x264/x265 i innych części GPL), podpisanych razem z aplikacją. Wtedy znika też wyłączona dziś weryfikacja bibliotek. |

**Licencje (ważne):** GPL nie da się pogodzić z regulaminem App Store. Z tego powodu VLC zniknął kiedyś ze sklepu. Biblioteki LGPL (ffmpeg, mpv w wersji LGPL, 7-Zip) bywają w sklepie, ale wymagają dynamicznego łączenia, udostępnienia informacji o licencji i umożliwienia podmiany biblioteki. Przed publikacją warto to skonsultować z prawnikiem. Prostsze alternatywy:
- wersja sklepowa tylko z formatami, które obsługuje macOS (MP4, MOV, HEVC, H.264), plus wersja „Pro” z mpv do pobrania ze strony (poza sklepem, z notaryzacją Apple),
- albo licencjonowany komercyjny dekoder.

Pozostałe funkcje działają w piaskownicy po dodaniu uprawnień:

| Funkcja | Uprawnienie / uwagi |
|---|---|
| Otwieranie plików i folderów (okno, przeciąganie, „Otwórz za pomocą”, usługa „Otwórz w Migawce”) | `com.apple.security.files.user-selected.read-only` – macOS sam daje dostęp do wskazanych plików |
| Mapa lokalizacji | `com.apple.security.network.client` |
| Drukowanie | `com.apple.security.print` |
| Biblioteka Zdjęć | `com.apple.security.personal-information.photos-library` + opis `NSPhotoLibraryUsageDescription` (już dodane) |
| Edycja w innym programie | bez zmian (`NSWorkspace`) |
| Czyszczenie po blokadzie ekranu / bezczynności | bez zmian |
| Blokada zrzutów ekranu | bez zmian |

## 2. Konto i podpis

- **Apple Developer Program:** 99 USD rocznie, na osobę prywatną albo na firmę. Firma wymaga numeru D-U-N-S.
- **Certyfikaty:** „Apple Distribution” do sklepu (i „Developer ID” dla ewentualnej wersji spoza sklepu), profil aplikacji z identyfikatorem, np. `pl.marchewka.migawka` zamiast obecnego `local.przegladarka.zdjec`. Zmiana identyfikatora oznacza nowe, puste ustawienia u użytkowników, co przy pierwszym wydaniu nie ma znaczenia.
- **Budowanie:** do wysyłki do sklepu potrzebny jest projekt Xcode, archiwum i wysyłka do App Store Connect. Obecny `build.sh` wystarcza do testów, ale nie do sklepu.

## 3. App Store Connect

- **Nazwa:** „Migawka” – sprawdzić dostępność w sklepie i jako znak towarowy. Można dodać podtytuł, np. „Bezpieczna przeglądarka zdjęć” / „Private photo & video viewer”.
- **Kategoria:** Fotografia (Photography), dodatkowa: Narzędzia (Utilities).
- **Opisy, słowa kluczowe, zrzuty ekranu po polsku i angielsku.** Tłumaczenie aplikacji jest gotowe.
- **Polityka prywatności (wymagany adres URL).** Migawka niczego nie zbiera ani nie wysyła, więc w ankiecie prywatności: *Data Not Collected*. Mapa korzysta z map Apple, a to nie jest zbieranie danych przez autora.
- **Cena:** płatna jednorazowo albo darmowa z jednorazowym zakupem wersji pełnej (In-App Purchase).
- **Recenzja Apple:** zwykle 1–3 dni. W notatce dla recenzenta warto opisać dysk RAM / czyszczenie danych i mapę.

## 4. Proponowana kolejność prac

1. Silnik „tylko w pamięci” zamiast dysku RAM: rozpakowywanie przez libarchive do pamięci, wyświetlanie zdjęć i filmów z pamięci. To największy kawałek pracy, a sam w sobie wzmacnia ochronę danych.
2. Wbudowanie bibliotek w aplikację (libarchive, unrar, mpv/ffmpeg w wersji LGPL albo decyzja „wersja sklepowa bez mpv”).
3. Projekt Xcode z piaskownicą i uprawnieniami, testy wszystkich funkcji w piaskownicy.
4. Konto deweloperskie, identyfikator, certyfikaty, TestFlight dla Maca.
5. Strona z polityką prywatności, opisy i zrzuty po polsku i angielsku, wysyłka do recenzji.

## Co jest już gotowe

- Tłumaczenie na angielski całego interfejsu, z poprawną odmianą liczby mnogiej po polsku i angielsku. Aplikacja wybiera język systemu: polski dla polskiego, angielski dla wszystkich innych.
- Ikona, nazwa, wersja, autor, okno „O programie”.
- Brak zbierania jakichkolwiek danych: to duży atut w opisie i w ankiecie prywatności.

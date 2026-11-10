# Migawka

Bezpieczna przeglądarka zdjęć, filmów i archiwów dla macOS, zaprojektowana dla danych wrażliwych (RODO): dokumentacji medycznej, zdjęć z oględzin, skanów dokumentów.

*A private photo, video and archive viewer for macOS, built for sensitive data (GDPR).*

Wersja: 0.5 · Autor: Tomasz Marchewka

## Najważniejsze funkcje

- Foldery, pojedyncze pliki i archiwa (ZIP, 7z, RAR, TAR…, także z hasłem). Zawartość archiwów trafia wyłącznie na dysk RAM, nigdy na SSD.
- Biblioteka Zdjęć macOS (także iCloud) z albumami, odczytywana prosto do pamięci.
- Szybka siatka miniatur (dziesiątki tysięcy plików), drzewo folderów, wyszukiwanie, filtry, ulubione.
- Podgląd z powiększaniem, korekty (bez zmiany pliku), panel informacji i wszystkie metadane (EXIF, TIFF, GPS, IPTC, ścieżki filmu).
- Filmy: AVFoundation dla MP4/MOV, wbudowany mpv dla AVI, MKV, WMV i innych; własny pasek sterowania, obracanie pionowych filmów.
- Pokaz slajdów z przejściami, pasek miniatur, druk zdjęcia i stykówki, opcjonalna mapa GPS (za zgodą).
- Ochrona: automatyczne czyszczenie danych (blokada ekranu, uśpienie, bezczynność), blokada Touch ID, blokada zrzutów ekranu, brak komunikacji z siecią poza opcjonalną mapą.
- Interfejs po polsku i angielsku.

Szczegóły zabezpieczeń: [BEZPIECZENSTWO.md](BEZPIECZENSTWO.md). Plan publikacji w Mac App Store: [APP_STORE.md](APP_STORE.md), teksty do sklepu: [OPIS_APP_STORE.md](OPIS_APP_STORE.md).

## Budowanie

Wymagania: macOS 14+ na Apple Silicon, narzędzia Xcode (swiftc), [Homebrew](https://brew.sh).

```bash
brew install ffmpeg mpv sevenzip
./build.sh
```

Skrypt kompiluje aplikację, podpisuje ją ad hoc (hardened runtime, uprawnienia z `Entitlements.plist`) i instaluje jako `~/Applications/Migawka.app`. ffmpeg, mpv i 7-Zip są opcjonalne: bez nich aplikacja działa, ale z mniejszą liczbą formatów.

Ikona: `swift make_icon.swift` tworzy `AppIcon.icns`.

## Struktura

| Plik | Zawartość |
|---|---|
| `PrzegladarkaZdjec.swift` | Model galerii, pamięć miniatur, okno główne, podgląd, aplikacja |
| `Scanner.swift`, `SecureTemp.swift` | Skanowanie folderów, rozpakowywanie archiwów, dysk RAM |
| `GridView.swift`, `FolderTree.swift`, `Filmstrip.swift` | Siatka miniatur, panel boczny, pasek miniatur |
| `VideoView.swift`, `MPVPlayer.swift`, `PlaybackBar.swift` | Odtwarzanie filmów (AVFoundation, mpv) i pasek sterowania |
| `PhotoLibrary.swift`, `Metadata.swift`, `PhotoInfo.swift` | Biblioteka Zdjęć, metadane, panel informacji i mapa |
| `Security.swift`, `AppLock.swift` | Czyszczenie danych, blokada aplikacji |
| `Adjustments.swift`, `Printing.swift`, `ExternalEditor.swift` | Korekty, druk, edycja w innym programie |
| `CMpv/` | Nagłówki API libmpv (licencja ISC) |
| `Localization/` | Tłumaczenia (en, pl) |

## Licencja

© 2026 Tomasz Marchewka. Wszelkie prawa zastrzeżone. Nagłówki w `CMpv/` pochodzą z projektu mpv i są objęte licencją ISC.

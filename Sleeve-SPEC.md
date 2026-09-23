# Sleeve — Audio-Werkzeugkasten für macOS

**Autor:** NeonRost
**Lizenz:** GPLv3 oder später (wie MIKE)
**Ziel:** Nativer Apple-Silicon-Ersatz für Tagr, erweiterbar zum Audio-Allrounder
**Sprachen:** Englisch (Basis), Deutsch, Spanisch

---

## 1. Konzept

Sleeve ist ein modusbasierter Audio-Werkzeugkasten. Die gemeinsame Klammer ist
immer die **Dateiliste**: Rippen erzeugt Dateien, Taggen bearbeitet sie,
Konvertieren wandelt sie um. Alle Modi arbeiten am selben Objekt.

Der Name kommt von der Plattenhülle — das, was den Ton umgibt, beschriftet und
einordnet. Genau das macht die App.

**Nicht-Ziele:** Kein Player. Keine Bibliotheksverwaltung. Kein Audio-Editor
mit Wellenform (das bleibt in MIKE).

### 1.1 Modus-Architektur

Kein Nero-artiges Startfenster, das den Nutzer vorab zur Entscheidung zwingt.
Stattdessen das Resolve-Modell: ein persistenter Umschalter im Fenster, die
Dateiliste bleibt beim Wechsel stehen.

```
┌─ Toolbar ────────────────────────────────────────────────┐
│  [ Taggen │ Konvertieren │ Rippen ]        modusabhängig  │
├──────────────┬───────────────────────────────────────────┤
│              │                                           │
│  Inspector   │   Trackliste — modusübergreifend,         │
│  je Modus    │   bleibt beim Wechsel erhalten            │
│              │                                           │
├──────────────┴───────────────────────────────────────────┤
│ + − × ⟳          │  42 Songs, 7 geändert                 │
└──────────────────────────────────────────────────────────┘
```

Umsetzung als `Picker` mit `.segmented`-Style, **ganz links in der Toolbar**,
direkt daneben „Speichern". Beide gehören zur Grundbedienung und stehen in
jedem Modus. Alles Modusspezifische sammelt sich am **rechten** Rand.

Mittig wäre der Umschalter die schlechtere Wahl: er belegt die Mitte und
drängt die übrigen Knöpfe ins Überlaufmenü.

**Modusabhängig heißt wörtlich modusabhängig.** Nummerierung, Schreibweise und
die Pattern-Engine gehören zum Taggen und haben im Konvertieren-Modus nichts
zu suchen. Über alle Modi hinweg bleiben nur „Auf Platte speichern" und der
Umschalter selbst.

Die Toolbar zeigt Symbol **und** Beschriftung, und der Platz dafür ist knapp:
Seitenleiste, Speichern-Knopf und Umschalter verbrauchen bereits gut die
Hälfte der Breite. Deshalb kurze Beschriftungen (deutsche Komposita sind
gnadenlos), kein Fenstertitel — der Name steht in der Menüleiste — und
Randfunktionen wie „Zu Music hinzufügen" im Menü statt in der Toolbar.

**Der entscheidende Architektur-Punkt:** `TrackListModel` ist ein
eigenständiges, modusunabhängiges Modell. Der Inspector ist nur eine über
`activeMode` ausgewählte View. Dadurch kostet jeder weitere Modus später fast
nichts.

```swift
enum AppMode: String, CaseIterable, Identifiable {
    case tag, convert, rip
    var id: String { rawValue }
}

@Observable
final class AppState {
    var activeMode: AppMode = .tag
    let trackList = TrackListModel()     // modusübergreifend
    var availableModes: [AppMode] {
        // Konvertieren nur wenn ffmpeg gefunden, Rippen nur bei CD im Laufwerk
    }
}
```

Modi, deren Voraussetzungen fehlen, werden nicht ausgeblendet, sondern
deaktiviert mit erklärendem Tooltip. Ausgeblendete Funktionen wirken wie Bugs.

**In Version 1.0 wird nur „Taggen" implementiert.** Die anderen Segmente sind
sichtbar, aber deaktiviert und mit „Kommt bald" versehen — oder bis zur 1.1
komplett ausgeblendet, das entscheidet sich beim Release.

---

## 2. Technischer Stack

| Bereich | Entscheidung |
|---|---|
| Sprache | Swift 6, Strict Concurrency |
| UI | SwiftUI, `Table` für die Trackliste |
| Minimum | macOS 14 (Sonoma) |
| Architektur | Apple Silicon nativ |
| Tag-Engine | TagLib 2.x über die C-API (`tag_c.h`), statisch gelinkt |
| Konvertierung | ffmpeg, **extern** (nicht gebundelt) |
| CD-Erkennung | IOKit `IOCDMedia` bzw. `drutil toc` → MusicBrainz Disc ID |
| Metadaten | MusicBrainz (Disc-ID-Lookup), Discogs (Cover, Style) |
| Netzwerk | URLSession, async/await |
| Persistenz | `UserDefaults`, Tokens im Keychain |

### 2.1 TagLib-Einbindung

Kein C++-Interop nötig. Die C-API deckt seit TagLib 2.0 auch PropertyMap
(`ALBUMARTIST`, `COMPOSER`, `DISCNUMBER`) und Complex Properties (Coverbilder) ab.

Verwendete Version: **TagLib 2.3.2**.

**Build-Skript** (`Scripts/build-taglib.sh`, einmalig): klont den Tag, baut
arm64-static und kopiert Header und Bibliotheken nach `Vendor/taglib/`.

```bash
cmake -S "$SRC" -B build-arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DVISIBILITY_HIDDEN=ON \
  -DBUILD_TESTING=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_BINDINGS=ON \
  -DWITH_ZLIB=ON
cmake --build build-arm64 --config Release
cmake --install build-arm64 --config Release
```

`BUILD_BINDINGS=ON` ist nicht optional — ohne das entsteht keine C-API.

**Xcode-Einbindung:**
- `Vendor/taglib/` → Header Search Paths (clang findet die `module.modulemap`
  dann von selbst; **nicht** `Vendor/taglib/include/` eintragen)
- `libtag_c.a` **und** `libtag.a` → Link Binary With Libraries
- Zusätzlich `libz.tbd` und `libc++.tbd` linken (TagLib ist intern C++)
- `Vendor/taglib/module.modulemap`:

```
module CTagLib {
    header "include/taglib/tag_c.h"
    link "tag_c"    // C-Bindings
    link "tag"      // C++-Kernbibliothek
    link "z"
    link "c++"
    export *
}
```

**Lizenz:** TagLib steht unter LGPL 2.1 / MPL 1.1. Statisches Linken in ein
GPLv3-Programm ist zulässig. TagLib-Quellen bzw. ein Link darauf gehören in die
Auslieferung, Vermerk in `LICENSES/` und in der README. Das Build-Skript legt
`LICENSES/taglib-LGPL-2.1.txt` und `taglib-MPL-1.1.txt` automatisch ab.

**Im Programm** („Über Sleeve", eigenes Fenster statt des Standardfelds — das
hängt die Build-Nummer an, „Version 1.0 (1)"): Icon, Name, Version, Hinweis
auf fehlende Gewährleistung und die GPL v3 oder später, „Lizenz anzeigen", Copyright aus
`NSHumanReadableCopyright` („Copyright (C) 2026 NeonRost"). „Lizenz anzeigen"
öffnet das Fenster **Lizenzen** mit dem vollen Text je Bestandteil, der im
Programm steckt: Sleeve (GPL v3), TagLib (LGPL 2.1 — von den beiden
TagLib-Lizenzen die mit der GPL verträgliche) und utfcpp (Boost 1.0, steckt
in TagLib). ffmpeg fehlt dort mit Absicht: Sleeve liefert es nicht mit. Die
Texte liegen in `Sleeve/Resources/Licenses/`; der GPL-Text ist der offizielle
(SHA-256 `3972dc97…`, wie `gpl-3.0.txt` bei der FSF), identisch mit `LICENSE`.

#### 2.1.1 Fallstricke (verifiziert am 12.09.2026)

**Die C-API liegt in einer eigenen Bibliothek.** TagLib 2.x baut `libtag.a`
(C++) und `libtag_c.a` (C-Bindings) getrennt. `link "tag"` allein ergibt
Undefined Symbols für jedes `taglib_*`-Symbol. Beide linken.

**UTF-8 ist Default.** `taglib_set_strings_unicode(1)` ist seit 2.0 überflüssig;
alle `char*` rein und raus sind UTF-8. Der Aufruf schadet nicht, die alte
Faustregel „erst auf Unicode stellen" ist aber überholt.

**Die Legacy-API ist kein sicherer Pfad.** `taglib_tag_comment()` und Kollegen
fallen bei fehlendem ID3v2-Frame stumm auf den ID3v1-Anhang zurück — und der ist
per Definition Latin-1, ohne Encoding-Kennzeichnung. Im Test lieferte die
Legacy-API `Kommentar mit Ãmlaut`, die PropertyMap `Kommentar mit Ümlaut`.
Konsequenz: `TagLibBridge` liest und schreibt **ausschließlich** über
`taglib_property_get/set`. Die Legacy-Funktionen kommen nur dort zum Einsatz, wo
es keine Property-Entsprechung gibt.

**`TAGLIB_COMPLEX_PROPERTY_PICTURE` ist aus Swift nicht erreichbar.** Das ist ein
funktionsartiges C-Makro und wird von Swift nicht importiert. Zum *Schreiben* von
Coverbildern muss `TagLibBridge` das
`TagLib_Complex_Property_Attribute`-Array von Hand aufbauen. *Lesen* geht
komfortabel über `taglib_picture_from_complex_property`, allerdings liefert diese
Funktion nur das **erste** Bild — für mehrere APIC-Frames muss das äußere
`TagLib_Complex_Property_Attribute***`-Array selbst durchlaufen werden.

**`ARCHS = arm64` ist Pflicht, nicht Geschmackssache.** Xcodes Standard
(`ARCHS_STANDARD`) baut für macOS universal. Gegen den arm64-only-Vendor-Build
linkt das nicht etwa mit einem Fehler, sondern mit hunderten
`ld: warning: ignoring file … required architecture 'x86_64'` — und einem
Binary ohne TagLib. Im Debug fällt das nicht auf, weil `ONLY_ACTIVE_ARCH = YES`
gilt; erst das Release-Build kippt. `ARCHS = arm64` steht deshalb in der
Projektkonfiguration.

**Smoketest:** `Scripts/run-smoketest.sh` kompiliert
`Scripts/taglib-smoketest.swift` gegen den Vendor-Build und liest alle Dateien in
`TestFiles/` samt Schreib-Roundtrip. Nach jedem TagLib-Update einmal laufen
lassen.
### 2.2 ffmpeg-Erkennung (ab Phase 4)

ffmpeg wird nicht mitgeliefert, sondern vom System erwartet — wie bei MIKE.
Damit der Konvertieren-Modus nicht stumm scheitert:

**Suchreihenfolge:**
1. Pfad aus den Einstellungen, falls vom Nutzer gesetzt
2. `/opt/homebrew/bin/ffmpeg` (Apple Silicon Homebrew)
3. `/usr/local/bin/ffmpeg` (Intel Homebrew / manuell)
4. `PATH` durchsuchen

`PATH` allein reicht **nicht** — eine per Finder gestartete App erbt die Shell-
Umgebung nicht und sieht Homebrew-Pfade oft nicht.

**Bei Nichtfund:** Der Modus bleibt **betretbar** — ihn zu sperren wäre ein
Zirkelschluss, denn die Anleitung steht genau in diesem Bereich. Am Starten
hindert stattdessen ein Blocker über dem Knopf.

Der Inspector zeigt dann eine Karte mit Erklärung und kopierbaren Befehlen,
„Manuell auswählen…" für einen eigenen Pfad und „Erneut suchen" nach der
Installation. Die Anleitung richtet sich danach, was auf dem Rechner liegt:

- **Homebrew vorhanden** → nur `brew install ffmpeg`
- **Homebrew fehlt** → erst der Homebrew-Installationsbefehl samt Link auf
  brew.sh, dann `brew install ffmpeg`. Ohne diese Prüfung liefe die Anleitung
  ins Leere und der Nutzer suchte den Fehler bei sich.

Ausgeführt wird nichts davon — die Befehle sind zum Kopieren da, das Terminal
bleibt beim Nutzer.

Ist ffmpeg gefunden, rutscht der Abschnitt ans **Ende** des Inspectors: nach
der Installation interessiert er nicht mehr.

**Keine Sandbox.** Homebrews ffmpeg ist gegen dutzende dylibs unter
`/opt/homebrew/lib` gelinkt. Ein Kindprozess erbt die Sandbox der App und darf
die nicht lesen — dyld bricht ab, bevor ffmpeg überhaupt startet. Externes
ffmpeg und App Sandbox schließen einander damit aus. Hardened Runtime und
Notarisierung bleiben unberührt; der Mac App Store fiele weg, ist mit GPLv3
aber ohnehin nicht vereinbar. Käme später ein statisch gelinktes ffmpeg ins
Bundle (§6.4), ließe sich die Sandbox wieder einschalten.

**Versionsprüfung:** `ffmpeg -version` beim Fund, Encoder-Verfügbarkeit einmalig
über `ffmpeg -encoders` abfragen und cachen. Ein LGPL-Build ohne `libmp3lame`
kann kein MP3 — das muss die App wissen und sagen, bevor der Nutzer einen
Batch startet.

---

## 3. Datenmodell

```swift
struct AudioTags: Equatable, Sendable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var comment: String?
    var lyrics: String?               // USLT / ©lyr / LYRICS
    var isCompilation: Bool
    var artwork: [Artwork]
}

struct Artwork: Equatable, Sendable {
    var data: Data
    var mimeType: String              // image/jpeg, image/png
    var pictureType: PictureType      // frontCover, backCover, artist, …
    var description: String?
}

@Observable
final class TrackFile: Identifiable {
    let id = UUID()
    var url: URL                      // veränderlich: Umbenennung, Konvertierung
    private(set) var original: AudioTags
    var edited: AudioTags
    var touchedFields: Set<TagField> = []   // siehe 4.1 — kritisch
    var proposedFilename: String?
    var lastError: TagError?
    var isDirty: Bool { !touchedFields.isEmpty || proposedFilename != nil }
}

@Observable
final class TrackListModel {
    var tracks: [TrackFile] = []
    var selection: Set<TrackFile.ID> = []
    // modusübergreifend, überlebt jeden Moduswechsel
}
```

### 3.1 Format-Mapping

| Feld | ID3v2 (MP3) | MP4 (M4A) | Vorbis (FLAC) |
|---|---|---|---|
| Album-Interpret | `TPE2` | `aART` | `ALBUMARTIST` |
| Komponist | `TCOM` | `©wrt` | `COMPOSER` |
| Disc-Nummer | `TPOS` | `disk` | `DISCNUMBER` |
| Compilation | — | `cpil` | `COMPILATION` |
| Cover | `APIC` | `covr` | `METADATA_BLOCK_PICTURE` |
| Songtext | `USLT` | `©lyr` | `LYRICS` |

`taglib_property_get(file, "ALBUMARTIST")` liefert den jeweils richtigen nativen
Key — das Mapping übernimmt TagLib weitgehend selbst. Ausnahme: Coverbilder über
`taglib_complex_property_get(file, "PICTURE")`.

---

## 4. Modus „Taggen" (Version 1.0)

### 4.1 Batch-Editor — der Kern

**Trackliste**
- Drag & Drop von Dateien und Ordnern, rekursiv
- Spalten: `#`, Titel, Interpret, Album, Jahr, Dauer, Dateiname, Status
- Sortierbar, Mehrfachauswahl mit Shift/Cmd, inline editierbar
- Statusspalte: unverändert / geändert / Fehler

**Inspector-Panel**
- Alle Felder aus `AudioTags`
- Bei Mehrfachauswahl mit unterschiedlichen Werten: Platzhalter
  `<Verschiedene>` statt leerem Feld
- **Ein Feld wird nur geschrieben, wenn es in `touchedFields` steht.**
  Nicht über String-Vergleich entscheiden. Genau hier zerschießt Tagr
  regelmäßig Felder, die der Nutzer nie angefasst hat: Feld sieht leer aus,
  also wird leer geschrieben. Das ist der wichtigste Einzelpunkt der Spec.
- Autocomplete aus den Werten bereits geladener Dateien

**Schreiben**
- `TagEngine` als `actor`, alle TagLib-Aufrufe off-main-thread
- Fortschrittsanzeige ab 20 Dateien
- Pro Datei fehlertolerant: eine kaputte Datei bricht den Batch nicht ab
- Fehler sammeln, am Ende in einem Sheet zusammenfassen
- **Undo:** `original`-Snapshot je Datei behalten, ein Session-weiter
  Undo-Schritt reicht. Cmd+Z muss funktionieren.
- Optional: Backup-Kopie neben der Datei

### 4.2 Nummerierung

- Tracks nach aktueller Sortierung durchnummerieren
- Führende Nullen (01 statt 1)
- Gesamtanzahl schreiben (03/12)
- Disc-übergreifend oder pro Disc neu beginnend

### 4.3 Schreibweise

- Title Case mit Ausnahmeliste ("of", "the", "und", "der" …), sprachabhängig
- GROSSBUCHSTABEN
- kleinschreibung
- Auf alle oder nur ausgewählte Felder anwendbar

### 4.4 Pattern-Engine

Beide Richtungen, gleiche Token-Syntax:

```
%artist%  %albumartist%  %album%  %title%
%track%   %disc%  %year%  %genre%  %composer%
```

**Tags → Dateiname**
- Beispiel: `%track% - %artist% - %title%`
- Live-Vorschau in eigener Spalte, bevor etwas passiert
- Ungültige Zeichen (`/`, `:`, Steuerzeichen) ersetzen, konfigurierbar
- Fehlende Tags: Segment inkl. umgebender Trennzeichen entfällt, statt
  `01 -  - Titel` zu erzeugen
- Kollisionen: ` (2)` anhängen
- Presets speicherbar

**Dateiname → Tags**
- Derselbe Pattern rückwärts: `%token%` wird zur benannten Capture-Group,
  alles dazwischen literal escaped → fertiger Regex
- Live-Vorschau als Tabelle, nicht-matchende Zeilen rot und übersprungen
- Presets: `%track% - %title%`, `%artist% - %title%`,
  `%track%. %artist% - %title%`, `%artist% - %album% - %track% - %title%`
- Bonus: Ordnernamen einbeziehen, `%artist%/%album%/%track% - %title%`

**All in One**
Makro über Nummerierung → Schreibweise → Dateibenennung → Speichern.
Reine Verkettung, keine eigene Logik.

### 4.5 Coverbilder

- Anzeige aller eingebetteten Bilder mit Vor/Zurück
- Hinzufügen per Drag & Drop oder Dateiauswahl, **ersetzend oder zusätzlich**
- Bildtyp je Bild wählbar (Vorderseite, Rückseite, Booklet-Seite, Tonträger …).
  Ein eingescanntes Booklet gehört als `Leaflet Page` ins Tag, nicht als
  zweites `Front Cover` — Abspielprogramme unterscheiden das. Beim Anhängen
  ersetzt ein Bild deshalb nur ein vorhandenes **desselben** Typs.
- Entfernen, einzeln oder alle
- **Auf alle ausgewählten Tracks anwenden** — der häufigste Fall
- Export als Datei, optional als `folder.jpg` im Albumordner
- Größenanpassung **je Bild beim Einfügen**, nicht als globale Voreinstellung.
  Der Einfüge-Dialog zeigt Vorschau, freie Pixelgröße, Format und Qualität —
  und die **tatsächliche** Dateigröße, nicht eine geschätzte. Sie zu messen
  kostet bei Coverformaten wenige Millisekunden.

  Hintergrund: Ein 4000×4000-PNG in jedem Track bläht ein Album um 200 MB auf.
  Eine globale Voreinstellung trifft es aber je Bild nie — wer seine Cover
  ohnehin auf 500×500 und unter 100 KB bringt, braucht sie nicht, und wer ein
  einzelnes Riesenbild einfügt, will genau dort entscheiden.

- Ein Bild, das weder skaliert noch umgewandelt werden muss, geht
  **byte-identisch** ins Tag. Kein Neupacken, kein Qualitätsverlust.

- Beim Stapel-Konvertieren (§5) gibt es keinen Moment zum Fragen, deshalb
  wandert das Coverbild dort unangetastet in die neue Datei.

### 4.6 Nachschlagen — MusicBrainz und Discogs

**Zwei Quellen, eine Oberfläche.** Der Unterschied ist grundsätzlich: Ein
Ripper wie XLD hat die **Disc ID** aus dem Inhaltsverzeichnis der CD und macht
damit einen exakten Schlüsselzugriff — kein Raten, keine Anmeldung. Lose
Dateien haben so einen Fingerabdruck nicht, dort bleibt nur die **Textsuche**.
Und genau die sperrt Discogs hinter einen Token; der Abruf eines bekannten
Releases über seine ID geht auch ohne (nachgeprüft).

| | Token | Stärken | Grenzen |
|---|---|---|---|
| MusicBrainz | nein | offen, sofort nutzbar, Cover Art Archive | nur Genres, keine Styles; max. 1 Anfrage/s |
| Discogs | ja | bessere Coverbilder, `style` statt nur `genre` | Suche nur mit Token |

Vorgabe ist MusicBrainz, solange kein Token hinterlegt ist. Beide Quellen
werden auf ein gemeinsames Modell (`LookupRelease`, `LookupTrack`) abgebildet —
Zuordnung, Feldauswahl und Übernahme kennen den Unterschied nicht.

**MusicBrainz-Eigenheiten**
- Verlangt einen User-Agent mit Anwendungsname und Kontakt; ein allgemeiner
  wird geblockt.
- Höchstens **eine Anfrage pro Sekunde**, sonst 503. Ein 503 ist dort keine
  Störung, sondern die Bitte um Geduld — der Client wiederholt mit wachsendem
  Abstand, statt den Vorgang abzubrechen.
- Künstler stehen in `artist-credit` mit `joinphrase`; der gutgeschriebene
  Name (`name`) hat Vorrang vor dem kanonischen (`artist.name`).
- Mehrfachtonträger stecken in `media[]`, die Discnummer ist `medium.position`.

### 4.6.1 Discogs

**Auth:** Personal Access Token, vom Nutzer in den Settings eingetragen,
im **Keychain** abgelegt. Kein OAuth-Flow — für eine Desktop-App ohne Server
unnötig kompliziert.

**Pflicht:** eigener User-Agent im Format
`Sleeve/1.0 +https://github.com/NeonRost/Sleeve`. Ohne den gibt es 403.
Rate-Limit 60/min authentifiziert — Token-Bucket im Netzwerk-Layer, der das
einhält, statt auf 429 zu reagieren.

**Ablauf** („Album nachschlagen", ein Blatt, keine Stufen mehr)
1. Tracks auswählen (typisch: ein Album)
2. Suchbegriffe aus vorhandenen Tags oder Ordnernamen raten — und **gleich
   suchen**, beim Öffnen wie beim Wechsel der Quelle
3. Links die Suchmaske: Interpret / Album / Jahr / Kat.-Nr.
4. Darunter die Treffer mit Thumbnail, Label, Jahr, Format, Land
5. Ein Klick auf einen Treffer lädt das Album nach **rechts** — ein anderer
   Klick ersetzt es. Kein „Zurück": Suche und Album stehen nebeneinander
6. **Zuordnung:** je Datei eine Zeile — Datei, zugeordneter Track (als
   Aufklappmenü tauschbar), dessen Dauer, die Dauer der Datei mit
   Abweichung. Über 3 s orange. Dazu „alles um eins verschieben". Der
   wichtigste Teil — automatisches Matching liegt bei Live-Alben,
   Bonustracks und Doppel-CDs regelmäßig daneben; die Dauer zeigt es, auch
   wenn die Titel passen
7. Feldauswahl unter „Übernehmen", bei Discogs mit der Wahl Genre/Style
8. Fuß: „12 von 12 Dateien zugeordnet", mit Warnung bei fehlenden
   Zuordnungen oder orangen Zeilen
9. Übernahme in den **Editor-Zustand**, nicht direkt auf Platte

**Ein Blatt, zwei Einsätze.** „Titel nachschlagen" im Track Splitter (§7.12)
ist aus denselben Teilen gebaut (`ReleaseSearch`, `Views/Lookup/LookupParts`):
Kopf mit Titel und „Quelle", links Suche, rechts Albumkopf und Vergleich,
darunter „Übernehmen", unten Status, Abbrechen, Anwenden. Gleiche
Bezeichnungen, gleiche Toleranz (`LookupComparison.tolerance`, 3 s), gleiche
Vorgabe für die Quelle. Vorher hießen die Felder hier „Albumtitel" und dort
„Album", die Spalte hieß „Discogs-Tracks" auch bei MusicBrainz, und nur der
Splitter suchte von selbst.

Solange ein Suchfeld den Fokus hat, sucht Return; sonst wendet es an. Ohne
diese Weiche schlösse Return in einem Suchfeld das Blatt, sobald rechts ein
Album steht.

**Steuerzeichen in den Antworten.** Discogs liefert in Freitextfeldern wie
`notes` rohe `\r`/`\n` mitten im String — nach JSON-Standard unzulässig.
`JSONDecoder` prüft dabei **faul**: er stolpert nur, wenn ein deklariertes Feld
die kaputte Zeichenkette auch liest. Ein Modell ohne `notes` kommt heute durch,
bricht aber, sobald jemand das Feld ergänzt — und dann nur bei manchen Releases.
Deshalb werden die Bytes grundsätzlich vor dem Dekodieren begradigt
(`JSONSanitizer`), statt darauf zu wetten, welche Felder im Modell stehen.

**Discogs-Eigenheiten**
- `genre` und `style` sind getrennt. `style` ist meist das Gewünschte
  ("Melodic Death Metal" statt "Rock"). Konfigurierbar, oder beide kombiniert.
- Tracklisten enthalten Index-Tracks und Überschriften ohne Position —
  beim Matching rausfiltern
- Künstlernamen haben Disambiguierungs-Suffixe: `Nirvana (2)`.
  Regex zum Entfernen: ` \(\d+\)$`
- Mehrere Künstler stehen in `artists[]` mit `join`-Feldern — zusammensetzen,
  nicht nur den ersten nehmen

### 4.7 Music.app

- Ausgewählte Tracks der Music-App hinzufügen
- ScriptingBridge oder `NSAppleScript`
- `NSAppleEventsUsageDescription` im Info.plist,
  `com.apple.security.automation.apple-events` in den Entitlements
- Bewusst klein halten, reines Convenience-Feature

---

## 5. Modus „Konvertieren" (Version 1.1)

**Der Verkaufsgrund:** Generische Konverter zerschießen Metadaten — Album-
Interpret weg, Cover als 6-MB-PNG, Disc-Nummer fehlt. Sleeve hat die
TagLib-Schicht bereits und schreibt die Tags nach der Konvertierung korrekt
neu. Der Pitch ist nicht „kann auch konvertieren", sondern „konvertiert, ohne
dass du danach nochmal taggen musst".

**UI:** Zielformat, Qualität/Bitrate, Zielordner, Vorlage für Dateinamen
(dieselbe Pattern-Engine), Checkbox „Originale behalten".

**Formate:** MP3 (LAME), FLAC, AAC, ALAC, Opus, Vorbis, WAV/AIFF

**Ablauf je Datei**
1. Tags vor der Konvertierung aus dem Quellfile lesen
2. ffmpeg mit `-map_metadata -1` aufrufen — ffmpegs eigene Tag-Übertragung
   bewusst abschalten, sie ist unzuverlässig über Formatgrenzen hinweg
3. Tags anschließend selbst per TagLib schreiben, inklusive Cover
4. Cover unverändert übernehmen — skaliert wird je Bild im Tag-Modus (§4.5)

**Encoder-Wahl je Format.** Es wird der erste verfügbare Kandidat genommen:
MP3 `libmp3lame`, AAC `aac_at` vor `aac` (AudioToolbox ist lizenziert, und ein
LGPL-Build hat oft gar keinen brauchbaren AAC-Encoder), ALAC `alac` vor
`alac_at` (offen und patentfrei, der native Encoder ist verlässlicher), FLAC
`flac`, Opus `libopus` vor `opus`, Vorbis `libvorbis` vor `vorbis`, WAV
`pcm_s16le`, AIFF `pcm_s16be`. Die nativen Opus- und Vorbis-Encoder gelten
ffmpeg als experimentell und brauchen zusätzlich `-strict -2`.

`-map_metadata -1` allein reicht nicht: das Coverbild ist ein Videostream, kein
Metadatum. Ohne `-vn` wandert es unskaliert mit.

Konvertierung als serielle Queue mit Fortschritt, abbrechbar. Bei mehreren
Kernen zwei bis drei parallele ffmpeg-Prozesse, nicht mehr — Plattendurchsatz
ist meist der Flaschenhals, nicht die CPU.

---

## 6. Modus „Rippen" (Version 1.2)

**Korrigiert nach Messung am Gerät.** Die erste Fassung dieses Abschnitts ging
davon aus, dass der Weg über die gemounteten `.aiff` genügt und Fehlerkorrektur,
Leseversatz und Prüfung deshalb entfallen. Diese Annahme war falsch: macOS gibt
den Rohzugriff ohne Fremdbibliothek und ohne Sonderrechte her. Der Rohweg ist
umgesetzt, weil der `.aiff`-Weg Versatzkorrektur und Mehrfachlesen
**prinzipbedingt ausschließt** — das CDDA-Dateisystem versteckt genau die Ebene,
auf der Ripper arbeiten. Nachrüsten ginge nicht, nur neu anfangen.

### 6.1 Technischer Ansatz

Rohzugriff über die ioctls aus `<IOKit/storage/IOCDMediaBSDClient.h>`.

**Rechte:** Der Geräteknoten gehört dem angemeldeten Benutzer
(`cr--r----- <benutzer> operator /dev/rdisk4`). Kein root, kein Helfer-Dienst, keine
Entitlements. Der Sandkasten ist ohnehin aus (§2.2).

**Zeichengerät, nicht Blockgerät** (`/dev/rdiskN`): gepuffert würde der Cache
wiederholte Leseversuche beantworten, statt die Scheibe zu fragen — der sichere
Modus wäre wertlos.

| ioctl | wofür |
|---|---|
| `DKIOCCDREADTOC` | Inhaltsverzeichnis, Format 5 liefert CD-TEXT |
| `DKIOCCDREAD` | rohe CDDA-Sektoren zu 2352 Byte |
| `DKIOCCDREADISRC` / `…MCN` | ISRC je Spur, Barcode der Scheibe |
| `DKIOCCDGETSPEED` / `…SET…` | Lesegeschwindigkeit |

Die TOC gibt es einfacher: als IOKit-Eigenschaft `TOC` am `IOCDMedia`-Objekt,
ohne das Gerät zu öffnen.

#### 6.1.1 Fallstricke

**Swift sieht die `_IOWR`-Makros nicht.** Fehlermeldung:
`macro 'DKIOCCDREAD' unavailable: structure not supported` — weil `_IOWR` die
Größe eines C-Structs einrechnet. Dieselbe Stolperstelle wie beim
TagLib-Bildmakro. Lösung: `Vendor/cdshim/` mit einem Header, der die Werte als
Konstanten herüberreicht. Die Structs selbst sieht Swift von sich aus.

**`bufferLength` beim Rücksprung prüfen, nicht nur den Rückgabewert.** Das
Test-Laufwerk (ASUS BW-16D1X-U) meldet auf die Anfrage nach Nutzdaten *und*
C2-Zeigern Erfolg und füllt 1176 von 10584 Byte. Wer das nicht prüft, schreibt
uninitialisierten Speicher als Audio in die Datei.

**C2 ist nicht verlässlich, und keine Vorabprüfung reicht.** Gemessen an einem
Gerät: die Vorabprüfung an Spur 1 bestanden, mitten in Spur 3 dann 6468 statt
15876 Byte. Dieselbe Anfrage liefert mal die volle Menge, mal ein Achtel. Daraus
folgen zwei Ebenen:

1. `CDDrive.supportsC2` prüft an drei Stellen mit drei Blockgrößen und
   vergleicht **den Inhalt** gegen ein gewöhnliches Lesen — die gemeldete
   Länge allein genügt nicht.
2. `CDReader` gibt im laufenden Betrieb nach: ein unbrauchbares C2-Lesen
   schaltet C2 für den Rest des Durchgangs ab, statt abzubrechen. Das
   Protokoll vermerkt es.

**ISRC nur als Satz lesen, nie einzeln.** `DKIOCCDREADISRC` liefert am
Testlaufwerk für Spur 2 mal deren eigene Kennung, mal die von Spur 1 — und der
veraltete Wert kommt **stabil** zurück. Erfolglos versucht: zweimal lesen und
Übereinstimmung verlangen (beide Antworten sind dann gleich falsch), die Spur
vorher anfahren, wechselnde Lesepositionen, eine andere Spur dazwischen
abfragen. Der Q-Subchannel wäre die saubere Quelle, aber dasselbe Laufwerk
liefert auf `kCDSectorAreaSubChannelQ` Audiodaten statt Subchannel — volle
Länge gemeldet, PCM im Puffer.

Der Fehler hat aber eine Signatur: eine Spur bekommt die Kennung ihrer
Vorgängerin, im Satz steht also ein Wert doppelt — und welcher der falsche ist,
lässt sich nicht entscheiden. `readISRCs(for:)` liest deshalb alle Spuren,
verwirft den ganzen Satz bei einem Duplikat und liest neu. Über sechs
Messdurchgänge: zweimal alle vierzehn richtig, viermal verworfen, **keine
einzige falsche Kennung durchgelassen**. Eine falsche ISRC im Tag fällt
niemandem auf, eine fehlende schon.

Die **MCN** ist davon nicht betroffen und zusätzlich bestätigt: der ioctl liefert
`0885470015767`, und dasselbe steht im UPC-Feld des CD-TEXT — zwei unabhängige
Quellen derselben Scheibe.

**CD-TEXT ist Latin-1, nicht UTF-8.** Als UTF-8 gelesen wird „Großvater" zu
„Gro�vater". Der Zeichensatz steht im Size-Info-Paket (0x8F).

### 6.2 CD-Erkennung

Kette von genau nach ungenau:

1. **MusicBrainz Disc ID** — SHA-1 über TOC-Werte, Base64 mit `._-`. Trifft
   genau diese Pressung. Geprüft gegen das offizielle Rechenbeispiel
   (`49HHV7Eb8UKF3aQiNmu1GR8vKTY-`), nicht bloß behauptet.
2. **TOC-Suche** (`/discid/-?toc=…`) — unschärfer, mehrere Treffer.
3. **CD-TEXT** — steht auf der Scheibe, kostet kein Netz.
4. **Von Hand** oder unbenannt rippen und im Tag-Modus nacharbeiten.

Stufe 3 ist keine Notlösung: die Testscheibe („Peter und der Wolf", Malte Arkona
/ Dresdner Philharmonie) steht **weder** unter ihrer Disc ID **noch** unter
ihrem Barcode bei MusicBrainz, trägt aber vollständiges CD-TEXT mit Titeln,
Interpreten und Komponist. Ohne CD-TEXT wäre diese CD nicht zu identifizieren.

Nebenbei fällt die FreeDB-Kennung ab; sie steht im Protokoll.

### 6.2.1 Welche Felder die Quellen wirklich füllen

Nachgemessen, bevor ein Feld gebaut wurde — ein Eingabefeld, das nie etwas
bekommt, ist schlimmer als keins.

| Feld | CD-TEXT | MusicBrainz |
|---|---|---|
| Album, Interpret, Titel | ja | ja |
| Komponist | ja (Album und je Track) | nein |
| Interpret **je Track** | ja | ja (Track-Credits) |
| Jahr | nein | ja |
| Genre | nein | ja — **aber nur über die Release-Group** |
| CD-Nummer bei Mehrfachausgaben | nein | ja |

**Genres hängen nicht am Release.** Gemessen: selbst „Nevermind" führt am
Release keine Genres, an der Release-Group sieben. Ohne
`inc=…+release-groups` und den Rückgriff auf `releaseGroup.genres` bliebe das
Genrefeld fast immer leer. Der Disc-ID-Weg liefert die Gruppe mit.

**Der Interpret je Track ist keine Spielerei.** Auf der Testscheibe tragen vier
von vierzehn Tracks einen anderen Interpreten als das Album — Klassik und
Sampler sind voll davon. Er wandert in `artist`, während `albumArtist` der der
Scheibe bleibt.

### 6.3 Was umgesetzt ist

| Funktion | Stand |
|---|---|
| Burst und sicherer Modus | umgesetzt |
| Wiederholungen mit Mehrheitsentscheid | umgesetzt |
| Leseversatz | umgesetzt, byte-genau geprüft |
| Doppelrip mit Prüfsummenvergleich | umgesetzt |
| Lesegeschwindigkeit | umgesetzt |
| MCN, CD-TEXT | umgesetzt |
| ISRC | umgesetzt, mit Verwerfen unstimmiger Sätze — siehe §6.1.1 |
| C2 | umgesetzt, mit Rückfall — vom Testlaufwerk nicht geliefert |
| Protokoll, Cue Sheet | umgesetzt |
| Automatischer Leseversatz | **nicht** — die Modellliste gehört AccurateRip |
| AccurateRip | **offen**, siehe §6.6 |
| cdparanoia als Modus | **verworfen** — zweiter Vendor-Build ohne Mehrwert |

Der sichere Modus liest jeden Block zweimal. Weichen die Ergebnisse ab, wird bis
`maxRetries` wiederholt; zwei übereinstimmende Lesungen beenden die Sache, sonst
entscheidet eine byteweise Mehrheit. Stellen ohne echte Mehrheit gelten als
ungeklärt und stehen im Protokoll.

**Versatzkorrektur:** Ein Laufwerk mit Versatz `o` liefert auf die Anfrage nach
Position `p` das Sample `p + o`. Wer ab `start` will, fragt ab `start − o`. Vor
Sektor 0 und hinter dem Lead-Out wird mit Stille aufgefüllt.

### 6.4 Verifikation

Zwei unabhängige Gegenproben, beide in der Testsuite:

1. **Gegen macOS selbst.** Das gemountete CDDA-Dateisystem zeigt dieselben
   Spuren als AIFC (`sowt` = little-endian, Nutzdaten ab Byte 2352). Roh
   gelesen und dort gelesen stimmen byteweise überein — über den ganzen
   Durchstich einschließlich `RipEngine` und WAV-Datei.
2. **Versatz gegen sich selbst.** Ein Versatz von genau einem Sektor muss
   dasselbe ergeben wie ein um einen Sektor verschobenes Lesen; ein Versatz von
   6 Samples muss auf 24 Byte genau treffen. Beides geprüft.

Die Prüfungen am Gerät werden übersprungen, wenn keine CD eingelegt ist — sie
dürfen die Suite nicht rot färben, nur weil kein Laufwerk hängt.

### 6.5 Ausgabe

**Zielformat frei wählbar.** Gelesen wird immer roh; was daraus wird, entscheidet
die Einstellung:

- **WAV** — direkt von der Scheibe geschrieben, ffmpeg wird nicht gebraucht.
- **alles andere** — das WAV ist Zwischenstand und wird durch dieselbe Pipeline
  geschickt wie der Konvertieren-Bereich (`ConversionPlanner` +
  `ConversionQueue`, `keepsOriginals = false`). Kein zweiter Konverter, keine
  zweite Fehlerquelle. `ripBlocker` sperrt den Start, wenn ffmpeg oder der
  Encoder fehlt — mit dem Hinweis, dass WAV auch ohne geht.

Geprüft an der Testscheibe: gerippt nach FLAC, dekodiert bitgenau zu dem, was
macOS von derselben Spur liest (`MD5 2070ab26…` auf beiden Seiten).

**Dateinamen** entstehen aus demselben Muster wie beim Konvertieren
(`%track% - %title%`, Voreinstellung). Wichtig: **Muster und Tags kommen aus
derselben Quelle** — sonst heißt die Datei anders, als in ihr steht. Bleibt vom
Muster nichts übrig, weil etwa der Titel fehlt, fällt es auf die zweistellige
Tracknummer zurück.

Die fertigen Dateien landen in derselben Trackliste wie alles andere.

Daneben optional Protokoll und Cue Sheet. Das Protokoll sagt ausdrücklich, was
**nicht** geprüft wurde: ohne Abgleich gegen fremde Rips ist die Aussage eine
über Wiederholbarkeit, nicht über Richtigkeit.

#### 6.5.1 Auswerfen

`diskutil eject` genügt **nicht**. Es gibt das Medium nur logisch frei: das
Volume verschwindet aus dem Finder, das Laufwerk meldet danach „No Media
Inserted" — und die Schublade bleibt zu, die Scheibe liegt weiter drin. Am
Testgerät (ASUS BW-16D1X-U über USB) so beobachtet und nachgemessen.

Deshalb zwei Schritte in `RipEngine.eject`:

1. `diskutil unmount` — das Volume sauber freigeben, damit macOS keine
   unsaubere Entnahme meldet. Auf das Ende des Prozesses wird gewartet.
2. `drutil tray eject` — die Lade wirklich öffnen.

Nachweis, dass Schritt 2 wirkt: nach dem Auswerfen bringt `drutil tray close`
das Medium mit der typischen Anlaufzeit von rund zehn Sekunden zurück. Eine
geschlossene Lade zu schließen tut das nicht.

`drutil` spricht das voreingestellte Laufwerk an. Bei mehreren optischen
Laufwerken am selben Rechner träfe es womöglich das falsche — selten genug, um
es nicht aufzulösen.

#### 6.5.2 Laufwerk nicht unnötig wecken

`RipEngine.inspect()` ist teuer: Gerät öffnen, CD-TEXT, MCN, **jede** ISRC —
wofür jede Spur angefahren wird — und drei C2-Proben. Sekundenlange Arbeit am
Laufwerk.

Der `DiscWatcher` hängt an `AppState` und überlebt damit den Rip-Bereich. Ohne
Bremse liefe `inspect()` bei **jedem** Ein- und Aushängen irgendeines Volumes —
ein USB-Stick im Tag-Bereich würde die CD anwerfen. Der Beobachter prüft
deshalb den aktiven Modus, bevor er etwas tut; beim Wechsel in den Rip-Bereich
liest die Ansicht ohnehin frisch ein.

#### 6.5.3 Schublade schließt von allein

Kein Fehler und nicht von Sleeve: das Testlaufwerk zieht die Lade nach rund
**50 Sekunden** von selbst wieder ein. Zweimal gemessen, bei beendeter App und
mit einem Detektor, der das Laufwerk nicht anfasst (Existenz des Knotens
`/dev/diskN`, kein IOKit, keine I/O).

Der erste Messversuch zeigte fälschlich auf eine IOKit-Abfrage — weil die
Prüfung selbst `availableDrives()` aufrief und damit genau das tat, was sie
untersuchen sollte. Ein Detektor, der Teil des Verdachts ist, taugt nicht.

#### 6.5.4 Formularzeilen: was `Form` erzwingt

Zwei Eigenheiten, beide gemessen statt hergeleitet — und beide nicht durch
Nachdenken zu finden:

**Der Inhaltsplatz einer Form-Zeile ist rechtsbündig und bekommt nur seine
Wunschbreite.** Bei einem Textfeld wächst die mit dem Inhalt. Folge: jedes
Titelfeld eine andere Breite, der Text rechts angeschlagen, und ein langer
Titel sprengt die Zeilenhöhe. `frame(maxWidth: .infinity)` hilft nicht — weder
am Feld noch an der umgebenden `HStack`.

Abhilfe: die Zeile in den **Beschriftungs**-Platz legen, der ist linksbündig
und lässt den Inhalt die Breite füllen. Die Dauer wandert in den Inhaltsplatz.

**`.textFieldStyle(.roundedBorder)` setzt seine eigene Breite durch** und
ignoriert `frame(maxWidth:)`. Wo Felder gleich breit sein sollen, wird die
Optik selbst gezeichnet (schlichtes Feld auf abgerundetem Hintergrund) — so
macht es die Trackliste ohnehin schon.

Dasselbe Muster in klein bei den beschrifteten Feldern: `LabeledContent`
klappt den Inhalt unter die Beschriftung, sobald dessen Wunschbreite nicht
mehr passt. Deshalb dort eine feste Beschriftungsspalte (`Row`).

#### 6.5.5 Bedienung

Zwei Dinge stehen bewusst **nicht** im Formular:

- **Der Startknopf** sitzt links in der Werkzeugleiste, an derselben Stelle, an
  der die anderen Modi „Speichern" zeigen. Unten in einem langen Formular
  scrollt der wichtigste Knopf aus dem Bild.
- **Der Fortschritt** steht in der Fußzeile. Im Formular verschwindet er genau
  dann, wenn man die Trackliste durchsieht — also wenn man ihn sehen will.

Im Formular selbst: Kästchen statt Schalter bei der Trackauswahl, kurze
Beschriftungen mit Erklärung am Mauszeiger (ausgeschriebene Sätze werden in
Knöpfen und Auswahlmenüs abgeschnitten), und dieselbe Feldanmutung wie im
Tag-Bereich — beschriftete Zeile, Eingabefeld mit Rahmen.

### 6.9 Abbild der ganzen Scheibe

**Kein ISO.** Nachgemessen an der Testscheibe: bei Sektor 16, wo der
ISO-9660-Volume-Descriptor stünde, liegen Audio-Samples statt der Kennung
`CD001`. Eine Audio-CD trägt kein Dateisystem. Und von den 2352 Byte eines
CDDA-Sektors sind alle 2352 Audio — ein ISO-Container mit seinen 2048 Byte
Nutzdaten würde ein Achtel wegwerfen (529 MiB gegenüber 461 MiB bei dieser
Scheibe). Geschrieben wird stattdessen ein durchgehender Audiostrom plus Cue
Sheet.

**Wo es sitzt:** in der **Ablage**, nicht im Rip-Bereich. Dort wählt man Spuren
aus; ein Abbild ist immer die ganze Scheibe, die beiden schließen sich aus.
Und nicht im Sleeve-Menü — das gehört bei macOS dem Programm selbst. Die
Oberfläche ist ein Blatt am Hauptfenster, kein eigenes Fenster: der Vorgang
hängt an der eingelegten Scheibe, die das Fenster ohnehin zeigt.

Die Leseeinstellungen sind an dieselben Werte gebunden wie der Rip-Bereich.
Zwei Sätze davon wären eine sichere Fehlerquelle; dass ein Regler an zwei
Stellen auftaucht, ist dagegen üblich.

**Formate:** `bin` (roh), `wav` (roh mit Kopf), `flac` (über die bestehende
Konverter-Pipeline). Der Dateityp im Cue Sheet folgt daraus — `BINARY` für
BIN, sonst `WAVE`. Steht dort der falsche, sucht das Abspielprogramm die
Trackgrenzen um 44 Byte verschoben.

**Gelesen wird strömend.** `CDReader.readContiguous` reicht Blöcke weiter,
statt sie zu sammeln: eine CD sind rund 550 MB, die erst vollständig in den
Speicher zu legen wäre verschwendet. Die Prüfsumme wird dabei fortgeschrieben
(`CRC32.continue_`/`finish`) — geprüft, dass das Ergebnis mit der am Stück
berechneten übereinstimmt.

**Datenspuren werden abgelehnt**, nicht mitgeschrieben. Eine Datenspur roh
auszulesen ist nicht, wofür dieser Modus da ist (§6.8).

#### Welches Format wofür

Gemessen mit VLC 3.0.23 auf demselben Rechner:

| Datei | VLC wählt den Demuxer |
|---|---|
| `.bin` | `ps` (MPEG-Programmstrom) — geraten, nicht erkannt |
| `.cue` | `ps` — VLC versteht keine Cue Sheets |
| `.wav` | `wav` — richtig |

Auch `ffprobe` kann mit der rohen `.bin` nichts anfangen (`Invalid data found
when processing input`); erst mit `-f s16le -ar 44100 -ch_layout stereo`
kommen die erwarteten 20,000000 s heraus. Das ist kein Mangel des Abbilds,
sondern die Natur einer kopflosen Datei: sie sagt niemandem, was sie ist.

XLD meldet `.cue` beim System an, `.bin` nicht — man öffnet also das Cue
Sheet, nicht die Rohdatei.

Daraus folgt ein Hinweis unter der Formatwahl (`DiscImageFormat.hint`): BIN
ist zum Archivieren und Brennen, WAV und FLAC zum Hören. Ohne ihn wählt man
BIN — „roh, wie auf der CD" klingt nach der treuesten Wahl, und das ist sie
auch — und wundert sich dann, dass sich nichts abspielen lässt. Genau so kam
die Frage auf.

#### Nachweis

Ein vollständiges Abbild der Testscheibe: 236218 Sektoren, 555 584 736 Byte
plus 44 Byte WAV-Kopf, in 136 s bei Burst und Versatz +6. Anschließend drei
Spuren quer über die Scheibe (1, 7, 14) aus dem Abbild geschnitten und mit
einem frischen Einzelspur-Rip verglichen — **byteweise identisch**. `ffprobe`
meldet `pcm_s16le`, 44100 Hz, 2 Kanäle, 3149,57 s gegenüber 52:30 aus der TOC.

#### Bekannte Einschränkung

Geschrieben wird nur `INDEX 01`. Wo genau eine Pause beginnt (`INDEX 00`),
sagt die TOC nicht — dafür bräuchte es den Subchannel, den das Testlaufwerk
nicht verlässlich liefert (§6.1.1). Lückenlos bleibt das Abbild trotzdem, weil
nichts herausgeschnitten wird; nur die Pausenmarken fehlen im Cue Sheet.

### 6.10 Zurückbrennen

Über **DiscRecording**, ohne Fremdbibliothek. Die Zahlen passen ohne
Umrechnung: `kDRBlockSizeAudio` ist 2352, also genau die Sektorgröße, mit der
auch gelesen wird. Ein `DRTrack` je Spur, gefüttert von einem
`DRTrackDataProduction`-Objekt, das die Bytes aus dem Abbild holt; gebrannt
wird mit `kDRBurnStrategyCDSAO` — Session-at-once, damit die Übergänge
lückenlos bleiben.

**Adressen sind trackrelativ.** Apples Dokumentation zu
`produceDataForTrack:…atAddress:` sagt es ausdrücklich: „the sector address on
the disc **from the start of the track**". Nicht geraten, nachgelesen — ein
Irrtum hier erzeugt eine Scheibe, auf der jede Spur versetzt beginnt.

**„Unsupported" ist kein Hindernis.** Das Testlaufwerk meldet
`DRDeviceSupportLevelUnsupported`. Apples Header unterscheidet:

| Wert | Bedeutung laut Header |
|---|---|
| `…LevelNone` | „the engine does not support the device and it **cannot be used**" |
| `…LevelUnsupported` | „the device is unsupported but the engine **will try to use it anyway**" |

Nur `None` sperrt. `CDBurner.info(of:)` prüft deshalb genau darauf und nicht
auf „ist es unterstützt".

Das Laufwerk selbst kann, was gebraucht wird:
`CD-Write: -R, -RW, BUFE, CDText, Test, IndexPts, ISRC`, Strategien
`CD-TAO, CD-SAO, CD-Raw`.

### 6.10.1 Ungeprüft bis zum ersten Rohling

**Die einzige Stelle in Sleeve, die nie an echter Hardware lief.** Alles andere
ist gemessen — das Rohlesen gegen macOS' eigene Sicht, der Leseversatz auf das
Byte, das Abbild gegen frische Einzelrips. Hier fehlte die leere Scheibe.

Geprüft ist der riskantere Teil:

| Was | Wie |
|---|---|
| Cue-Sheet-Auswertung | Rundlauf: geschrieben, gelesen, alle 14 Startsektoren und Längen gegen die TOC |
| Adressrechnung des Producers | Abbild aus erkennbaren Sektoren; Adresse 5 der Spur muss Sektor 15 liefern |
| WAV-Kopf überspringen | 44 Byte Versatz in jeder Adresse |
| Dateiende | über das Ende hinaus wird nichts erfunden |
| Spurenaufbau | Summe der `DRTrack`-Längen deckt sich mit der TOC; Pause nur vor Spur 1 |
| Laufwerkserkennung | am echten Gerät |
| Ablehnung untauglicher Medien | am echten Gerät, **beide** Zweige: beschriebene Audio-CD und leerer Rohling vom falschen Typ |

Nicht geprüft: der `DRBurn`-Aufruf, das Verhalten des Laufwerks während des
Schreibens, Pufferleerläufe, das Ergebnis.

**Eine DVD hilft dabei nicht.** Eine Audio-CD ist Red Book — CD-Format,
2352-Byte-Sektoren, CDDA-Spuren, SAO. Auf DVD-Medien gibt es das nicht. Ein
leerer DVD-Rohling schließt aber einen anderen Zweig, der in der Praxis
häufiger vorkommt als der Brand selbst: **leeres Medium, falscher Typ.** An
einer leeren DVD-R gemessen:

```
Typ (roh) : DRDeviceMediaTypeDVDR      leer: 1      frei: 2297888 Blöcke
Meldung   : „Das ist eine DVD-R. Für eine Audio-CD braucht es einen
             CD-R- oder CD-RW-Rohling."
bereit    : false
```

Die frühere Fassung sagte „Das ist kein beschreibbarer CD-Rohling" — bei einem
leeren Rohling mit 4,38 GiB freiem Platz irreführend. Deshalb nennt
`CDBurner.mediaName` das Medium jetzt beim Namen. Nebenbei: die
Medientyp-Konstanten sind `CFString?` und taugen nicht als `case`-Muster in
einem `switch`.

**Beim ersten Rohling nachzuholen:**

1. Probelauf (`kDRBurnTestingKey`) — läuft der Ablauf durch, ohne zu schreiben?
2. Kommen die Fortschrittswerte sinnvoll an?
3. Echter Brand, dann die gebrannte Scheibe mit Sleeve wieder einlesen und die
   Prüfsummen je Spur gegen das Abbild halten. Das ist der eigentliche
   Nachweis — und er schließt die Adressrechnung mit ein.
4. Stimmen die Trackgrenzen auf den Frame?

Eine Stolperstelle beim Prüfen ist schon aufgefallen: **`DRMSF.frames()` ist
der Frame-Anteil einer Zeitangabe (0–74), nicht die Gesamtzahl** — dafür ist
`sectors()` da. Der erste Anlauf summierte über vierzehn Spuren 493 statt
236218. Die Prüfung hat den Irrtum gefunden, bevor er in den Brennercode
wandern konnte.

### 6.10.2 Bedienung

**Ablage → Abbild auf CD brennen…**, ein Blatt wie beim Erzeugen.

Der **Probelauf** ist der hervorgehobene Knopf, nicht der echte Brand: Laser
aus, ganzer Ablauf, Rohling bleibt unbeschrieben und beliebig oft
wiederverwendbar. Der echte Brand steht daneben und fragt nach — er ist die
einzige Funktion in Sleeve, die etwas Materielles unwiderruflich verbraucht.

Im Blatt steht sichtbar, dass dieser Teil nie an echter Hardware lief. Das
gehört in die Oberfläche und nicht nur hierher.

FLAC-Abbilder werden vorher nach WAV ausgepackt — das Laufwerk nimmt nur rohes
PCM. Die temporäre Datei verschwindet danach.

### 6.6 AccurateRip — offen

Die Datenbank gehört Illustrate. Ob ein GPLv3-Programm sie anfragen darf, ist
**vor der ersten Zeile Code** zu klären, nicht danach. Ohne sie fehlen zwei
Dinge: der Abgleich gegen fremde Rips derselben Pressung und die Modellliste für
den automatischen Leseversatz.

Der Doppelrip ersetzt den ersten Punkt teilweise — er zeigt, dass sich die
Scheibe reproduzierbar lesen lässt, aber nicht, dass der Versatz stimmt.

### 6.7 Codec-Lizenzen

Alle unproblematisch für GPLv3:

| Codec | Lage |
|---|---|
| FLAC | BSD-artig, patentfrei |
| MP3 | Patente 2017 ausgelaufen, LAME ist LGPL |
| AAC / ALAC | AudioToolbox encodet systemseitig, Apple hat lizenziert |
| Opus / Vorbis | BSD |

Falls doch irgendwann ffmpeg mitgeliefert wird: `--enable-gpl`-Build nehmen,
dann ist LAME direkt drin und die GPLv3 passt.

### 6.8 Rechtliche Designregeln

Kein Rechtsrat, nur die Punkte, die das Design bestimmen.

In Deutschland deckt §53 UrhG die Privatkopie: Kopien für den privaten Gebrauch
sind zulässig, solange die Vorlage nicht offensichtlich rechtswidrig ist. Eine
eigene gekaufte CD zu rippen fällt klar darunter.

Der kritische Punkt ist **§95a: das Umgehen wirksamer technischer
Schutzmaßnahmen** — verboten ist auch das Anbieten von Software, die das tut.
Daraus folgen zwei harte Designregeln:

1. **Nur Standard-CDDA lesen.** Normale Audio-CDs haben keinen Kopierschutz,
   das ist unkritisch. Kopiergeschützte Scheiben (ca. 2001–2006) lässt Sleeve
   mit klarer Fehlermeldung scheitern — es wird nichts umgangen. Der Code liest
   ausschließlich `kCDSectorTypeCDDA` und wertet das Control-Nibble aus;
   Datenspuren werden übersprungen, nicht ausgelesen.
2. **Keine DVDs, kein CSS, nichts in der Richtung.**

Unter diesen Regeln ist Sleeve in derselben Position wie XLD, das seit Jahren
unbehelligt existiert.

---

## 7. Track Splitter

Eine lange Aufnahme an den Stillen dazwischen in einzelne Tracks zerlegen,
ohne neu zu kodieren. **Ablage → In Tracks aufteilen…**

Stille-Erkennung und Randpuffer stammen aus dem Track Splitter in NeonRosts
Werkzeugkoffer und sind dort über längere Zeit erprobt. Übernommen wurde das
Erprobte, **nicht** die dortige Umgebung.

### 7.1 Der Kern heißt „schneide an diesen Positionen"

Nicht „finde Stille". Woher die Grenzen kommen, ist austauschbar: heute aus
der Stille, später aus einem Cue Sheet (§9.1). Sonst stünde das Cue-Einlesen
irgendwann als zweites Werkzeug daneben statt als weitere Quelle davor.

### 7.2 Was übernommen wurde und was nicht

| Aus dem Werkzeugkoffer | Lage in Sleeve |
|---|---|
| `silencedetect`-Aufruf und Auswertung | übernommen |
| Randpuffer 2 s | übernommen — Stille ganz am Anfang oder Ende ist Leerlauf |
| Vorgaben −30 dB, 0,5 s | übernommen |
| `-ss`/`-to` vor `-c copy` | übernommen |
| ffmpeg als Tag-Schreiber samt Format-Tabelle | **nicht** — Sleeve taggt mit TagLib und kann dort mehr |
| Mustersyntax `%n` / `%t` | **nicht** — Sleeve hat `%track%` und acht weitere |
| Eigener Tag-Block für Interpret, Album, Cover | **nicht** — die Stücke landen in der Trackliste, das kann der Tag-Bereich besser |

**`-c copy` erbt die Tags der Quelle.** Was die ganze Aufnahme beschreibt —
Interpret, Jahr, Genre —, darf bleiben. Was die **Quelldatei** beschreibt,
nicht, und wird nach dem Schneiden über TagLib ersetzt bzw. gelöscht:

| Tag | Warum |
|---|---|
| Titel | sonst hieße jedes Stück wie das ganze Album |
| Tracknummer | wird neu vergeben, `n/gesamt` |
| Kommentar | bei Downloads fast immer die Herkunfts-URL |

Am echten Album-Video gemessen: ohne das trugen **alle 13 Stücke**
`comment=https://www.youtube.com/watch?v=…` und den Albumtitel als Titel.

### 7.3 Grenzen finden

Drei Regeln, jede an einem echten Album gemessen und jede gegen eine erste
Fassung, die dort versagt hat. Gegengeprüft wurde an der Trackliste, die der
Uploader des Albums angegeben hat (§7.11).

**1. Nichts wird verworfen.** Die Tracks liegen lückenlos aneinander, eine
Pause gehört zum Ende des vorigen Tracks — wie bei CD-Rippern üblich. Die
erste Fassung ließ die Pausen weg, und mit ihnen alles, was leiser als die
Schwelle war: **66 s des Albums standen in keiner Datei**, darunter das leise
Intro von „Slider" (sechs Sekunden bei −35 bis −49 dB). Jetzt ergeben die
Stücke zusammen die Datei — auf die AAC-Rahmen genau.

**2. Geschnitten wird am Ende der tiefsten Stille**, nicht am Ende der
Schwellen-Stille (`cutPosition`). Die Schwelle allein trennt nicht sauber: ein
leises Intro liegt darunter und gehört trotzdem zum nächsten Stück. Bei
„LR-7" endet die digitale Null bei 32:35, danach setzt das Intro ein, das
immer wieder kurz unter −30 dB fällt — die Schwellen-Stille reichte bis 32:40.
Als Boden gilt, was höchstens 6 dB über dem Tiefsten liegt oder unter −60 dB;
gibt es mehrere Abschnitte, zählt der längste. Ohne Hüllkurve wird am Ende der
Stille geschnitten.

**3. Kurze Stücke gehen zu dem Nachbarn, dem sie näher liegen** (`thin`).
Liegen zwischen zwei langen Tracks mehrere zu kurze, bleibt von den Schnitten
dort genau einer: der an der längsten Pause.

| Fall | längste Pause | Ergebnis |
|---|---|---|
| Applaus direkt nach einem Live-Stück | danach | bleibt beim Stück |
| zerklüftetes Intro nach langer Pause („LUV") | davor | gehört zum nächsten Stück |

Die erste Fassung hängte alles an den Vorgänger — so gehörte das Intro von
„LUV" zum Track davor, 15 s daneben.

Dazu: Stillen, zwischen denen weniger als eine Sekunde klingt, gelten als eine
(`bridge`) — ein Knacken in der Pause trennt sie nicht. Am Dateianfang und
-ende gibt es nur einen Nachbarn; kurze Stücke gehen dorthin. Voreinstellung
für die Mindestlänge 10 s.

**Was keine Stille-Erkennung findet:** Übergänge ohne Pause. Bei „Lynch"
springt der Pegel um 16:33 nur von −2 auf −20 dB, mehr nicht. Dafür gibt es
„Hier teilen".

### 7.4 Album als Video

Ein heruntergeladenes „ganzes Album" ist oft ein **Video** — YouTube liefert
Bild und Ton zusammen. Solche Dateien abzuweisen wäre falsch: die Tonspur
lässt sich verlustfrei herausziehen.

`-c copy` allein genügt dafür **nicht** — nachgemessen: bei einer MP4 kopiert
es *beide* Spuren, die Stücke bleiben Videos mit h264 und AAC. Deshalb
`-map 0:a:0 -c:a copy`, und der Behälter richtet sich nach dem Tonformat
(`AudioSplitter.SourceInfo.outputExtension`): AAC und ALAC nach m4a, MP3 bleibt
MP3, Vorbis nach ogg, rohes PCM nach wav. Aus einem Video wird nie wieder ein
Video.

Nachgewiesen: die so herausgezogene Tonspur ist mit der im Video
**bitgleich** — gleiche MD5 über die Rohsamples, ohne Schnitt verglichen.
(Mit Schnitt weichen sie ab, aber das ist der bekannte Frame-Rundungseffekt
und kein Verlust.)

Bei der Analyse spart `-vn` das Dekodieren des Bildes — bei einem
stundenlangen Album-Video der Löwenanteil der Zeit.

### 7.5 Zielformat

Voreingestellt ist **wie die Quelle** — reiner Schnitt, nichts wird neu
kodiert. Die Auswahl zeigt dabei die tatsächliche Endung mit („Wie die Quelle
(M4A)"), damit man nicht raten muss.

Jedes andere Format **kodiert neu**. Bei einer verlustbehafteten Quelle ist
das ein zweiter Verlust, und das steht als Warnung in der Oberfläche, nicht im
Kleingedruckten. Gewollt ist es trotzdem manchmal — eine MP3 für den
Autoradio-Stick —, deshalb gibt es die Auswahl überhaupt.

Die Encoder-Auswahl kommt aus derselben Quelle wie beim Konvertieren
(`FFmpegTool.encoder(for:)`), samt `-strict -2` für die nativen Opus- und
Vorbis-Encoder. Fehlt der Encoder, sperrt der Knopf mit demselben Hinweis wie
im Konvertieren-Bereich.

### 7.6 Aufbau des Fensters

Ein eigenes Fenster, kein Blatt: der Splitter hängt an keiner Scheibe im
Hauptfenster, und ein Blatt lässt sich weder verschieben noch vergrößern.

```
┌──────────────────────────────────────────────────────────────┐
│ Datei · Dauer · Codec · Video                   [Auswählen…] │
│ Schwelle ─●─   Mindeststille ─●─   Kürzester Track ─●─  [Neu analysieren] │
│ ▁▃▇▅▃▁│▂▅▇▆▃│▁▃▇▇▅│ …   Übersicht, fest, scrollt nie weg      │
├────────────────────────┬─────────────────────────────────────┤
│ ▶ 01 Titel      1:33   │ Track 3 · 05:16.7 – 09:31.7    4:15 │
│ ▶ 02 Titel      3:37   │ ● Anfang [05:16.7]⇅  ● Ende [09:31.7]⇅ │
│ ▶ 03 Titel ◀    4:15   │ [   Lupe ±10 s   ]  [   Lupe ±10 s   ] │
│ …                      │ ▶ Ab Marke  ⏮ ⏭  05:12.0   Vorschau 14 s │
│                        │ Anfang hierher · Ende hierher · Hier teilen │
│                        │ Mit vorigem zusammenlegen · Zurücksetzen │
├────────────────────────┴─────────────────────────────────────┤
│ Ordner … · Format … · Dateiname … → 03.m4a                   │
│ ✓ 13 Tracks geschrieben — in der Trackliste   [In 13 Tracks aufteilen] │
└──────────────────────────────────────────────────────────────┘
```

Grundsatz, der sich schon zweimal bewährt hat (Rip-Fortschritt, Abbild): **was
man beim Arbeiten sehen muss, darf nicht wegscrollen.** Übersicht, Bearbeiter
und Meldungen stehen deshalb fest; nur die Trackliste scrollt.

### 7.7 Hüllkurve

Einmal berechnet, in fester Auflösung: ffmpeg dekodiert nach Mono mit 4000 Hz,
daraus werden **hundert Spitzenwerte je Sekunde** (10 ms je Wert). Beide
Ansichten schöpfen daraus — die Übersicht fasst viele Werte je Bildpunkt
zusammen, die Lupen wenige.

- **Spitzenwert, nicht Mittelwert** — der Mittelwert zöge kurze laute Stellen
  glatt, und genau die sucht man.
- **4000 Hz reichen** — gegen die volle Auflösung weicht die Hüllkurve um
  0,002 ab (bei 2000 Hz um 0,023). Eine Stunde ergibt 29 MB Zwischendatei
  statt 635 MB.
- **Normiert auf den lautesten Punkt der ganzen Datei**, auch in der Lupe.
  Ohne Normierung wird eine leise Aufnahme zur flachen Linie (ffmpegs `sine`
  liefert nur −18 dBFS). Normierte jede Lupe auf sich selbst, sähe ein leises
  Ausklingen so laut aus wie der Refrain — und man setzte die Grenze falsch.

Gezeichnet in drei Ebenen: Tönung (billig), Hüllkurve (teuer, `Equatable`,
nur bei neuer Datei, neuem Ausschnitt oder neuer Größe) und Marke samt
Abspielkopf (billig, zehnmal je Sekunde). Ohne die Trennung liefe bei jedem
Schritt des Abspielkopfs eine Viertelmillion Werte neu durch.

Dunkel bleibt nur, was an den Dateirändern abgeschnitten wurde — zwischen den
Tracks gibt es keine Lücken (§7.3).

### 7.8 Lupen, Marke, Grenzen

Über 45 Minuten ist ein Bildpunkt der Übersicht rund zwei Sekunden: gut zum
Orientieren, zu grob zum Schneiden. Der Bearbeiter zeigt deshalb **zwei Lupen**
von je ±10 s — auf den Anfang (grün) und das Ende (orange) des gewählten
Tracks, rund 30 ms je Bildpunkt.

**Eine Marke für das ganze Fenster** (gestrichelt). Unberührt steht sie **am
Anfang** des gewählten Tracks, auf der grünen Linie. Ein Klick in eine Lupe
oder in die Übersicht setzt sie; in der Übersicht wählt der Klick zugleich den
Track.

Über eine Grenze **hinweg** hören ist ein eigener Weg: ⏮ und ⏭ sowie der
Knopf in der Trackliste spielen ab einem Drittel der Hörprobe davor. Die erste
Fassung ließ die Marke selbst um diesen Vorlauf vor dem Anfang stehen, damit
„Ab Marke abspielen" von allein über die Grenze hörte — nicht zu erraten: wer
einen Track abspielt, erwartet ihn ab der grünen Linie.

**Grenzen sind gemeinsam.** Der Anfang von Track 3 ist das Ende von Track 2;
wer ihn verschiebt, verschiebt beides (`moveBoundary`). Verschöbe man nur eine
Seite, entstünde wieder eine Lücke, und was darin liegt, stünde in keiner
Datei. Abschneiden lässt sich nur an den Dateirändern — etwa eine Ansage vor
dem ersten Stück. Nach Teilen oder Zusammenlegen gilt der neue Stand als
Ausgangspunkt für „Zurücksetzen", sonst führte es an eine Grenze, die es nicht
mehr gibt.

Grenzen setzen, drei Wege — alle am selben Track, alle sofort in beiden
Ansichten sichtbar:

1. **Die farbige Linie in der Lupe ziehen.** Der Zeiger zeigt an, wo sie sich
   greifen lässt. Ob gezogen oder geklickt wird, entscheidet der erste
   Kontakt — sonst spränge die Geste um, sobald der Finger die Linie verlässt.
2. **„Anfang hierher" / „Ende hierher"** — nimmt, was man hört: beim Abspielen
   den roten Kopf, sonst die Marke.
3. **Zeitfeld mit Zehntelschritten** — der genaue Weg.

Dazu **„Hier teilen"** (neue Grenze an der Marke) und **„Mit vorigem
zusammenlegen"**. Erst mit beidem ist die Bearbeitung vollständig: Grenzen
können entstehen und verschwinden.

#### Hineinhören

`AVPlayer` mit einem Boundary-Observer, der nach der Probenlänge anhält, und
einem Periodic-Observer für den Abspielkopf. Kein Player: kein Scrubbing, keine
Lautstärke, keine Liste.

- Abspielen läuft **über das Trackende hinaus**, begrenzt nur von der Datei —
  sonst ließe sich die hintere Grenze nicht beurteilen.
- **Stopp von Hand übernimmt die Stelle in die Marke**, das Auslaufen der Probe
  nicht. Man arbeitet so: hören, an der richtigen Stelle stoppen, „Ende
  hierher". Liefe dagegen jede Probe weiter, marschierte die Marke bei jedem
  Abspielen ein Stück vor.
- Spielbarkeit wird **zur Laufzeit** geprüft, nicht an der Endung geraten.
  Gemessen nimmt AVFoundation alles, was der Splitter akzeptiert — auch Opus,
  das eine Endungsliste fälschlich ausgeschlossen hätte. `isPlayable` **wirft**
  bei manchen Behältern, statt `false` zu liefern.

### 7.9 Verworfene Zwischenstände

Das Fenster ist in mehreren Runden entstanden, jede am Benutzen gescheitert.
Festgehalten, damit sie niemand noch einmal baut:

| Anlauf | Warum verworfen |
|---|---|
| Langes Formular, Hüllkurve oben | scrollte weg, sobald man zu den Tracks kam — „nichts zu sehen" |
| Zwei Abspielknöpfe übereinander | verschiedene Bedeutung, nicht zu erraten |
| Laufleiste je Zeile | bewegte sich nicht mit; Stopp sprang zurück; endete am Trackende |
| Regler ±15 s je Zeile | blind — man sah nicht, wohin man schiebt; durch ziehbare Linien in der Lupe ersetzt |
| 2000 Werte fester Anzahl | 1,35 s je Wert bei 45 Minuten, für eine Lupe unbrauchbar |
| Pausen verwerfen | verwarf mit ihnen leise Intros — 66 s des Albums in keiner Datei |
| Kurzes immer an den Vorgänger | ein Intro nach langer Pause landete im falschen Track |
| Schnipsel unter 1 s verwerfen | zerschnitt das Intro von „LR-7"; ersetzt durch Zusammenfassen der Stillen |

### 7.10 Prüfen am echten Fenster

`App/DebugHooks.swift`, **nur in Debug-Builds**: Startparameter öffnen das
Fenster in einem festen Zustand, damit es sich per Bildschirmfoto prüfen
lässt.

```
Sleeve -SleeveDebugSplit <Datei> [-SleeveDebugSelect <n>]
       [-SleeveDebugPlayEnd YES] [-SleeveDebugShiftEnd <s>]
       [-SleeveDebugSplitTo <Ordner>]
```

Anlass: die Hüllkurve war als „fertig" gemeldet, geprüft war aber nur ihre
Berechnung. Gesehen hatte sie niemand. Seitdem gilt für dieses Fenster:
Aussagen über die Oberfläche nur nach einem Foto.

### 7.11 Nachweis

#### Gegenprobe an der Trackliste des Uploaders

Voreinstellungen (−30 dB, 0,5 s, 10 s). Die Angaben des Uploaders sind ganze
Sekunden und liegen meist mitten in der Pause; Sleeve setzt den Anfang dorthin,
wo die Musik einsetzt, und liegt deshalb meist eine Sekunde später.

| | Uploader | erste Fassung | jetzt |
|---|---|---|---|
| Vision | 1:35 | +2,6 s | +0,8 s |
| LUV | 18:55 | +14,9 s | +1,7 s |
| LR-7 | 32:35 | +5,4 s | +1,0 s |
| Slider | 39:30 | +5,2 s | −0,7 s |
| sieben weitere | | innerhalb 1,5 s | innerhalb 1,5 s |
| Lynch | 16:33 | nicht gefunden | nicht gefunden — keine Pause |

12 von 13 innerhalb von 1,7 s. Bei „Slider" liegt Sleeve **vor** dem Uploader:
das leise Intro beginnt bei 39:29,3, er hat gerundet. Die zusätzliche Grenze
bei 14:46 ist eine gewollte Pause mitten in „48k Rate Change[Freeze]".

#### Gebaute Datei

Der Durchstich arbeitet mit einer gebauten Datei — drei Töne zu 12 s, dazwischen
3 s Stille —, weil dort jede Grenze vorher bekannt ist. An echter Musik wäre
„stimmt ungefähr" das Beste, was sich prüfen ließe.

Gefunden werden die drei Tracks auf ±0,3 s genau, geschnitten mit der
erwarteten Länge, und Titel und Tracknummer stehen danach in der Datei.

Dazu der Durchgang am **echten Album-Video** (44:49, H.264 + AAC):

| | Ergebnis |
|---|---|
| Tracks | 13, reines AAC in `.m4a`, **kein Bild** |
| Tracknummern | `1/13` … `13/13` |
| „Slider" | beginnt mit seinem leisen Intro (−35 dB), vorher verworfen |
| Titel, Kommentar | nicht mehr von der Quelle geerbt |
| Interpret, Jahr | von der Quelle übernommen |
| Summe der Stücke | 2689,5 s bei 2689,3 s Datei — nichts verloren, +0,2 s durch AAC-Rahmen |
| Meldung | in der Fußzeile, mit „Im Finder zeigen" |

Eine Stolperstelle beim Prüfen: `Timecode.format(61.25)` ergibt `01:01.2`,
nicht `.3`. Genau `.x5` ist binär ein Gleichstand, und `%.1f` rundet dann zur
geraden Ziffer. IEEE-Verhalten, kein Fehler — festgehalten, damit es niemand
dafür hält.

### 7.12 Tracktitel von außen

**Titel nachschlagen…** öffnet ein Blatt mit drei Quellen — gebaut wie „Album
nachschlagen" beim Taggen (§4.6), mit denselben Teilen. Alle liefern eine
`TrackListing`; was man damit tun kann, ist dasselbe.

| Quelle | liefert | wann |
|---|---|---|
| MusicBrainz | Titel, **Längen**, Album, Interpret, Jahr, Genre | Alben, die dort stehen |
| Discogs (mit Token) | ebenso, Genre oder Style nach Wahl | Alben, die nur dort stehen |
| Trackliste (eingefügt) | Titel, **Startzeiten** | Album-Videos — die Liste steht fast immer in der Beschreibung |

Die zweite Quelle war nicht bestellt, ist aber die, die für den eigentlichen
Anlass trägt: das Testalbum steht **nicht** bei MusicBrainz. Gesucht mit und
ohne Interpret, mit und ohne das ∞ — MusicBrainz zerlegt „IMagination∞lenS" am
∞ und findet nur Alben namens „Lens". Das Blatt sucht beim Öffnen gleich mit
einem Vorschlag aus dem Dateinamen („Interpret - Album", ohne angehängte
Klammern wie „(Full Album)") und verweist, wenn nichts kommt, sofort aufs
Einfügen. Suche und Treffer bleiben erhalten, bis eine andere Datei kommt.

**Eingefügter Text** (`TrackListing(pasted:)`): je Zeile eine Zeitangabe,
vorn oder hinten, mit oder ohne Stunden, Nummer und Satzzeichen drumherum.
Zeilen ohne Zeit — Link, Überschrift — und Zeilen, die nach dem Entfernen der
Zeit keinen Titel haben — „(44:49)", die Gesamtlänge —, werden übergangen;
rückwärts springende Zeiten gehören nicht zur Liste. Geprüft mit genau dem
Text aus der Videobeschreibung.

**Vor dem Übernehmen** steht die Liste neben dem Gefundenen, mit Abweichung je
Zeile. Die Anzahl allein beruhigt zu früh: am Testalbum passten 13 zu 13, und
doch lag eine Grenze 106 s daneben. Der Fuß meldet deshalb auch orange Zeilen,
nicht nur eine falsche Anzahl.

**Übernehmen** wie beim Taggen: Titel, Interpret, Album, Jahr, Genre — was
die Quelle nicht liefert, ist ausgegraut (eine eingefügte Liste hat nur
Titel) — und als sechster Schalter **Grenzen**. Nicht Angehaktes bleibt, wie
es war.

**Grenzen ausrichten** (voreingestellt bei Startzeiten, bei Längen nur, wenn
die Anzahl nicht passt): jede Zeitangabe rastet an einer erkannten Stille
innerhalb von 5 s ein; liegt keine in der Nähe, gilt die Angabe. Genau so
findet die Liste, was keine Stille-Erkennung findet — Lynch bei 16:33. Aus
Längen wird fortlaufend addiert, aber jede Grenze neu vom eingerasteten
Vorgänger aus: ein Mitschnitt hat selten dieselben Pausen wie die CD, auf die
sich die Längen beziehen, und stur addiert wanderte der Fehler mit jedem Track
weiter. Nach dem Ausrichten gilt das Ergebnis als Ausgangspunkt für
„Zurücksetzen".

Album, Interpret, Jahr und Genre aus der Liste landen beim Schneiden in den
Tags. Ohne sie bleibt, was die Quelle trug.

**Ergebnis am Testalbum** mit der eingefügten Liste: 13 Dateien, benannt und
getaggt („05 - 48k Rate Change[Freeze]⇒Convert22.m4a" — Sonderzeichen bleiben),
„48k" wieder ein Track (2:25), Lynch 2:24 ab 16:33. In der Lupe zeigt sich,
dass der Übergang eine knappe halbe Sekunde **nach** 16:33 liegt: der Uploader
hat auf ganze Sekunden gerundet, ein Zug an der grünen Linie genügt.

---

## 8. Projektstruktur

```
Sleeve/
├── Sleeve.xcodeproj
├── Sleeve/
│   ├── App/
│   │   ├── SleeveApp.swift
│   │   ├── AppState.swift            // activeMode, Moduswahl
│   │   └── ModeSwitcher.swift
│   ├── Model/
│   │   ├── AudioTags.swift
│   │   ├── TrackFile.swift
│   │   ├── TrackListModel.swift      // modusübergreifend
│   │   └── Artwork.swift
│   ├── TagEngine/
│   │   ├── TagEngine.swift           // actor, TagLib-Fassade
│   │   ├── TagLibBridge.swift        // C-API, unsafe gekapselt
│   │   └── PropertyKeys.swift
│   ├── Pattern/
│   │   ├── PatternToken.swift
│   │   ├── PatternRenderer.swift     // Tags → String
│   │   └── PatternParser.swift       // String → Tags
│   ├── Lookup/
│   │   ├── LookupModels.swift        // gemeinsames Modell beider Quellen
│   │   ├── LookupService.swift       // Fassade davor
│   │   ├── JSONSanitizer.swift       // siehe §4.6.1, Steuerzeichen
│   │   ├── RateLimiter.swift
│   │   ├── DiscogsModels.swift
│   │   ├── DiscogsClient.swift
│   │   ├── MusicBrainzClient.swift
│   │   ├── KeychainStore.swift
│   │   ├── ReleaseSearch.swift       // die Suche beider Nachschlage-Blätter
│   │   ├── LookupSession.swift       // „Album nachschlagen": Zuordnung, Felder
│   │   └── ReleaseMatcher.swift
│   ├── Convert/                      // 1.1
│   │   ├── AudioFormat.swift         // Zielformate, Encoder-Kandidaten
│   │   ├── ProcessRunner.swift       // einzige Stelle, die fremde Programme startet
│   │   ├── FFmpegLocator.swift
│   │   ├── ConversionPlanner.swift   // Aufrufparameter und Zielpfade, rein rechnend
│   │   └── ConversionQueue.swift
│   ├── Rip/                          // 1.2
│   │   ├── DiscTOC.swift             // TOC, Disc ID, FreeDB — rein rechnend
│   │   ├── CDText.swift              // Latin-1, siehe §6.1.1
│   │   ├── CDDrive.swift             // einzige Stelle mit Gerätezugriff
│   │   ├── CDReader.swift            // Versatz, Burst/Sicher, C2-Rückfall
│   │   ├── RipEngine.swift           // actor, orchestriert einen Durchgang
│   │   ├── RipSettings.swift
│   │   ├── RipReport.swift           // Protokoll und Cue Sheet
│   │   └── WAVWriter.swift
│   ├── Views/
│   │   ├── TrackTableView.swift      // modusübergreifend
│   │   ├── Inspectors/
│   │   │   ├── TagInspector.swift
│   │   │   ├── ConvertInspector.swift
│   │   │   └── RipInspector.swift
│   │   ├── Popovers/
│   │   ├── About/                    // „Über Sleeve" und Lizenzen
│   │   └── Lookup/                   // LookupSheet + LookupParts (auch vom Splitter)
│   ├── Localization/  (en, de, es)
│   └── Resources/
│       ├── Sleeve.icon/          // App-Icon, erzeugt von Scripts/build-icon.sh
│       └── Licenses/             // Lizenztexte fürs Fenster „Lizenzen"
├── Vendor/
│   ├── taglib/
│   │   ├── include/taglib/    // Header
│   │   ├── lib/               // libtag.a, libtag_c.a
│   │   └── module.modulemap
│   ├── cdshim/                // löst die _IOWR-Makros auf, siehe §6.1.1
│   │   ├── CDShim.h
│   │   └── module.modulemap
│   └── src/                   // TagLib-Quellen, nicht eingecheckt
├── Scripts/
│   ├── build-taglib.sh
│   ├── run-smoketest.sh
│   └── taglib-smoketest.swift
├── Icon/                      // Icon-Entwurf: SVG-Master, Ebenen, .icns, Vorschau
├── Docs/                      // Aufträge und Notizen — bewusst NICHT in Sleeve/,
│                              // sonst landen sie als Ressource im App-Bundle
├── TestFiles/                 // §10 — selbst erzeugt, eingecheckt: die Tests brauchen sie
├── LICENSE  (GPLv3)
├── LICENSES/
│   ├── taglib-LGPL-2.1.txt
│   ├── taglib-MPL-1.1.txt
│   └── utfcpp-BSL-1.0.txt
├── README.md
└── SPEC.md
```

---

## 9. Reihenfolge

**Wochenende — so weit es kommt:**

1. **TagLib bauen, Module-Map, ein einziger Test:** Titel einer MP3 lesen und
   in die Konsole schreiben. Das zuerst. Wenn der Build-Schritt nicht sauber
   läuft, ist alles Weitere verschwendete Zeit.
2. `TagLibBridge` — lesen aller Felder für MP3, M4A, FLAC
3. Schreiben, gegen eine Testdatei-**Kopie**
4. `AppState` + `TrackListModel` + Modus-Umschalter (nur „Taggen" aktiv)
5. Trackliste + Drag & Drop
6. TagInspector mit Mehrfachauswahl und `touchedFields`-Logik
7. Speichern mit Fortschritt und Fehlersammlung

Alles ab hier ist Zugabe: Nummerierung, Schreibweise, Pattern-Engine beide
Richtungen, Coverbilder, Discogs, Music.app, Lokalisierung, Icon, Website,
Ko-fi, AlternativeTo.

Dann 1.1 Konvertieren, 1.2 Rippen.

### 9.1 Vorgemerkt, nicht gebaut

Nichts davon ist beschlossen — festgehalten ist nur, was beim Bauen zu
beachten wäre. (Abbild **erzeugen** ist inzwischen gebaut, siehe §6.9.)

| Idee | Anmerkung |
|---|---|
| **Abbild öffnen** | Eingang, kein eigener Bereich: `.cue` auf die Trackliste ziehen. |

**Der Splitter (§7) und das Cue-Einlesen sind dasselbe Werkzeug** — einmal kommen
die Schnittgrenzen aus dem Cue, einmal von Hand, einmal aus der Stille
(ffmpeg bringt `silencedetect` mit). Wer das Cue-Einlesen baut, sollte den
Kern deshalb als „schneide diese Datei an dieser Liste von Positionen"
anlegen und nicht als „lies ein Cue" — sonst steht der Splitter später als
zweites Werkzeug daneben statt als Oberfläche davor.

**Wo solche Funktionen hingehören:** in die **Ablage**, zu „Dateien
hinzufügen…" und „Zu Music hinzufügen" — nicht ins Sleeve-Menü, das bei macOS
dem Programm selbst gehört (Über, Einstellungen, Beenden). Ab etwa vier
Medienfunktionen lohnt ein eigenes Menü „Medium"; ein „Extras"-Menü ist eine
Windows-Gewohnheit.

---

## 10. Testdateien

Vor dem ersten Schreibversuch einen Ordner mit Testmaterial anlegen:

- MP3 mit ID3v2.3, ID3v2.4, ID3v1 und ganz ohne Tag
- MP3 mit mehreren APIC-Frames
- M4A aus der Music-App
- FLAC mit Vorbis-Comments
- Datei mit Umlauten und Emoji im Titel
- Schreibgeschützte Datei
- Absichtlich beschädigte Datei
- Datei mit 6-MB-Cover

Die letzten drei sind die, an denen Tagger üblicherweise sterben.

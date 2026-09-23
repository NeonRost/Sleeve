# Sleeve — App-Icon

Motiv: eine Plattenhülle links, aus deren rechter Seite eine CD zur Hälfte
herausragt. Die vier abstrahierten Zeilen auf der Hülle sind die Metadaten,
die die App schreibt — der einzige Hinweis auf die Funktion.

Vorgaben: [`../Docs/ICON-BRIEF.md`](../Docs/ICON-BRIEF.md).

---

## Dateien

| Datei | wofür | Geometrie |
|---|---|---|
| `sleeve-icon-master.svg` | Das Original, vier benannte Gruppen | mit Squircle |
| `sleeve-icon-dark.svg` | Dark-Mode-Fassung, siehe unten | mit Squircle |
| `Sleeve.icns` | Klassisches Fallback, 16–512 px je @1x und @2x | mit Squircle |
| `layers/*.svg` | Die vier Ebenen einzeln, Importquelle für Icon Composer | randlos |
| `Sleeve.icon/` | Icon-Composer-Dokument, Entwurfsstand | randlos |
| `preview-sizes.png` | Kontaktabzug zur Abnahme, hell und dunkel | mit Squircle |
| `preview-zoom.png` | Prüfansicht: kleine Größen pixelgenau vergrößert | mit Squircle |

Was es mit „mit Squircle" und „randlos" auf sich hat, steht unter
[Zwei Geometrien](#zwei-geometrien).

Die App bindet **nicht** die Fassung aus diesem Ordner ein, sondern
`Sleeve/Resources/Sleeve.icon` — dieselbe Datei, vom Skript an beide Stellen
geschrieben, damit Xcodes synchronisierte Ordnergruppe sie findet.

Nichts davon von Hand bearbeiten. Alles wird erzeugt von:

```bash
./Scripts/build-icon.sh
```

Das Skript ruft `Scripts/make-icon-svg.py` (Geometrie und Farben) und
`Scripts/make-icon-preview.py` (Kontaktabzug) auf und braucht `rsvg-convert`
(`brew install librsvg`) sowie `iconutil` aus Xcode.

---

## Zwei Geometrien

Die beiden Zielformate vertragen **nicht** dasselbe Bild:

**Klassisch (`.icns`, Master, Vorschauen)** — das Bild bringt seine Form selbst
mit: ein Squircle bei `x=100, y=100, w=824, h=824, rx=184`, alles daran
geclippt, ringsum 100 px Luft. So steht es im Auftrag, und so erwartet es
macOS von einer `.icns`.

**Icon Composer (`layers/`, `Sleeve.icon/`)** — die Ebenen müssen die volle
Leinwand füllen. Maske, Tiefe, Schatten und Glanzlicht legt macOS selbst an.
Der Inhalt ist dafür um den Faktor `1024/824 = 1.2427` um die Bildmitte
hochskaliert, der Squircle-Clip entfällt, und der eigene Schlagschatten ist
weggelassen — sonst läge er doppelt unter dem des Systems.

Wer die eingerückte Fassung als Icon-Composer-Ebene einsetzt, bekommt ein
**Icon im Icon**: macOS legt seine eigene Form außen herum an, der eigene
Squircle sitzt eingerückt darin, und dazwischen steht ein dunkler Rahmen.
Genau daran ist der erste Anlauf gescheitert.

---

## Palette

Unverändert aus der NeonRost-Palette, dieselbe wie beim MIKE-Werkzeugkoffer.

| Farbe | Verwendung |
|---|---|
| `#8FE3FF` | hellster Punkt, Verlaufsstart Hintergrund |
| `#35B4E8` | Mitte Hintergrund (38 %) |
| `#0E6EA6` | Hülle oben |
| `#0A5C8F` | Hintergrund unten |
| `#063D63` | Hülle unten, CD-Nabe |
| `#EAF7FF` | Metadatenzeilen |
| `#031F33` | Schlagschatten und Öffnungsschlitz |

Die CD ist ein eigener Verlauf quer zum Hintergrund, von unten-links nach
oben-rechts: `#FFFFFF` → `#CFEEFB` (30 %) → `#8FD4F0` (55 %) → `#E8F8FF` (78 %)
→ `#9BC9DE`.

---

## Dark-Mode-Fassung

Nach Vorgabe wird nur der hellste Verlaufsstopp entsättigt, die unteren Stopps
bleiben, und die Zeilen werden etwas kräftiger.

| | hell | dunkel |
|---|---|---|
| Hellster Verlaufsstopp | `#8FE3FF` | `#97DFF7` (Sättigung −15 %) |
| Zeile 1 | 0.92 | 1.00 |
| Zeile 2 | 0.62 | 0.68 |
| Zeile 3 | 0.40 | 0.44 |
| Zeile 4 | 0.26 | 0.29 |

Die Zeilendeckkraft steigt relativ um 10 %, bei Zeile 1 auf 1.0 begrenzt.
Der Unterschied ist bewusst zurückhaltend — mehr würde die Palette verlassen.

---

## Optische Korrektur

Rechnerisch bleiben links 50 px Luft zwischen Squircle und Hülle, rechts 69 px
zwischen CD und Squircle. Der runde CD-Rand verträgt weniger Rand als die
gerade Hüllenkante, deshalb wandert die Gruppe aus Hülle, CD und Zeilen um die
erlaubten **10 px nach rechts** — danach 60 px links, 59 px rechts. Das ist der
einzige Eingriff in die vorgegebene Geometrie.

---

## Abnahme

Geprüft am Kontaktabzug und zusätzlich rechnerisch.

| | Kriterium | Ergebnis |
|---|---|---|
| 1 | Bei 32 px sind Hülle und CD zwei getrennte Formen | erfüllt, ohne Kontrastanpassung |
| 2 | Bei 32 px mindestens zwei Zeilen als Struktur sichtbar | erfüllt — **drei** getrennte Bänder messbar, keine vereinfachte Kleinvariante nötig |
| 3 | Bei 16 px bleibt die Silhouette „Rechteck mit Kreis rechts" | erfüllt |
| 4 | Kristallfacetten ab 128 px nicht wahrnehmbar | **nachgebessert**, siehe unten |
| 5 | Schlagschatten läuft nicht über den Squircle-Rand | erfüllt, Alpha außerhalb ist exakt 0 |

## Stolperstelle: Farben in `icon.json`

Icon Composer erwartet Farben mit Farbraum-Angabe und Doppelpunkt:

```
extended-srgb:0.2078,0.7059,0.9098,1.0000
```

Ein blanker Hex-Wert wie `#35B4E8` lässt `actool` mit
`-[__NSPlaceholderArray initWithObjects:count:]: attempt to insert nil object`
abstürzen — ohne jeden Hinweis darauf, welches Feld gemeint ist. Die Umrechnung
macht `srgb()` in `Scripts/make-icon-svg.py`.

---

### Was nachgebessert werden musste

Die Facetten waren zunächst zwei scharfkantige Polygone mit Deckkraft 0.055 und
0.038. Messung: die Abweichung zum facettenlosen Rendering betrug bei 1024 px
**und** bei 128 px unverändert 11 von 255 Kanalstufen. Großflächige Formen
verlieren beim Verkleinern nichts an Amplitude — sie wären bei 128 px genauso
sichtbar geblieben wie bei 1024 px.

Die Facetten liegen jetzt hinter einer Weichzeichnung (`stdDeviation="26"`) bei
Deckkraft 0.05 und 0.032. Damit bleibt eine flächige Aufhellung von 9 von 255
Stufen, aber **keine Kante**: der größte Helligkeitssprung zwischen zwei
Nachbarpixeln liegt ab 128 px nur noch 1 Stufe über dem des reinen
Hintergrundverlaufs. Spürbar bei 1024 px, als Struktur nicht mehr erkennbar bei
128 px.

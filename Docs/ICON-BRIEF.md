# Auftrag: App-Icon für Sleeve

Erstelle das App-Icon für **Sleeve**, einen macOS-Audio-Tagger. Ergebnis sind
ein geschichtetes SVG-Master, die Icon-Composer-Ebenen und ein fertiges
`.icns` für ältere Systeme.

Lies diesen Auftrag komplett, bevor du anfängst. Die Geometrie unten ist eine
Vorgabe, keine Anregung — optische Feinkorrektur ist erlaubt, die Grundkomposition
nicht.

---

## 1. Motiv

Eine rechteckige Plattenhülle steht **links**. Aus ihrer **rechten** Seite ragt
eine CD heraus, etwa zur Hälfte sichtbar. Auf der Hülle stehen vier abstrahierte
Textzeilen — das sind symbolisch die Metadaten, die die App schreibt.

Die Zeilen sind der einzige Hinweis auf die Funktion. **Füge keine weiteren
Symbole hinzu** — kein Etikett, kein Anhänger, keine Note, kein Zahnrad, kein
Wellenform-Element. Das Icon muss bei 16 px noch lesbar sein, und jedes
zusätzliche Element zerstört genau das.

Die CD ist ein Hauptdarsteller, kein Detail: ihr Durchmesser entspricht der
vollen Höhe der Hülle.

---

## 2. Canvas und Geometrie

Arbeite auf **1024 × 1024**. Der macOS-Squircle ist ein zentriertes abgerundetes
Rechteck bei `x=100, y=100, w=824, h=824, rx=184`. Alles wird daran geclippt.

| Element | Werte |
|---|---|
| Hülle | `x=150, y=277, w=470, h=470, rx=20` |
| CD | Mittelpunkt `(620, 512)`, Radius `235` |
| CD-Nabe außen | Radius `88`, dunkelblau, Deckkraft ~0.18 |
| CD-Loch | Radius `42`, fast weiß, mit dünnem Rand |
| Öffnungsschlitz | `x=602, y=297, w=16, h=430, rx=8`, dunkel, Deckkraft ~0.45 |

**Zeilen auf der Hülle** — vier abgerundete Rechtecke, Höhe `30`, `rx=15`,
linker Anschlag `x=196`, vertikaler Abstand `56`:

| Zeile | y | Breite | Deckkraft |
|---|---|---|---|
| 1 | 400 | 330 | 0.92 |
| 2 | 456 | 238 | 0.62 |
| 3 | 512 | 286 | 0.40 |
| 4 | 568 | 164 | 0.26 |

Die abnehmende Deckkraft erzeugt Tiefe und lässt die untere Hälfte der Hülle
ruhig, damit die CD die Aufmerksamkeit behält.

**Zeichenreihenfolge:** Hintergrund → CD → Hülle → Zeilen. Die CD liegt hinter
der Hülle, deshalb ist links von `x=620` nur ihr rechter Sichelanteil zu sehen.

**Optische Korrektur, die du selbst treffen darfst:** Der rechte Rand der CD
liegt bei `x=855`, der linke Rand der Hülle bei `x=150`. Der Abstand zum
Squircle ist links `50`, rechts `69`. Verschiebe die gesamte Gruppe um bis zu
`10 px` nach rechts, wenn die Komposition dadurch ausgewogener wirkt. Prüfe das
visuell, nicht rechnerisch.

---

## 3. Farben

Das Blau ist gesetzt und stammt aus der bestehenden NeonRost-Palette (dieselbe
wie beim MIKE-Werkzeugkoffer). Nicht ändern.

```
#8FE3FF   hellster Punkt, Verlaufsstart Hintergrund
#35B4E8   Mitte Hintergrund
#0E6EA6   Hülle oben
#0A5C8F   Hintergrund unten
#063D63   Hülle unten
```

**Verläufe:**

- Hintergrund: linear von `#8FE3FF` (0 %) über `#35B4E8` (38 %) nach
  `#0A5C8F` (100 %), Richtung oben-links nach unten-rechts
- Hülle: linear von `#0E6EA6` nach `#063D63`, gleiche Richtung
- CD: silbrig mit blauem Schimmer, linear quer —
  `#FFFFFF` → `#CFEEFB` (30 %) → `#8FD4F0` (55 %) → `#E8F8FF` (78 %) →
  `#9BC9DE` (100 %). Kein Regenbogen, nur ein kühler Schimmer.
- Zeilen: `#EAF7FF` mit den Deckkraftwerten aus der Tabelle
- Glanzkante: weißer Verlauf mit Deckkraft 0.55 → 0, obere ~46 px der Hülle

**Schatten:** weicher Schlagschatten unter CD und Hülle, `dy=14`,
`stdDeviation=18`, Farbe `#031F33` bei Deckkraft 0.45.

**Kristallfacetten:** ein bis zwei sehr dezente helle Polygone im Hintergrund,
Deckkraft **maximal 0.06**. Sie sollen bei 1024 px spürbar und bei 128 px
unsichtbar sein. Wenn sie auffallen, sind sie zu stark.

---

## 4. Ebenenstruktur

Baue in sauber getrennten, benannten Gruppen. Das ist keine Kosmetik, sondern
Voraussetzung für Icon Composer:

```
background     Squircle-Füllung + Kristallfacetten
disc           CD mit Nabe und Loch
sleeve         Hüllenkörper, Glanzkante, Öffnungsschlitz
metadata       die vier Zeilen
```

Keine Gruppe darf Elemente einer anderen enthalten.

---

## 5. Lieferumfang

```
Icon/
├── sleeve-icon-master.svg        1024×1024, geschichtet, Gruppen wie oben
├── layers/
│   ├── background.svg
│   ├── disc.svg
│   ├── sleeve.svg
│   └── metadata.svg
├── sleeve-icon-dark.svg          siehe Abschnitt 6
├── Sleeve.icon/                  Icon-Composer-Dokument
├── Sleeve.icns                   klassisches Fallback
├── preview-sizes.png             Kontaktabzug, siehe Abschnitt 7
└── README.md                     welche Datei wofür, Palette dokumentiert
```

### Icon Composer

Aktuelle macOS-Versionen nutzen geschichtete Icons, die Tiefe, Spiegelung und
Dark Mode automatisch erzeugen. Das Werkzeug liegt Xcode bei. Importiere die
vier Ebenen aus `layers/` in dieser Reihenfolge und lass den Glaseffekt vom
System kommen — zeichne **keine** eigenen Glanzlichter oder Spiegelungen dafür.

### Klassisches .icns

Parallel für ältere Systeme. Rendere aus dem Master per `rsvg-convert` oder
`resvg` die Größen 16, 32, 64, 128, 256, 512, 1024 jeweils in `@1x` und `@2x`
in ein `Sleeve.iconset/`, dann:

```bash
iconutil -c icns Sleeve.iconset -o Sleeve.icns
```

Lege das als `Scripts/build-icon.sh` ins Repo, damit es reproduzierbar ist.

---

## 6. Dark-Mode-Variante

Das Blau ist stark gesättigt und leuchtet auf dunklem Dock-Hintergrund
unangenehm. Erzeuge eine zweite Fassung:

- Sättigung des hellsten Verlaufsstopps um **etwa 15 %** reduzieren
- Untere Verlaufsstopps unverändert lassen
- Deckkraft der Metadatenzeilen um etwa 10 % anheben, damit sie sich gegen den
  dunkleren Gesamteindruck behaupten

Konkrete Werte darfst du optisch bestimmen, dokumentiere sie in der README.

---

## 7. Abnahmekriterien

Rendere `preview-sizes.png` als Kontaktabzug mit dem Icon bei **1024, 256, 128,
64, 32 und 16 px**, hell und dunkel nebeneinander. Prüfe daran:

1. Bei **32 px** sind Hülle und CD noch als zwei getrennte Formen erkennbar.
   Falls nicht: Kontrast zwischen Hüllenblau und Hintergrundblau erhöhen.
2. Bei **32 px** bleiben mindestens zwei Metadatenzeilen als Struktur sichtbar.
   Falls sie verschmieren: nur die oberen zwei Zeilen behalten und deren Höhe
   leicht erhöhen. Eine vereinfachte Kleinvariante ist ausdrücklich erlaubt.
3. Bei **16 px** darf alles zu Silhouette werden — aber die Silhouette muss
   noch „Rechteck mit Kreis rechts daneben" sein, kein Blob.
4. Die Kristallfacetten sind ab 128 px nicht mehr wahrnehmbar.
5. Der Schlagschatten läuft nirgends über den Squircle-Rand hinaus.

Wenn eines der Kriterien nicht erfüllt ist, korrigiere und rendere neu, bevor
du abgibst. Melde am Ende kurz, welche Kriterien du geprüft hast und wo du
optisch nachjustieren musstest.

---

## 8. Was nicht passieren soll

- Keine zusätzlichen Symbole, siehe Abschnitt 1
- Keine Schrift im Icon, auch nicht der Name
- Keine Perspektive oder 3D-Neigung — die Hülle bleibt frontal
- Keine anderen Farben als die Palette aus Abschnitt 3
- Kein Hinweis auf Rippen oder Konvertieren. Sleeve ist in Version 1.0 ein
  Tagger; die späteren Modi teilen sich dasselbe Motiv.

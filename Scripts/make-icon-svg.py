#!/usr/bin/env python3
"""
make-icon-svg.py — erzeugt alle SVG-Quellen für das Sleeve-Icon.

Master, Einzelebenen und Dark-Variante entstehen aus derselben Geometrie,
damit sie nicht auseinanderlaufen. Vorgaben: Docs/ICON-BRIEF.md.
"""

import colorsys
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "Icon")

# Das Icon-Composer-Dokument entsteht zweimal: einmal als Entwurfslieferung in
# Icon/, einmal im App-Ordner, wo Xcodes synchronisierte Gruppe es findet und
# als App-Icon einbindet. Beide werden erzeugt, können also nicht auseinander-
# laufen — keine der beiden Fassungen von Hand bearbeiten.
ICON_BUNDLES = [
    os.path.join(ICON, "Sleeve.icon"),
    os.path.join(ROOT, "Sleeve", "Resources", "Sleeve.icon"),
]

# ── Geometrie ───────────────────────────────────────────────────────────────
CANVAS = 1024
SQ = dict(x=100, y=100, w=824, h=824, rx=184)          # macOS-Squircle
SLEEVE = dict(x=150, y=277, w=470, h=470, rx=20)
DISC = dict(cx=620, cy=512, r=235)
HUB_R, HOLE_R = 88, 42
SLOT = dict(x=602, y=297, w=16, h=430, rx=8)

# Optische Korrektur (ICON-BRIEF §2): links bleiben 50 px Luft, rechts 69.
# Der runde CD-Rand verträgt weniger Rand als die gerade Hüllenkante, die
# Gruppe wandert deshalb um das erlaubte Maximum nach rechts → 60 / 59.
SHIFT = 10

LINES = [  # y, Breite, Deckkraft
    (400, 330, 0.92),
    (456, 238, 0.62),
    (512, 286, 0.40),
    (568, 164, 0.26),
]
LINE_H, LINE_RX, LINE_X = 30, 15, 196

# ── Palette (NeonRost, unverändert) ─────────────────────────────────────────
C_LIGHTEST = "#8FE3FF"
C_MID      = "#35B4E8"
C_SLEEVE_T = "#0E6EA6"
C_BG_BOT   = "#0A5C8F"
C_SLEEVE_B = "#063D63"
C_LINE     = "#EAF7FF"
C_SHADOW   = "#031F33"


def desaturate(hex_color, amount):
    """Sättigung um `amount` (0–1) relativ absenken."""
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    r, g, b = colorsys.hls_to_rgb(h, l, s * (1 - amount))
    return "#%02X%02X%02X" % tuple(round(v * 255) for v in (r, g, b))


def srgb(hex_color):
    """Farbcodierung, die Icon Composer erwartet: Farbraum, Doppelpunkt,
       vier Komponenten. Ein blanker Hex-Wert bringt actool zum Absturz."""
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"extended-srgb:{r:.4f},{g:.4f},{b:.4f},1.0000"


# Dark Mode: nur der hellste Verlaufsstopp wird entsättigt (ICON-BRIEF §6).
C_LIGHTEST_DARK = desaturate(C_LIGHTEST, 0.15)


def line_opacity(o, dark):
    """Zeilen im Dark Mode um 10 % anheben, damit sie sich behaupten."""
    return round(min(1.0, o * 1.10), 3) if dark else o


# ── SVG-Bausteine ───────────────────────────────────────────────────────────

def defs(dark=False, need=None):
    need = need or ALL_DEFS
    lightest = C_LIGHTEST_DARK if dark else C_LIGHTEST
    out = ["  <defs>"]

    if "bg" in need:
        out.append(f'''    <linearGradient id="bgGradient" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{lightest}"/>
      <stop offset="0.38" stop-color="{C_MID}"/>
      <stop offset="1" stop-color="{C_BG_BOT}"/>
    </linearGradient>''')

    if "sleeve" in need:
        out.append(f'''    <linearGradient id="sleeveGradient" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{C_SLEEVE_T}"/>
      <stop offset="1" stop-color="{C_SLEEVE_B}"/>
    </linearGradient>''')

    if "cd" in need:
        # Quer zum Hintergrundverlauf: von unten-links nach oben-rechts.
        out.append('''    <linearGradient id="discGradient" x1="0" y1="1" x2="1" y2="0">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="0.30" stop-color="#CFEEFB"/>
      <stop offset="0.55" stop-color="#8FD4F0"/>
      <stop offset="0.78" stop-color="#E8F8FF"/>
      <stop offset="1" stop-color="#9BC9DE"/>
    </linearGradient>''')

    if "gloss" in need:
        out.append('''    <linearGradient id="glossGradient" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>''')

    if "facets" in need:
        # Die Facetten werden weichgezeichnet. Eine harte Polygonkante behält
        # beim Verkleinern ihre volle Amplitude und bleibt deshalb auch bei
        # 128 px als Kante erkennbar — genau das soll sie nicht (§7, Punkt 4).
        out.append('''    <filter id="facetBlur" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="26"/>
    </filter>''')

    if "shadow" in need:
        out.append(f'''    <filter id="softShadow" x="-25%" y="-25%" width="150%" height="150%">
      <feDropShadow dx="0" dy="14" stdDeviation="18"
                    flood-color="{C_SHADOW}" flood-opacity="0.45"/>
    </filter>''')

    if "clips" in need:
        out.append(f'''    <clipPath id="squircleClip">
      <rect x="{SQ['x']}" y="{SQ['y']}" width="{SQ['w']}" height="{SQ['h']}" rx="{SQ['rx']}"/>
    </clipPath>
    <clipPath id="sleeveClip">
      <rect x="{SLEEVE['x']}" y="{SLEEVE['y']}" width="{SLEEVE['w']}"
            height="{SLEEVE['h']}" rx="{SLEEVE['rx']}"/>
    </clipPath>''')

    out.append("  </defs>")
    return "\n".join(out)


# ── Randlose Fassung für Icon Composer ──────────────────────────────────────
#
# Zwei Zielformate, zwei Geometrien — das lässt sich nicht vermeiden:
#
#   .icns          Das Bild bringt seine eigene Squircle-Form samt Rand mit.
#                  Das ist die Vorgabe aus ICON-BRIEF §2.
#   Icon Composer  Die Ebenen müssen die volle Fläche füllen; die Squircle-
#                  Maske, den Schatten und das Glanzlicht legt macOS selbst an.
#                  Ein eingerückter Squircle in der Ebene ergibt sonst ein
#                  Icon im Icon, mit dunklem Rahmen drumherum.
#
# Der Inhalt wird dafür vom Squircle (824 px) auf die volle Leinwand
# hochskaliert und der eigene Schlagschatten weggelassen.
BLEED = CANVAS / SQ["w"]
BLEED_TRANSFORM = (f'translate({CANVAS / 2},{CANVAS / 2}) scale({BLEED:.6f}) '
                   f'translate({-CANVAS / 2},{-CANVAS / 2})')


def bleed(markup):
    """Gruppeninhalt randlos aufziehen: Squircle-Clip raus, eigener
       Schlagschatten raus, Inhalt auf die volle Leinwand skaliert."""
    markup = markup.replace(' clip-path="url(#squircleClip)"', "")
    markup = markup.replace(' filter="url(#softShadow)"', "")
    # Der Hintergrund ist kein skalierter Inhalt, sondern füllt einfach alles.
    markup = markup.replace(
        f'''<rect x="{SQ['x']}" y="{SQ['y']}" width="{SQ['w']}" height="{SQ['h']}"
          rx="{SQ['rx']}" fill="url(#bgGradient)"/>''',
        f'''<rect x="0" y="0" width="{CANVAS}" height="{CANVAS}" fill="url(#bgGradient)"/>''')
    markup = markup.replace('<g filter="url(#facetBlur)">',
                            f'<g filter="url(#facetBlur)" transform="{BLEED_TRANSFORM}">')
    return markup.replace(f'<g transform="translate({SHIFT},0)">',
                          f'<g transform="{BLEED_TRANSFORM} translate({SHIFT},0)">')


def group_background(dark=False):
    return f'''  <g id="background" clip-path="url(#squircleClip)">
    <rect x="{SQ['x']}" y="{SQ['y']}" width="{SQ['w']}" height="{SQ['h']}"
          rx="{SQ['rx']}" fill="url(#bgGradient)"/>
    <!-- Kristallfacetten: bei 1024 px spürbar, ab 128 px unsichtbar.
         Weichgezeichnet, damit keine Kante übrig bleibt, die das Verkleinern
         unbeschadet übersteht. -->
    <g filter="url(#facetBlur)">
      <polygon points="100,556 476,100 648,100 100,748" fill="#FFFFFF" opacity="0.05"/>
      <polygon points="924,262 924,486 596,924 372,924" fill="#FFFFFF" opacity="0.032"/>
    </g>
  </g>'''


def group_disc(dark=False):
    return f'''  <g id="disc" clip-path="url(#squircleClip)">
    <g transform="translate({SHIFT},0)">
      <circle cx="{DISC['cx']}" cy="{DISC['cy']}" r="{DISC['r']}"
              fill="url(#discGradient)" filter="url(#softShadow)"/>
      <circle cx="{DISC['cx']}" cy="{DISC['cy']}" r="{HUB_R}"
              fill="{C_SLEEVE_B}" opacity="0.18"/>
      <circle cx="{DISC['cx']}" cy="{DISC['cy']}" r="{HOLE_R}" fill="#F6FCFF"/>
      <circle cx="{DISC['cx']}" cy="{DISC['cy']}" r="{HOLE_R}" fill="none"
              stroke="{C_BG_BOT}" stroke-opacity="0.30" stroke-width="3"/>
    </g>
  </g>'''


def group_sleeve(dark=False):
    return f'''  <g id="sleeve" clip-path="url(#squircleClip)">
    <g transform="translate({SHIFT},0)">
      <rect x="{SLEEVE['x']}" y="{SLEEVE['y']}" width="{SLEEVE['w']}"
            height="{SLEEVE['h']}" rx="{SLEEVE['rx']}"
            fill="url(#sleeveGradient)" filter="url(#softShadow)"/>
      <!-- Glanzkante, an der Hüllenform beschnitten -->
      <rect x="{SLEEVE['x']}" y="{SLEEVE['y']}" width="{SLEEVE['w']}" height="46"
            fill="url(#glossGradient)" clip-path="url(#sleeveClip)"/>
      <!-- Öffnungsschlitz, aus dem die CD kommt -->
      <rect x="{SLOT['x']}" y="{SLOT['y']}" width="{SLOT['w']}"
            height="{SLOT['h']}" rx="{SLOT['rx']}"
            fill="{C_SHADOW}" opacity="0.45"/>
    </g>
  </g>'''


def group_metadata(dark=False):
    rows = "\n".join(
        f'      <rect x="{LINE_X}" y="{y}" width="{w}" height="{LINE_H}" '
        f'rx="{LINE_RX}" fill="{C_LINE}" opacity="{line_opacity(o, dark)}"/>'
        for y, w, o in LINES
    )
    return f'''  <g id="metadata" clip-path="url(#squircleClip)">
    <g transform="translate({SHIFT},0)">
{rows}
    </g>
  </g>'''


HEADER = (
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
    f'viewBox="0 0 {CANVAS} {CANVAS}">'
)


ALL_DEFS = ("bg", "sleeve", "cd", "gloss", "facets", "shadow", "clips")


def document(groups, dark=False, need=None):
    body = "\n".join(groups)
    return f"{HEADER}\n{defs(dark, need or ALL_DEFS)}\n{body}\n</svg>\n"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    print("  ", os.path.relpath(path, ROOT))


def main():
    print("SVG-Quellen:")

    for dark, name in ((False, "sleeve-icon-master.svg"), (True, "sleeve-icon-dark.svg")):
        write(os.path.join(ICON, name), document(
            [group_background(dark), group_disc(dark), group_sleeve(dark), group_metadata(dark)],
            dark,
        ))

    # Einzelebenen für Icon Composer — je Datei nur eine Gruppe, nichts vermischt.
    layers = {
        "background": (group_background, ("bg", "facets", "clips")),
        "disc":       (group_disc,       ("cd", "shadow", "clips")),
        "sleeve":     (group_sleeve,     ("sleeve", "gloss", "shadow", "clips")),
        "metadata":   (group_metadata,   ("clips",)),
    }
    for name, (builder, need) in layers.items():
        # Die Einzelebenen sind die Importquelle für Icon Composer und
        # deshalb randlos — identisch mit dem, was in den .icon-Bundles liegt.
        # Die eingerückte Squircle-Fassung steckt im Master und in der .icns.
        svg = document([bleed(builder(False))], dark=False, need=need)
        write(os.path.join(ICON, "layers", f"{name}.svg"), svg)
        for bundle in ICON_BUNDLES:
            write(os.path.join(bundle, "Assets", f"{name}.svg"), svg)

    # Icon-Composer-Dokument. Reihenfolge im JSON ist von vorne nach hinten.
    #
    # Farben brauchen hier zwingend eine Farbraum-Angabe mit Doppelpunkt —
    # ein Hex-Wert lässt actool mit einer nil-Exception abstürzen, ohne zu
    # sagen, welches Feld gemeint ist.
    icon_json = {
        "fill": {"automatic-gradient": srgb(C_MID)},
        "groups": [
            {
                # Vordergrund: bekommt den Systemschatten und das
                # System-Glanzlicht. Eigene Spiegelungen zeichnen wir nicht.
                "layers": [
                    {"image-name": "metadata.svg", "name": "metadata"},
                    {"image-name": "sleeve.svg", "name": "sleeve"},
                    {"image-name": "disc.svg", "name": "disc"},
                ],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "specular": True,
                "translucency": {"enabled": False, "value": 0.5},
            },
            {
                "layers": [{"image-name": "background.svg", "name": "background"}],
            },
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": ["iOS", "macOS"]},
    }
    for bundle in ICON_BUNDLES:
        write(os.path.join(bundle, "icon.json"), json.dumps(icon_json, indent=2) + "\n")

    print(f"\n  Dark-Mode-Verlaufsstopp: {C_LIGHTEST} → {C_LIGHTEST_DARK} (Sättigung −15 %)")
    print(f"  Optische Verschiebung:   +{SHIFT} px nach rechts")


if __name__ == "__main__":
    sys.exit(main())

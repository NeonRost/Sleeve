#!/usr/bin/env python3
# Copyright (C) 2026 NeonRost
# SPDX-License-Identifier: GPL-3.0-or-later
"""
make-icon-svg.py — generates all SVG sources for the Sleeve icon.

Master, individual layers and dark variant come from the same geometry, so
that they cannot drift apart. Requirements: Icon/ICON-BRIEF.md.
"""

import colorsys
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "Icon")

# The Icon Composer document is produced twice: once as the design delivery in
# Icon/, once in the app folder, where Xcode's synchronized group finds it and
# uses it as the app icon. Both are generated, so they cannot drift apart —
# do not edit either copy by hand.
ICON_BUNDLES = [
    os.path.join(ICON, "Sleeve.icon"),
    os.path.join(ROOT, "Sleeve", "Resources", "Sleeve.icon"),
]

# ── Geometry ────────────────────────────────────────────────────────────────
CANVAS = 1024
SQ = dict(x=100, y=100, w=824, h=824, rx=184)          # macOS-Squircle
SLEEVE = dict(x=150, y=277, w=470, h=470, rx=20)
DISC = dict(cx=620, cy=512, r=235)
HUB_R, HOLE_R = 88, 42
SLOT = dict(x=602, y=297, w=16, h=430, rx=8)

# Optical correction (ICON-BRIEF §2): 50 px of room remain on the left, 69 on
# the right. The round CD edge tolerates less margin than the straight sleeve
# edge, so the group moves right by the permitted maximum → 60 / 59.
SHIFT = 10

LINES = [  # y, Breite, Deckkraft
    (400, 330, 0.92),
    (456, 238, 0.62),
    (512, 286, 0.40),
    (568, 164, 0.26),
]
LINE_H, LINE_RX, LINE_X = 30, 15, 196

# ── Palette (NeonRost, unchanged) ───────────────────────────────────────────
C_LIGHTEST = "#8FE3FF"
C_MID      = "#35B4E8"
C_SLEEVE_T = "#0E6EA6"
C_BG_BOT   = "#0A5C8F"
C_SLEEVE_B = "#063D63"
C_LINE     = "#EAF7FF"
C_SHADOW   = "#031F33"


def desaturate(hex_color, amount):
    """Lower the saturation relatively by `amount` (0–1)."""
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    r, g, b = colorsys.hls_to_rgb(h, l, s * (1 - amount))
    return "#%02X%02X%02X" % tuple(round(v * 255) for v in (r, g, b))


def srgb(hex_color):
    """Color encoding Icon Composer expects: color space, colon, four
       components. A bare hex value crashes actool."""
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"extended-srgb:{r:.4f},{g:.4f},{b:.4f},1.0000"


# Dark mode: only the lightest gradient stop is desaturated (ICON-BRIEF §6).
C_LIGHTEST_DARK = desaturate(C_LIGHTEST, 0.15)


def line_opacity(o, dark):
    """Raise the lines by 10 % in dark mode, so that they hold their own."""
    return round(min(1.0, o * 1.10), 3) if dark else o


# ── SVG building blocks ─────────────────────────────────────────────────────

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
        # Across the background gradient: from bottom left to top right.
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
        # The facets are blurred. A hard polygon edge keeps its full amplitude
        # when scaled down and therefore stays recognizable as an edge even at
        # 128 px — which is exactly what it should not (§7, point 4).
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


# ── Borderless version for Icon Composer ────────────────────────────────────
#
# Two target formats, two geometries — that cannot be avoided:
#
#   .icns          The picture brings its own squircle shape including the
#                  margin. That is the requirement from ICON-BRIEF §2.
#   Icon Composer  The layers have to fill the whole area; macOS applies the
#                  squircle mask, the shadow and the highlight itself. An
#                  inset squircle in the layer otherwise makes an icon within
#                  the icon, with a dark frame around it.
#
# For that, the content is scaled up from the squircle (824 px) to the full
# canvas, and the own drop shadow is left out.
BLEED = CANVAS / SQ["w"]
BLEED_TRANSFORM = (f'translate({CANVAS / 2},{CANVAS / 2}) scale({BLEED:.6f}) '
                   f'translate({-CANVAS / 2},{-CANVAS / 2})')


def bleed(markup):
    """Stretch group content borderless: squircle clip out, own drop
       shadow out, content scaled to the full canvas."""
    markup = markup.replace(' clip-path="url(#squircleClip)"', "")
    markup = markup.replace(' filter="url(#softShadow)"', "")
    # The background is not scaled content, it simply fills everything.
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
    <!-- Crystal facets: noticeable at 1024 px, invisible from 128 px down.
         Blurred, so that no edge is left that survives scaling down
         unscathed. -->
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
      <!-- Gloss edge, clipped to the sleeve shape -->
      <rect x="{SLEEVE['x']}" y="{SLEEVE['y']}" width="{SLEEVE['w']}" height="46"
            fill="url(#glossGradient)" clip-path="url(#sleeveClip)"/>
      <!-- Opening slit the CD comes out of -->
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
    print("SVG sources:")

    for dark, name in ((False, "sleeve-icon-master.svg"), (True, "sleeve-icon-dark.svg")):
        write(os.path.join(ICON, name), document(
            [group_background(dark), group_disc(dark), group_sleeve(dark), group_metadata(dark)],
            dark,
        ))

    # Individual layers for Icon Composer — one group per file, nothing mixed.
    layers = {
        "background": (group_background, ("bg", "facets", "clips")),
        "disc":       (group_disc,       ("cd", "shadow", "clips")),
        "sleeve":     (group_sleeve,     ("sleeve", "gloss", "shadow", "clips")),
        "metadata":   (group_metadata,   ("clips",)),
    }
    for name, (builder, need) in layers.items():
        # The individual layers are the import source for Icon Composer and
        # therefore borderless — identical to what is in the .icon bundles.
        # The inset squircle version lives in the master and in the .icns.
        svg = document([bleed(builder(False))], dark=False, need=need)
        write(os.path.join(ICON, "layers", f"{name}.svg"), svg)
        for bundle in ICON_BUNDLES:
            write(os.path.join(bundle, "Assets", f"{name}.svg"), svg)

    # Icon Composer document. The order in the JSON is front to back.
    #
    # Colors here strictly need a color space with a colon — a hex value
    # crashes actool with a nil exception, without saying which field is
    # meant.
    icon_json = {
        "fill": {"automatic-gradient": srgb(C_MID)},
        "groups": [
            {
                # Foreground: gets the system shadow and the system
                # highlight. We draw no reflections of our own.
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

    print(f"\n  Dark mode gradient stop: {C_LIGHTEST} → {C_LIGHTEST_DARK} (saturation −15 %)")
    print(f"  Optical shift:           +{SHIFT} px to the right")


if __name__ == "__main__":
    sys.exit(main())

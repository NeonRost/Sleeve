#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The background of Sleeve's disk image (660x430, drawn at 3x, scaled down).

The same canvas and title layout as MIKE's and TOM's backgrounds, so the
three installers read as a family. The motif is the icon's: a disc rising
out of the bottom edge like a sun over the horizon, its grooves only hinted
at, in the blue of the icon and the website.

What the layout has to respect — taken over from MIKE, where it was found by
mounting the image and looking:

* Finder's toolbar hides roughly the bottom 65 pt, so only about the first
  365 pt are ever on screen. The disc is placed so that its top arc runs
  through the visible band below the icon labels; the rest is bleed.
* The two 160 pt icons sit at x=175 and x=485, y=165, and take x 95..255 and
  405..565 down to about y 265 with their labels. Nothing with contrast goes
  there — Finder draws the labels dark in light mode and light in dark mode,
  so the blue behind them stays in the middle.

    python3 Scripts/make-dmg-background.py      # writes Scripts/dmg-background.png
"""

import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SCALE = 3
CANVAS_W, CANVAS_H = 660, 430          # matches create-dmg's --window-size
W, H = CANVAS_W * SCALE, CANVAS_H * SCALE

# The website's blues: --blue-300 at the top, --blue-500 behind the icons,
# --blue-700 at the bottom.
SKY_TOP = (122, 186, 238)
SKY_MID = (74, 146, 214)
SKY_LOW = (32, 98, 170)
TITLE = (16, 52, 96)
SUBTITLE = (30, 74, 124)
RULE = (60, 110, 165)

# The disc: centre below the canvas, so only its upper part shows.
DISC_CX, DISC_CY = 330 * SCALE, 560 * SCALE
DISC_R = 292 * SCALE                   # top edge at y = 268, just below the labels
HOLE_R = 46 * SCALE


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


img = Image.new("RGB", (W, H))
draw = ImageDraw.Draw(img)

# ---- Sky ------------------------------------------------------------------
for y in range(H):
    t = y / H
    color = lerp(SKY_TOP, SKY_MID, t / 0.6) if t < 0.6 else lerp(SKY_MID, SKY_LOW, (t - 0.6) / 0.4)
    draw.line([(0, y), (W, y)], fill=color)

# ---- A soft glow where the disc rises ---------------------------------------
glow = Image.new("L", (W, H), 0)
ImageDraw.Draw(glow).ellipse(
    [DISC_CX - DISC_R * 1.25, DISC_CY - DISC_R * 1.25,
     DISC_CX + DISC_R * 1.25, DISC_CY + DISC_R * 1.25], fill=70)
glow = glow.filter(ImageFilter.GaussianBlur(40 * SCALE))
img = Image.composite(Image.new("RGB", (W, H), (200, 230, 252)), img, glow)

# ---- The disc -----------------------------------------------------------------
disc = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(disc)

# Body: a translucent silver-blue, lighter than the sky around it.
d.ellipse([DISC_CX - DISC_R, DISC_CY - DISC_R, DISC_CX + DISC_R, DISC_CY + DISC_R],
          fill=(214, 236, 252, 92))

# Grooves: fine rings, a little irregular in brightness, as on a pressed disc.
r = DISC_R - 10 * SCALE
i = 0
while r > HOLE_R + 34 * SCALE:
    alpha = 34 if i % 3 else 52
    d.ellipse([DISC_CX - r, DISC_CY - r, DISC_CX + r, DISC_CY + r],
              outline=(255, 255, 255, alpha), width=max(1, SCALE // 2))
    r -= (2.6 + (i % 4) * 0.7) * SCALE
    i += 1

# The clear inner ring and the hole, as on the icon.
ring_r = HOLE_R + 30 * SCALE
d.ellipse([DISC_CX - ring_r, DISC_CY - ring_r, DISC_CX + ring_r, DISC_CY + ring_r],
          fill=(160, 205, 240, 70))
d.ellipse([DISC_CX - HOLE_R, DISC_CY - HOLE_R, DISC_CX + HOLE_R, DISC_CY + HOLE_R],
          fill=(0, 0, 0, 0))

# Rim: one crisp highlight along the edge that shows.
d.ellipse([DISC_CX - DISC_R, DISC_CY - DISC_R, DISC_CX + DISC_R, DISC_CY + DISC_R],
          outline=(255, 255, 255, 150), width=int(1.6 * SCALE))

# Sheen: two wedges of light from the centre, the way a disc catches a lamp.
sheen = Image.new("RGBA", (W, H), (0, 0, 0, 0))
s = ImageDraw.Draw(sheen)
for start, span, alpha in [(-122, 16, 26), (-64, 9, 18)]:
    s.pieslice([DISC_CX - DISC_R, DISC_CY - DISC_R, DISC_CX + DISC_R, DISC_CY + DISC_R],
               start, start + span, fill=(255, 255, 255, alpha))
sheen = sheen.filter(ImageFilter.GaussianBlur(6 * SCALE))
mask = Image.new("L", (W, H), 0)
ImageDraw.Draw(mask).ellipse(
    [DISC_CX - DISC_R + 3 * SCALE, DISC_CY - DISC_R + 3 * SCALE,
     DISC_CX + DISC_R - 3 * SCALE, DISC_CY + DISC_R - 3 * SCALE], fill=255)
sheen.putalpha(Image.composite(sheen.getchannel("A"), Image.new("L", (W, H), 0), mask))

img = Image.alpha_composite(img.convert("RGBA"), disc)
img = Image.alpha_composite(img, sheen).convert("RGB")
draw = ImageDraw.Draw(img)

# ---- Title, as on MIKE and TOM ------------------------------------------------
def font(size, bold=False):
    try:
        return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size, index=1 if bold else 0)
    except OSError:
        return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)


def centered(text, f, cy, fill):
    box = draw.textbbox((0, 0), text, font=f)
    draw.text(((W - (box[2] - box[0])) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
              text, font=f, fill=fill)


centered("Sleeve", font(30 * SCALE, bold=True), 50 * SCALE, TITLE)
centered("Tag · Convert · Rip · Burn · Split", font(14 * SCALE), 82 * SCALE, SUBTITLE)
draw.line([(W / 2 - 40 * SCALE, 100 * SCALE), (W / 2 + 40 * SCALE, 100 * SCALE)],
          fill=RULE, width=max(1, SCALE // 2))

# ---- A quiet hint between the icons ---------------------------------------------
# Three small chevrons, fading towards the Applications folder.
for n, alpha in enumerate((0.55, 0.38, 0.22)):
    cx, cy, size = (312 + n * 16) * SCALE, 165 * SCALE, 7 * SCALE
    col = lerp(SKY_MID, (255, 255, 255), alpha)
    draw.line([(cx - size / 2, cy - size), (cx + size / 2, cy), (cx - size / 2, cy + size)],
              fill=col, width=int(2.2 * SCALE), joint="curve")

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dmg-background.png")
img.resize((CANVAS_W, CANVAS_H), Image.LANCZOS).save(out)
print("saved", out)

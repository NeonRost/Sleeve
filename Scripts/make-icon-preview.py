#!/usr/bin/env python3
"""
make-icon-preview.py — Kontaktabzug für die Abnahme (ICON-BRIEF §7).

Zeigt das Icon bei 1024, 256, 128, 64, 32 und 16 px, helle und dunkle Fassung
nebeneinander, jeweils in Originalgröße.

Mit --zoom entsteht zusätzlich eine Prüfansicht, in der die kleinen Größen
pixelgenau vergrößert sind — nur zum Hinsehen, nicht Teil der Lieferung.
"""

import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "Icon")
SIZES = [1024, 256, 128, 64, 32, 16]

LIGHT_BG = (242, 242, 245)
DARK_BG = (28, 28, 30)
LIGHT_FG = (60, 60, 67)
DARK_FG = (200, 200, 208)


def render(svg, size, out):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), svg, "-o", out],
                   check=True)
    return Image.open(out).convert("RGBA")


def font(size):
    for name in ("SFNSDisplay.ttf", "Helvetica.ttc", "Arial.ttf"):
        for folder in ("/System/Library/Fonts", "/System/Library/Fonts/Supplementary",
                       "/Library/Fonts"):
            path = os.path.join(folder, name)
            if os.path.exists(path):
                try:
                    return ImageFont.truetype(path, size)
                except OSError:
                    pass
    return ImageFont.load_default(size=size)


def build(zoom=False):
    master = os.path.join(ICON, "sleeve-icon-master.svg")
    dark_svg = os.path.join(ICON, "sleeve-icon-dark.svg")

    scales = {s: (8 if s == 16 else 4 if s == 32 else 2 if s == 64 else 1) for s in SIZES} \
        if zoom else {s: 1 for s in SIZES}

    margin, gap, label_h = 48, 40, 30
    with tempfile.TemporaryDirectory() as tmp:
        light = {s: render(master, s, os.path.join(tmp, f"l{s}.png")) for s in SIZES}
        dark = {s: render(dark_svg, s, os.path.join(tmp, f"d{s}.png")) for s in SIZES}

        if zoom:
            for table in (light, dark):
                for s in SIZES:
                    f = scales[s]
                    if f > 1:
                        table[s] = table[s].resize((s * f, s * f), Image.NEAREST)

        big = 1024
        small = [s for s in SIZES if s != 1024]
        small_w = sum(s * scales[s] for s in small) + gap * (len(small) - 1)
        col_w = max(big, small_w)
        small_h = max(s * scales[s] for s in small)

        width = margin * 2 + col_w * 2 + gap * 2
        height = margin * 2 + label_h + big + gap + label_h + small_h + margin

        sheet = Image.new("RGB", (width, height), LIGHT_BG)
        draw = ImageDraw.Draw(sheet)
        # Rechte Hälfte dunkel — so ist auch zu sehen, wie das Icon auf einem
        # dunklen Dock sitzt.
        split = margin + col_w + gap
        draw.rectangle([split - gap // 2, 0, width, height], fill=DARK_BG)

        title, caption = font(30), font(20)

        for index, (table, x0, fg) in enumerate((
            (light, margin, LIGHT_FG),
            (dark, split + gap // 2, DARK_FG),
        )):
            name = "Light" if index == 0 else "Dark"
            draw.text((x0, margin), name, font=title, fill=fg)

            y = margin + label_h
            sheet.paste(table[1024], (x0, y), table[1024])
            draw.text((x0, y + big + 6), "1024 px", font=caption, fill=fg)

            y = y + big + gap + label_h
            x = x0
            base = y + small_h
            for s in small:
                img = table[s]
                sheet.paste(img, (x, base - img.height), img)
                draw.text((x, base + 6), f"{s} px", font=caption, fill=fg)
                x += img.width + gap

        out = os.path.join(ICON, "preview-zoom.png" if zoom else "preview-sizes.png")
        sheet.save(out)
        print("  ", os.path.relpath(out, ROOT), f"{sheet.width}×{sheet.height}")


if __name__ == "__main__":
    build(zoom="--zoom" in sys.argv)

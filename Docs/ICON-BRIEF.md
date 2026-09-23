# Brief: app icon for Sleeve

Create the app icon for **Sleeve**, a macOS audio tagger. The result is a
layered SVG master, the Icon Composer layers and a finished `.icns` for older
systems.

Read this brief completely before starting. The geometry below is a
requirement, not a suggestion — fine optical correction is allowed, the basic
composition is not.

---

## 1. Motif

A rectangular record sleeve stands on the **left**. A CD sticks out of its
**right** side, about half of it visible. On the sleeve there are four
abstract lines of text — symbolically, the metadata the app writes.

The lines are the only hint at the function. **Add no further symbols** — no
label, no tag, no note, no gear, no waveform element. The icon has to stay
readable at 16 px, and every additional element destroys exactly that.

The CD is a main character, not a detail: its diameter equals the full height
of the sleeve.

---

## 2. Canvas and geometry

Work on **1024 × 1024**. The macOS squircle is a centered rounded rectangle at
`x=100, y=100, w=824, h=824, rx=184`. Everything is clipped to it.

| Element | Values |
|---|---|
| Sleeve | `x=150, y=277, w=470, h=470, rx=20` |
| CD | center `(620, 512)`, radius `235` |
| CD hub outer | radius `88`, dark blue, opacity ~0.18 |
| CD hole | radius `42`, almost white, with a thin rim |
| Opening slit | `x=602, y=297, w=16, h=430, rx=8`, dark, opacity ~0.45 |

**Lines on the sleeve** — four rounded rectangles, height `30`, `rx=15`, left
edge `x=196`, vertical spacing `56`:

| Line | y | Width | Opacity |
|---|---|---|---|
| 1 | 400 | 330 | 0.92 |
| 2 | 456 | 238 | 0.62 |
| 3 | 512 | 286 | 0.40 |
| 4 | 568 | 164 | 0.26 |

The decreasing opacity creates depth and keeps the lower half of the sleeve
calm, so that the CD keeps the attention.

**Drawing order:** background → CD → sleeve → lines. The CD lies behind the
sleeve, so left of `x=620` only its right crescent is visible.

**Optical correction you may make yourself:** the right edge of the CD is at
`x=855`, the left edge of the sleeve at `x=150`. The distance to the squircle
is `50` on the left and `69` on the right. Move the whole group up to `10 px`
to the right if that makes the composition more balanced. Check it visually,
not arithmetically.

---

## 3. Colors

The blue is fixed and comes from the existing NeonRost palette (the same as
for the MIKE toolbox). Do not change it.

```
#8FE3FF   lightest point, background gradient start
#35B4E8   background middle
#0E6EA6   sleeve top
#0A5C8F   background bottom
#063D63   sleeve bottom
```

**Gradients:**

- Background: linear from `#8FE3FF` (0 %) via `#35B4E8` (38 %) to `#0A5C8F`
  (100 %), direction top left to bottom right
- Sleeve: linear from `#0E6EA6` to `#063D63`, same direction
- CD: silvery with a blue shimmer, linear across —
  `#FFFFFF` → `#CFEEFB` (30 %) → `#8FD4F0` (55 %) → `#E8F8FF` (78 %) →
  `#9BC9DE` (100 %). No rainbow, just a cool shimmer.
- Lines: `#EAF7FF` with the opacity values from the table
- Gloss edge: white gradient with opacity 0.55 → 0, top ~46 px of the sleeve

**Shadow:** soft drop shadow under CD and sleeve, `dy=14`, `stdDeviation=18`,
color `#031F33` at opacity 0.45.

**Crystal facets:** one or two very subtle light polygons in the background,
opacity **at most 0.06**. They should be noticeable at 1024 px and invisible
at 128 px. If they stand out, they are too strong.

---

## 4. Layer structure

Build in cleanly separated, named groups. That is not cosmetics but a
precondition for Icon Composer:

```
background     squircle fill + crystal facets
disc           CD with hub and hole
sleeve         sleeve body, gloss edge, opening slit
metadata       the four lines
```

No group may contain elements of another.

---

## 5. Deliverables

```
Icon/
├── sleeve-icon-master.svg        1024×1024, layered, groups as above
├── layers/
│   ├── background.svg
│   ├── disc.svg
│   ├── sleeve.svg
│   └── metadata.svg
├── sleeve-icon-dark.svg          see section 6
├── Sleeve.icon/                  Icon Composer document
├── Sleeve.icns                   classic fallback
├── preview-sizes.png             contact sheet, see section 7
└── README.md                     which file for what, palette documented
```

### Icon Composer

Current macOS versions use layered icons that produce depth, reflection and
dark mode automatically. The tool comes with Xcode. Import the four layers
from `layers/` in this order and let the glass effect come from the system —
draw **no** highlights or reflections of your own for it.

### Classic .icns

In parallel for older systems. Render the sizes 16, 32, 64, 128, 256, 512,
1024 each in `@1x` and `@2x` from the master via `rsvg-convert` or `resvg`
into a `Sleeve.iconset/`, then:

```bash
iconutil -c icns Sleeve.iconset -o Sleeve.icns
```

Put this into the repository as `Scripts/build-icon.sh` so that it is
reproducible.

---

## 6. Dark mode variant

The blue is strongly saturated and glares unpleasantly on a dark Dock
background. Create a second version:

- Reduce the saturation of the lightest gradient stop by **about 15 %**
- Leave the lower gradient stops unchanged
- Raise the opacity of the metadata lines by about 10 %, so that they hold
  their own against the darker overall impression

You may determine concrete values visually; document them in the README.

---

## 7. Acceptance criteria

Render `preview-sizes.png` as a contact sheet with the icon at **1024, 256,
128, 64, 32 and 16 px**, light and dark side by side. Check on it:

1. At **32 px** sleeve and CD are still recognizable as two separate shapes.
   If not: increase the contrast between sleeve blue and background blue.
2. At **32 px** at least two metadata lines stay visible as structure. If
   they smear: keep only the top two lines and increase their height
   slightly. A simplified small variant is explicitly allowed.
3. At **16 px** everything may become a silhouette — but the silhouette must
   still be "rectangle with a circle next to it on the right", not a blob.
4. The crystal facets are no longer perceptible from 128 px down.
5. The drop shadow nowhere runs over the squircle edge.

If one of the criteria is not met, correct and render again before
delivering. At the end, report briefly which criteria you checked and where
you had to adjust optically.

---

## 8. What must not happen

- No additional symbols, see section 1
- No text in the icon, not even the name
- No perspective or 3D tilt — the sleeve stays frontal
- No colors other than the palette from section 3
- No hint at ripping or converting. Sleeve is a tagger in version 1.0; the
  later modes share the same motif.

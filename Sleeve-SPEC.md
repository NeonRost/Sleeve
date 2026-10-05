# Sleeve — audio toolbox for macOS

**Author:** NeonRost
**License:** GPLv3 or later (like MIKE)
**Goal:** a native Apple Silicon replacement for Tagr, extensible into an audio all-rounder
**Languages:** English (base), German, Spanish

---

## 1. Concept

Sleeve is a mode-based audio toolbox. What ties it together is always the
**file list**: ripping produces files, tagging edits them, converting turns
them into something else. All modes work on the same object.

The name comes from the record sleeve — the thing around the music that
labels and files it. That is exactly what the app does.

**Non-goals:** no player. No library management. No audio editor with a
waveform (that stays in MIKE).

### 1.1 Mode architecture

No Nero-style start window that forces the user to decide up front. Instead
the Resolve model: a persistent switcher in the window, the file list stays
put when switching.

```
┌─ Toolbar ────────────────────────────────────────────────┐
│  [ Tag │ Convert │ Rip ]                   mode-dependent │
├──────────────┬───────────────────────────────────────────┤
│              │                                           │
│  Inspector   │   Track list — shared by all modes,       │
│  per mode    │   stays when switching                    │
│              │                                           │
├──────────────┴───────────────────────────────────────────┤
│ + − × ⟳          │  42 songs, 7 changed                  │
└──────────────────────────────────────────────────────────┘
```

Implemented as a `Picker` with `.segmented` style, **at the far left of the
toolbar**, "Save" right next to it. Both are basic controls and present in
every mode. Everything mode-specific gathers at the **right** edge.

In the middle the switcher would be the worse choice: it takes up the middle
and pushes the other buttons into the overflow menu.

**Mode-dependent means literally mode-dependent.** Numbering, capitalization
and the pattern engine belong to tagging and have no place in the Convert
mode. Across all modes only "Save to disk" and the switcher itself remain.

The toolbar shows icon **and** label, and space is tight: sidebar, Save
button and switcher already use up a good half of the width. Hence short
labels (German compound words are merciless), no window title — the name is
in the menu bar — and fringe functions such as "Add to Music" in the menu
instead of the toolbar.

**The decisive architectural point:** `TrackListModel` is an independent,
mode-agnostic model. The inspector is merely a view selected via
`activeMode`. That way every further mode costs almost nothing later.

```swift
enum AppMode: String, CaseIterable, Identifiable {
    case tag, convert, rip
    var id: String { rawValue }
}

@Observable
final class AppState {
    var activeMode: AppMode = .tag
    let trackList = TrackListModel()     // shared by all modes
    var availableModes: [AppMode] {
        // Convert only if ffmpeg was found, Rip only with a CD in the drive
    }
}
```

Modes whose requirements are missing are not hidden but disabled with an
explanatory tooltip. Hidden features look like bugs.

**Only "Tag" is implemented in version 1.0.** The other segments are visible
but disabled and marked "Coming soon" — or hidden entirely until 1.1; that is
decided at release.

---

## 2. Technical stack

| Area | Decision |
|---|---|
| Language | Swift 6, strict concurrency |
| UI | SwiftUI, `Table` for the track list |
| Minimum | macOS 14 (Sonoma) |
| Architecture | native Apple Silicon |
| Tag engine | TagLib 2.x via the C API (`tag_c.h`), statically linked |
| Conversion | ffmpeg, **external** (not bundled) |
| CD detection | IOKit `IOCDMedia` or `drutil toc` → MusicBrainz disc ID |
| Metadata | MusicBrainz (disc ID lookup), Discogs (cover, style) |
| Network | URLSession, async/await |
| Persistence | `UserDefaults`, tokens in the keychain |

### 2.1 Integrating TagLib

No C++ interop needed. Since TagLib 2.0 the C API also covers the PropertyMap
(`ALBUMARTIST`, `COMPOSER`, `DISCNUMBER`) and complex properties (cover
pictures).

Version used: **TagLib 2.3.2**.

**Build script** (`Scripts/build-taglib.sh`, once): clones the tag, builds
arm64 static and copies headers and libraries to `Vendor/taglib/`.

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

`BUILD_BINDINGS=ON` is not optional — without it no C API is built.

**Xcode integration:**
- `Vendor/taglib/` → Header Search Paths (clang then finds the
  `module.modulemap` by itself; do **not** enter `Vendor/taglib/include/`)
- `libtag_c.a` **and** `libtag.a` → Link Binary With Libraries
- Additionally link `libz.tbd` and `libc++.tbd` (TagLib is C++ inside)
- `Vendor/taglib/module.modulemap`:

```
module CTagLib {
    header "include/taglib/tag_c.h"
    link "tag_c"    // C bindings
    link "tag"      // C++ core library
    link "z"
    link "c++"
    export *
}
```

**License:** TagLib is under LGPL 2.1 / MPL 1.1. Linking it statically into a
GPLv3 program is allowed. TagLib's sources or a link to them belong in the
distribution, with a note in `LICENSES/` and in the README. The build script
puts `LICENSES/taglib-LGPL-2.1.txt` and `taglib-MPL-1.1.txt` there
automatically.

**In the program** ("About Sleeve", a window of its own instead of the
standard panel — that one appends the build number, "Version 1.0 (1)"):
icon, name, version, a note on the missing warranty and the GPL v3 or later,
"Show License", copyright from `NSHumanReadableCopyright` ("Copyright (C)
2026 NeonRost"). "Show License" opens the **Licenses** window with the full
text of every component inside the program: Sleeve (GPL v3), TagLib (LGPL 2.1
— of the two TagLib licenses the one compatible with the GPL) and utfcpp
(Boost 1.0, part of TagLib). ffmpeg is missing there on purpose: Sleeve does
not ship it. The texts live in `Sleeve/Resources/Licenses/`; the GPL text is
the official one (SHA-256 `3972dc97…`, like `gpl-3.0.txt` at the FSF),
identical to `LICENSE`.

#### 2.1.1 Pitfalls (verified on 12 Sept 2026)

**The C API lives in a library of its own.** TagLib 2.x builds `libtag.a`
(C++) and `libtag_c.a` (C bindings) separately. `link "tag"` alone yields
undefined symbols for every `taglib_*` symbol. Link both.

**UTF-8 is the default.** `taglib_set_strings_unicode(1)` has been
superfluous since 2.0; every `char*` in and out is UTF-8. The call does no
harm, but the old rule of thumb "switch to Unicode first" is outdated.

**The legacy API is not a safe route.** `taglib_tag_comment()` and friends
silently fall back to the ID3v1 appendix when the ID3v2 frame is missing —
and that is Latin-1 by definition, without any encoding marker. In the test
the legacy API returned `Kommentar mit Ãmlaut`, the PropertyMap `Kommentar
mit Ümlaut`. Consequence: `TagLibBridge` reads and writes **exclusively**
via `taglib_property_get/set`. The legacy functions are only used where there
is no property equivalent.

**`TAGLIB_COMPLEX_PROPERTY_PICTURE` cannot be reached from Swift.** It is a
function-like C macro and Swift does not import it. To *write* cover
pictures, `TagLibBridge` has to build the `TagLib_Complex_Property_Attribute`
array by hand. *Reading* is convenient via
`taglib_picture_from_complex_property`, but that function only returns the
**first** picture — for several APIC frames the outer
`TagLib_Complex_Property_Attribute***` array has to be walked by hand.

**`ARCHS = arm64` is mandatory, not a matter of taste.** Xcode's default
(`ARCHS_STANDARD`) builds universal for macOS. Against the arm64-only vendor
build this does not fail with an error but with hundreds of
`ld: warning: ignoring file … required architecture 'x86_64'` — and a binary
without TagLib. In Debug this goes unnoticed because `ONLY_ACTIVE_ARCH = YES`
applies; only the Release build breaks. That is why `ARCHS = arm64` is in the
project configuration.

**Smoke test:** `Scripts/run-smoketest.sh` compiles
`Scripts/taglib-smoketest.swift` against the vendor build and reads every
file in `TestFiles/`, including a write round trip. Run it once after every
TagLib update.

### 2.2 Locating ffmpeg (from phase 4 on)

ffmpeg is not shipped but expected on the system — as with MIKE. So that the
Convert mode does not fail silently:

**Search order:**
1. Path from the settings, if set by the user
2. `/opt/homebrew/bin/ffmpeg` (Apple Silicon Homebrew)
3. `/usr/local/bin/ffmpeg` (Intel Homebrew / manual)
4. Search `PATH`

`PATH` alone is **not** enough — an app launched from the Finder does not
inherit the shell environment and often does not see Homebrew paths.

**If not found:** the mode stays **enterable** — locking it would be
circular, because the instructions are in exactly this section. Instead, a
blocker above the button prevents starting.

The inspector then shows a card with an explanation and copyable commands,
"Choose Manually…" for a path of one's own and "Search Again" after
installing. The instructions depend on what is on the machine:

- **Homebrew present** → just `brew install ffmpeg`
- **Homebrew missing** → first the Homebrew install command with a link to
  brew.sh, then `brew install ffmpeg`. Without this check the instructions
  would lead nowhere and the user would look for the mistake on their side.

None of it is run — the commands are there to be copied, the Terminal stays
with the user.

Once ffmpeg is found, the section moves to the **end** of the inspector:
after installation nobody cares about it any more.

**No sandbox.** Homebrew's ffmpeg is linked against dozens of dylibs under
`/opt/homebrew/lib`. A child process inherits the app's sandbox and may not
read them — dyld aborts before ffmpeg even starts. External ffmpeg and the
App Sandbox thus exclude each other. Hardened Runtime and notarization are
unaffected; the Mac App Store would be out, but it is incompatible with the
GPLv3 anyway. Should a statically linked ffmpeg ever go into the bundle, the
sandbox could be switched on again.

**Version check:** `ffmpeg -version` when found; query the available encoders
once via `ffmpeg -encoders` and cache them. An LGPL build without
`libmp3lame` cannot do MP3 — the app has to know that and say so before the
user starts a batch.

---

## 3. Data model

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
    var url: URL                      // mutable: renaming, conversion
    private(set) var original: AudioTags
    var edited: AudioTags
    var touchedFields: Set<TagField> = []   // see 4.1 — critical
    var proposedFilename: String?
    var lastError: TagError?
    var isDirty: Bool { !touchedFields.isEmpty || proposedFilename != nil }
}

@Observable
final class TrackListModel {
    var tracks: [TrackFile] = []
    var selection: Set<TrackFile.ID> = []
    // shared by all modes, survives every mode switch
}
```

### 3.1 Format mapping

| Field | ID3v2 (MP3) | MP4 (M4A) | Vorbis (FLAC) |
|---|---|---|---|
| Album artist | `TPE2` | `aART` | `ALBUMARTIST` |
| Composer | `TCOM` | `©wrt` | `COMPOSER` |
| Disc number | `TPOS` | `disk` | `DISCNUMBER` |
| Compilation | — | `cpil` | `COMPILATION` |
| Cover | `APIC` | `covr` | `METADATA_BLOCK_PICTURE` |
| Lyrics | `USLT` | `©lyr` | `LYRICS` |

`taglib_property_get(file, "ALBUMARTIST")` returns the right native key in
each case — TagLib largely does the mapping itself. Exception: cover
pictures, via `taglib_complex_property_get(file, "PICTURE")`.

---

## 4. The Tag mode (version 1.0)

### 4.1 Batch editor — the core

**Track list**
- Drag and drop of files and folders, recursive
- Columns: `#`, title, artist, album, year, duration, file name, status
- Sortable, multiple selection with Shift/Cmd, editable inline
- Clicking as in the Finder: the first click selects the row, a click into a
  cell of a row that is already selected edits it; a double click does both.
  With ⌘ or ⇧ held a click only changes the selection. Before, every cell was
  a text field and the first click started editing — a row could only be
  selected by aiming at the length, the file name or the size. Whether the
  row was selected *before* the click is remembered on mouse down, because
  the table changes the selection on that same click.
- Status column: unchanged / changed / error

**Inspector panel**
- All fields from `AudioTags`
- With several tracks selected and differing values: the placeholder
  `<Multiple values>` instead of an empty field — `<Mixed>` in the narrow
  track and disc number fields, where the long one was cut off to
  "<Multipl"
- **A field is only written if it is in `touchedFields`.** Never decide via
  a string comparison. This is exactly where Tagr regularly wrecks fields the
  user never touched: the field looks empty, so empty gets written. This is
  the single most important point of the spec.
- Autocomplete from the values of already loaded files

**Writing**
- `TagEngine` as an `actor`, all TagLib calls off the main thread
- Progress indicator from 20 files on
- Fault-tolerant per file: one broken file does not abort the batch
- Collect errors, summarize them in a sheet at the end
- **Undo:** keep an `original` snapshot per file; one session-wide undo step
  is enough. Cmd+Z has to work.
- Optional: backup copy next to the file

### 4.2 Numbering

- Number tracks in the current sort order
- Leading zeros (01 instead of 1)
- Write the total (03/12)
- Across discs or starting again per disc

### 4.3 Capitalization

- Title Case with an exception list ("of", "the", "und", "der" …),
  language-dependent
- UPPER CASE
- lower case
- Applicable to all fields or only chosen ones

### 4.3.1 Find and replace

A toolbar popover next to capitalization ("Replace"), for what capitalization
and patterns cannot do: "feat." to "ft.", removing "(Remastered 2011)",
tidying up what a download site left behind.

- Find, replace with (empty means: remove), match case, regular expression.
  In regex mode `$1` inserts the first group. Plain text goes through the
  same engine, escaped (`TextReplacement`).
- Applies to the chosen text fields of the selection (or of all tracks when
  nothing is selected), like capitalization.
- **Preview before anything happens:** the number of changes and the first
  six as old (struck through) → new; a field replaced down to nothing shows
  "cleared". An invalid regular expression is reported instead of a preview.
- Where something was replaced, doubled spaces collapse and the edges are
  trimmed — removing "(Live)" from "Song (Live)" gives "Song", not "Song ".
  Fields without a match stay exactly as they are and are not marked as
  touched (§4.1).

### 4.3.2 Fill a field

"Fill" in the toolbar — Mp3tag calls it "Format value": one field from a
pattern. Album artist = `%artist%`, title = `%track% %title%`, or the title
from the file name.

- The placeholders of the pattern engine (§4.4), plus two about the file:
  `%filename%` (the name without extension) and `%folder%` (the folder it is
  in). `FieldFormat` parses and renders.
- The result is a tag, not a file name: "/" and ":" stay, only spaces and
  separators a dropped group leaves at the edges go. A missing value takes
  the text before it along, as with file names.
- Numbers as stored ("3"); leading zeros on request.
- A track where the pattern gives nothing is left out, not cleared.
- Preview as with replacing: number of changes, the first six old → new.
  Only changed fields count as touched (§4.1).

### 4.4 Pattern engine

Both directions, the same token syntax:

```
%artist%  %albumartist%  %album%  %title%
%track%   %disc%  %year%  %genre%  %composer%
```

**Tags → file name**
- Example: `%track% - %artist% - %title%`
- Live preview in a column of its own before anything happens
- Replace invalid characters (`/`, `:`, control characters), configurable
- Missing tags: the segment including the surrounding separators is dropped,
  instead of producing `01 -  - Title`
- Collisions: append ` (2)`
- Presets can be saved

**File name → tags**
- The same pattern backwards: `%token%` becomes a named capture group,
  everything in between escaped literally → a finished regex
- Live preview as a table, non-matching rows red and skipped
- Presets: `%track% - %title%`, `%artist% - %title%`,
  `%track%. %artist% - %title%`, `%artist% - %album% - %track% - %title%`
- Bonus: include folder names, `%artist%/%album%/%track% - %title%`

**All in One**
A macro over numbering → capitalization → renaming → saving. Pure chaining,
no logic of its own.

### 4.5 Cover pictures

- Show all embedded pictures with back/forward
- Add via drag and drop or file picker, **replacing or in addition**
- Picture type selectable per picture (front, back, booklet page, medium …).
  A scanned booklet belongs in the tag as `Leaflet Page`, not as a second
  `Front Cover` — players tell the two apart. That is why, when appending, a
  picture only replaces an existing one **of the same** type.
- Remove, individually or all
- **Apply to all selected tracks** — the most common case
- Export as a file (the save panel suggests `cover.jpg` or `cover.png`); a
  dedicated `folder.jpg` in the album folder is not built
- Resizing **per picture when adding**, not as a global preset. The import
  dialog shows a preview, free pixel size, format and quality — and the
  **actual** file size, not an estimated one. Measuring it costs a few
  milliseconds for cover formats.

  Background: a 4000×4000 PNG in every track bloats an album by 200 MB. But
  a global preset never gets it right per picture — whoever brings their
  covers to 500×500 and under 100 KB anyway does not need it, and whoever
  adds a single huge picture wants to decide right there.

- A picture that needs neither scaling nor converting goes into the tag
  **byte-identical**. No re-encoding, no loss of quality.

- In batch conversion (§5) there is no moment to ask, so the cover picture
  moves into the new file untouched there.

### 4.6 Lookup — MusicBrainz and Discogs

**Two sources, one UI.** The difference is fundamental: a ripper like XLD has
the **disc ID** from the CD's table of contents and does an exact key lookup
with it — no guessing, no sign-in. Loose files have no such fingerprint; only
the **text search** remains. And that is exactly what Discogs locks behind a
token; fetching a known release by its ID works without one (verified).

| | Token | Strengths | Limits |
|---|---|---|---|
| MusicBrainz | no | open, usable right away, Cover Art Archive | genres only, no styles; max. 1 request/s |
| Discogs | yes | better cover pictures, `style` instead of just `genre` | search only with a token |

MusicBrainz is the default as long as no token is stored. Both sources are
mapped onto a common model (`LookupRelease`, `LookupTrack`) — matching, field
selection and applying do not know the difference.

**MusicBrainz quirks**
- Requires a User-Agent with application name and contact; a generic one is
  blocked.
- At most **one request per second**, otherwise 503. There, a 503 is not a
  malfunction but a request for patience — the client retries with a growing
  interval instead of aborting.
- Artists are in `artist-credit` with `joinphrase`; the credited name
  (`name`) takes precedence over the canonical one (`artist.name`).
- Multiple media are in `media[]`, the disc number is `medium.position`.

### 4.6.1 Discogs

**Auth:** personal access token, entered by the user in the settings and
stored in the **keychain**. No OAuth flow — needlessly complicated for a
desktop app without a server.

**Mandatory:** a User-Agent of its own in the format
`Sleeve/1.0 +https://github.com/NeonRost/Sleeve`. Without it there is a 403.
Rate limit 60/min authenticated — a token bucket in the network layer that
keeps within it, instead of reacting to 429.

**Flow** ("Look Up Album", one sheet, no stages any more)
1. Select tracks (typically: one album)
2. Guess the search terms from existing tags or the folder name — and
   **search right away**, when opening as well as when switching the source
3. On the left the search form: artist / album / year / catalog no.
4. Below it the results with thumbnail, label, year, format, country
5. A click on a result loads the album on the **right** — another click
   replaces it. No "Back": search and album stand side by side
6. **Matching:** one row per file — file, assigned track (swappable as a
   pop-up menu), its duration, the file's duration with the deviation. Above
   3 s orange. Plus "shift everything by one". The most important part —
   automatic matching regularly misses on live albums, bonus tracks and
   double CDs; the duration shows it even when the titles fit
7. Field selection under "Take over", for Discogs with the genre/style
   choice — and **Cover**: the release's front cover goes into every file of
   the lookup, replacing only an existing front cover (booklet pages stay).
   Size choice 600 / 1000 / 1200 px, remembered. MusicBrainz covers come from
   the Cover Art Archive in its largest ready-made size (`front-1200`; the
   original can be several megabytes), and only where the release says it
   has a front cover — otherwise the switch is greyed out. Discogs delivers
   its primary image (usually 600 px). Preset only when the files have no
   front cover yet, so that a good cover of one's own is not replaced by
   accident. The cover is downloaded on Apply; if that fails, nothing is
   applied and the sheet stays open.
8. Footer: "12 of 12 files matched", with a warning for missing matches or
   orange rows
9. Applied to the **editor state**, not directly to disk

**One sheet, two uses.** "Look Up Titles" in the Track Splitter (§7.12) is
built from the same parts (`ReleaseSearch`, `Views/Lookup/LookupParts`):
header with title and "Source", search on the left, album header and
comparison on the right, "Take over" below that, status, Cancel, Apply at the
bottom. The same labels, the same tolerance (`LookupComparison.tolerance`,
3 s), the same default source. Before, the fields were called "Release title"
here and "Album" there, the column was called "Discogs tracks" even for
MusicBrainz, and only the splitter searched by itself.

While a search field has focus, Return searches; otherwise it applies.
Without this switch, Return in a search field would close the sheet as soon
as an album is shown on the right.

**Control characters in the responses.** Discogs delivers raw `\r`/`\n` in
the middle of free-text fields such as `notes` — not allowed by the JSON
standard. `JSONDecoder` checks **lazily**: it only trips if a declared field
actually reads the broken string. A model without `notes` gets through today
but breaks as soon as someone adds the field — and then only for some
releases. That is why the bytes are always straightened before decoding
(`JSONSanitizer`), instead of betting on which fields the model contains.

**Discogs quirks**
- `genre` and `style` are separate. `style` is usually what one wants
  ("Melodic Death Metal" instead of "Rock"). Configurable, or both combined.
- Track lists contain index tracks and headings without a position — filter
  them out when matching
- Artist names have disambiguation suffixes: `Nirvana (2)`. Regex to remove
  them: ` \(\d+\)$`
- Several artists are in `artists[]` with `join` fields — join them, do not
  just take the first

### 4.7 Music app

- Add selected tracks to the Music app
- ScriptingBridge or `NSAppleScript`
- `NSAppleEventsUsageDescription` in Info.plist,
  `com.apple.security.automation.apple-events` in the entitlements
- Deliberately kept small, pure convenience

---

## 5. The Convert mode (version 1.1)

**The selling point:** generic converters wreck metadata — album artist
gone, cover as a 6 MB PNG, disc number missing. Sleeve already has the TagLib
layer and writes the tags correctly after conversion. The pitch is not "can
convert too" but "converts without you having to tag again afterwards".

**UI:** target format, quality/bitrate, target folder, file name template
(the same pattern engine), checkbox "Keep originals".

**Formats:** MP3 (LAME), FLAC, AAC, ALAC, Opus, Vorbis, WAV/AIFF

**Per file**
1. Read the tags from the source file before converting
2. Call ffmpeg with `-map_metadata -1` — deliberately switch off ffmpeg's own
   tag copying, it is unreliable across format boundaries
3. Then write the tags ourselves via TagLib, cover included
4. Take the cover over unchanged — scaling happens per picture in tag mode
   (§4.5)

**Encoder choice per format.** The first available candidate is taken: MP3
`libmp3lame`, AAC `aac_at` before `aac` (AudioToolbox is licensed, and an
LGPL build often has no usable AAC encoder at all), ALAC `alac` before
`alac_at` (open and patent-free, the native encoder is more reliable), FLAC
`flac`, Opus `libopus` before `opus`, Vorbis `libvorbis` before `vorbis`, WAV
`pcm_s16le`, AIFF `pcm_s16be`. ffmpeg considers the native Opus and Vorbis
encoders experimental; they additionally need `-strict -2`.

`-map_metadata -1` alone is not enough: the cover picture is a video stream,
not metadata. Without `-vn` it comes along unscaled.

Conversion as a serial queue with progress, cancellable. With several cores
two to three parallel ffmpeg processes, no more — disk throughput is usually
the bottleneck, not the CPU.

---

## 6. The Rip mode (version 1.2)

**Corrected after measuring on the device.** The first version of this
section assumed that going through the mounted `.aiff` files was enough and
that error correction, read offset and verification could therefore be
dropped. That assumption was wrong: macOS offers raw access without a
third-party library and without special privileges. The raw route is
implemented because the `.aiff` route **rules out by design** offset
correction and repeated reading — the CDDA file system hides exactly the
level rippers work on. Adding it later would not be possible, only starting
over.

### 6.1 Technical approach

Raw access via the ioctls from `<IOKit/storage/IOCDMediaBSDClient.h>`.

**Privileges:** the device node belongs to the logged-in user
(`cr--r----- <user> operator /dev/rdisk4`). No root, no helper service, no
entitlements. The sandbox is off anyway (§2.2).

**Character device, not block device** (`/dev/rdiskN`): buffered, the cache
would answer repeated read attempts instead of asking the disc — secure mode
would be worthless.

| ioctl | for |
|---|---|
| `DKIOCCDREADTOC` | table of contents, format 5 delivers CD-TEXT |
| `DKIOCCDREAD` | raw CDDA sectors of 2352 bytes |
| `DKIOCCDREADISRC` / `…MCN` | ISRC per track, barcode of the disc |
| `DKIOCCDGETSPEED` / `…SET…` | read speed |

The TOC is simpler to get: as the IOKit property `TOC` on the `IOCDMedia`
object, without opening the device.

#### 6.1.1 Pitfalls

**Swift does not see the `_IOWR` macros.** Error message:
`macro 'DKIOCCDREAD' unavailable: structure not supported` — because `_IOWR`
folds in the size of a C struct. The same stumbling block as the TagLib
picture macro. Solution: `Vendor/cdshim/` with a header that hands the values
over as constants. Swift sees the structs themselves on its own.

**Check `bufferLength` on return, not just the return value.** The test drive
(ASUS BW-16D1X-U) reports success when asked for payload *and* C2 pointers
and fills 1176 of 10584 bytes. Whoever does not check writes uninitialized
memory into the file as audio.

**C2 is not reliable, and no upfront check is enough.** Measured on one
device: the upfront check on track 1 passed, then in the middle of track 3
6468 instead of 15876 bytes. The same request delivers the full amount one
time and an eighth the next. Two levels follow from this:

1. `CDDrive.supportsC2` checks at three positions with three block sizes and
   compares **the content** against an ordinary read — the reported length
   alone is not enough.
2. `CDReader` gives way during operation: an unusable C2 read switches C2 off
   for the rest of the pass instead of aborting. The log notes it.

**Read ISRCs only as a set, never one by one.** On the test drive,
`DKIOCCDREADISRC` returns for track 2 sometimes its own code, sometimes track
1's — and the stale value comes back **consistently**. Tried without success:
reading twice and demanding agreement (both answers are then equally wrong),
seeking to the track first, varying read positions, querying another track in
between. The Q subchannel would be the clean source, but the same drive
returns audio data for `kCDSectorAreaSubChannelQ` instead of subchannel —
full length reported, PCM in the buffer.

The error does have a signature, though: a track gets its predecessor's code,
so one value appears twice in the set — and which one is wrong cannot be
decided. `readISRCs(for:)` therefore reads all tracks, discards the whole set
on a duplicate and reads again. Over six measuring runs: all fourteen right
twice, discarded four times, **not a single wrong code let through**. A wrong
ISRC in the tag goes unnoticed, a missing one does not.

The **MCN** is not affected and additionally confirmed: the ioctl returns
`0885470015767`, and the same is in the UPC field of the CD-TEXT — two
independent sources on the same disc.

**CD-TEXT is Latin-1, not UTF-8.** Read as UTF-8, "Großvater" becomes
"Gro�vater". The character set is in the size info pack (0x8F).

### 6.2 Identifying the disc

A chain from exact to inexact:

1. **MusicBrainz disc ID** — SHA-1 over TOC values, Base64 with `._-`. Hits
   exactly this pressing. Checked against the official worked example
   (`49HHV7Eb8UKF3aQiNmu1GR8vKTY-`), not merely claimed.
2. **TOC search** (`/discid/-?toc=…`) — less exact, several results. Only
   ever **suggestions** (§6.2.2): the first version applied the first hit by
   itself and gave a German audio drama the year and genre of a Japanese
   compilation.
3. **CD-TEXT** — on the disc itself, costs no network.
4. **By hand**, or rip unnamed and finish in tag mode.

Step 3 is no makeshift: the test disc ("Peter und der Wolf", Malte Arkona /
Dresdner Philharmonie) is **neither** under its disc ID **nor** under its
barcode at MusicBrainz, but carries complete CD-TEXT with titles, artists and
composer. Without CD-TEXT this CD could not be identified.

The FreeDB identifier comes as a by-product; it goes into the log.

### 6.2.2 Looking up a disc

**Look Up…** in the Rip section opens "Look Up Disc", built from the same
parts as the other two lookup sheets (§4.6): search on the left with
MusicBrainz or Discogs, prefilled from album and artist; the selected release
on the right; "Take over" at the bottom (title, artist, album, year, genre,
disc).

- When it opens, the disc ID hits are listed, marked "Disc ID"; a single hit
  is selected right away. Without one, the pressings with a similar TOC are
  listed, marked "Similar", with a note to check the lengths. Without those
  either, the text search runs with the prefilled terms.
- **The comparison uses the disc's own track lengths** from the TOC — exact
  to a 75th of a second — against the release's. A wrong pressing shows
  immediately: on the test disc a "similar" hit deviated by up to three
  minutes per track, and the footer says "probably another pressing".
- **Multi-disc releases:** the disc that is in the drive is preselected — the
  same number of tracks first, then the smallest total deviation — and can
  be changed ("Compare with: Disc 2 of 4"). Only its tracks are compared and
  taken over; before, the titles of all discs were written over each other
  by track number. "Disc" in "Take over" sets part n of m.
- Nothing is applied without "Apply". "CD-TEXT" goes back to the disc's own
  details and clears year and genre if they came from a lookup — typed ones
  stay.

### 6.2.1 Which fields the sources really fill

Measured before a field was built — an input field that never receives
anything is worse than none.

| Field | CD-TEXT | MusicBrainz |
|---|---|---|
| Album, artist, title | yes | yes |
| Composer | yes (album and per track) | no |
| Artist **per track** | yes | yes (track credits) |
| Year | no | yes |
| Genre | no | yes — **but only via the release group** |
| Disc number for multi-disc sets | no | yes |

**Genres do not hang off the release.** Measured: even "Nevermind" has no
genres on the release, seven on the release group. Without
`inc=…+release-groups` and the fallback to `releaseGroup.genres` the genre
field would almost always stay empty. The disc ID route delivers the group
too.

**The artist per track is no gimmick.** On the test disc four of fourteen
tracks carry an artist different from the album — classical music and
compilations are full of it. It goes into `artist`, while `albumArtist` stays
that of the disc.

### 6.3 What is implemented

| Function | Status |
|---|---|
| Burst and secure mode | implemented |
| Retries with majority vote | implemented |
| Read offset | implemented, checked to the byte |
| Second pass with checksum comparison | implemented |
| Read speed | implemented |
| MCN, CD-TEXT | implemented |
| ISRC | implemented, with discarding inconsistent sets — see §6.1.1 |
| C2 | implemented, with fallback — not delivered by the test drive |
| Log, cue sheet | implemented |
| Automatic read offset | **no** — the list of models belongs to AccurateRip |
| AccurateRip | **open**, see §6.6 |
| cdparanoia as a mode | **rejected** — a second vendor build without added value |

Secure mode reads every block twice. If the results differ, reading is
repeated up to `maxRetries`; two matching reads settle it, otherwise a
bytewise majority decides. Positions without a real majority count as
unresolved and go into the log.

**Offset correction:** a drive with offset `o` delivers sample `p + o` when
asked for position `p`. Whoever wants it from `start` asks from `start − o`.
Before sector 0 and beyond the lead-out the gap is filled with silence.

### 6.4 Verification

Two independent counter-checks, both in the test suite:

1. **Against macOS itself.** The mounted CDDA file system shows the same
   tracks as AIFC (`sowt` = little-endian, payload from byte 2352). Read raw
   and read there, they match byte for byte — across the whole route
   including `RipEngine` and the WAV file.
2. **Offset against itself.** An offset of exactly one sector has to give the
   same as a read shifted by one sector; an offset of 6 samples has to hit
   exactly 24 bytes. Both checked.

The checks on the device are skipped when no CD is inserted — they must not
turn the suite red just because no drive is connected.

### 6.5 Output

**Target format freely selectable.** Reading is always raw; what it becomes
is decided by the setting:

- **WAV** — written straight from the disc, ffmpeg is not needed.
- **anything else** — the WAV is an intermediate and goes through the same
  pipeline as the Convert section (`ConversionPlanner` + `ConversionQueue`,
  `keepsOriginals = false`). No second converter, no second source of errors.
  `ripBlocker` locks starting when ffmpeg or the encoder is missing — with
  the hint that WAV works without.

Checked on the test disc: ripped to FLAC, decodes bit-exact to what macOS
reads from the same track (`MD5 2070ab26…` on both sides).

**File names** come from the same pattern as when converting
(`%track% - %title%`, default). Important: **pattern and tags come from the
same source** — otherwise the file is named differently from what it
contains. If nothing is left of the pattern, because the title is missing,
say, it falls back to the two-digit track number.

The finished files land in the same track list as everything else.

Alongside, optionally, log and cue sheet. The log says explicitly what was
**not** checked: without comparing against other people's rips, the
statement is one about repeatability, not about correctness.

#### 6.5.1 Ejecting

`diskutil eject` is **not** enough. It only releases the medium logically:
the volume disappears from the Finder, the drive then reports "No Media
Inserted" — and the tray stays shut, the disc is still inside. Observed and
measured on the test device (ASUS BW-16D1X-U over USB).

`RipEngine.eject` therefore asks DiscRecording: `DRDevice(forBSDName:)`
finds the drive the disc is in, and its `ejectMedia` unmounts the volume and
opens the tray — of exactly that drive, which matters with several (§6.12).
Measured on the test drive: afterwards `trayIsOpen` is true and the drive
reports no medium.

Only a drive DiscRecording does not know — a pure reader without burner —
falls back to the earlier two steps:

1. `diskutil unmount` — release the volume cleanly, so that macOS reports no
   improper removal. The process is waited for.
2. `drutil tray eject` — really open the tray. `drutil` addresses the default
   drive, which is why it is only the fallback.

Proof that the tray really opens: `drutil tray close` brings the medium back
with the typical spin-up time of about ten seconds. Closing a closed tray
does not do that. `DRDevice.closeTray` on the other hand reported success and
left the tray open — Sleeve does not close trays.

#### 6.5.2 Not waking the drive needlessly

`RipEngine.inspect()` is expensive: opening the device, CD-TEXT, MCN,
**every** ISRC — for which every track is sought — and three C2 probes.
Seconds of work on the drive.

The `DiscWatcher` hangs off `AppState` and thus outlives the Rip section.
Without a brake, `inspect()` would run on **every** mounting and unmounting
of any volume — a USB stick in the Tag section would spin up the CD. The
watcher therefore checks the active mode before doing anything; when
switching to the Rip section the view reads everything freshly anyway.

#### 6.5.3 The tray closes by itself

Not a bug and not caused by Sleeve: the test drive pulls the tray back in by
itself after about **50 seconds**. Measured twice, with the app quit and with
a detector that does not touch the drive (existence of the node
`/dev/diskN`, no IOKit, no I/O).

The first measuring attempt wrongly pointed at an IOKit query — because the
check itself called `availableDrives()` and thus did exactly what it was
supposed to investigate. A detector that is part of the suspicion is useless.

#### 6.5.4 Form rows: what `Form` enforces

Two quirks, both measured rather than derived — and neither to be found by
thinking:

**The content slot of a form row is right-aligned and only gets its desired
width.** For a text field that grows with the content. Result: every title
field a different width, the text aligned right, and a long title blows up
the row height. `frame(maxWidth: .infinity)` does not help — neither on the
field nor on the surrounding `HStack`.

Remedy: put the row into the **label** slot, which is left-aligned and lets
the content fill the width. The duration moves to the content slot.

**`.textFieldStyle(.roundedBorder)` insists on its own width** and ignores
`frame(maxWidth:)`. Where fields should have equal widths, the look is drawn
by hand (a plain field on a rounded background) — as the track list already
does.

The same pattern in small for the labelled fields: `LabeledContent` folds the
content below the label as soon as its desired width no longer fits. Hence a
fixed label column there (`Row`).

#### 6.5.5 Controls

Two things are deliberately **not** in the form:

- **The start button** sits on the left of the toolbar, in the same place
  where the other modes show "Save". At the bottom of a long form the most
  important button scrolls out of view.
- **Progress** is in the footer. In the form it disappears exactly when one
  looks through the track list — that is, when one wants to see it.

In the form itself: checkboxes instead of switches for the track selection,
short labels with the explanation on the mouse pointer (full sentences get
cut off in buttons and pickers), and the same field look as in the Tag
section — a labelled row, an input field with a border.

### 6.9 Image of the whole disc

**No ISO.** Measured on the test disc: at sector 16, where the ISO 9660
volume descriptor would be, there are audio samples instead of the identifier
`CD001`. An audio CD carries no file system. And of the 2352 bytes of a CDDA
sector all 2352 are audio — an ISO container with its 2048 bytes of payload
would throw away an eighth (529 MiB compared to 461 MiB for this disc).
Instead, one continuous audio stream plus a cue sheet is written.

**Where it lives:** in the **File** menu, not in the Rip section. There one
picks tracks; an image is always the whole disc, the two exclude each other.
And not in the Sleeve menu — on macOS that belongs to the program itself. The
UI is a sheet on the main window, not a window of its own: the process
depends on the inserted disc, which the window shows anyway.

The read settings are bound to the same values as the Rip section. Two sets
of them would be a sure source of errors; a control appearing in two places,
on the other hand, is common.

**Formats:** `bin` (raw), `wav` (raw with header), `flac` (via the existing
converter pipeline). The file type in the cue sheet follows from that —
`BINARY` for BIN, otherwise `WAVE`. If the wrong one is there, the player
looks for the track boundaries shifted by 44 bytes.

**Reading streams.** `CDReader.readContiguous` passes blocks on instead of
collecting them: a CD is about 550 MB, and putting all of it into memory
first would be wasteful. The checksum is continued along the way
(`CRC32.continue_`/`finish`) — checked to match the one computed in one go.

**Data tracks are refused**, not written along. Extracting a data track raw
is not what this mode is for (§6.8).

#### Which format for what

Measured with VLC 3.0.23 on the same machine:

| File | VLC picks the demuxer |
|---|---|
| `.bin` | `ps` (MPEG program stream) — guessed, not recognized |
| `.cue` | `ps` — VLC does not understand cue sheets |
| `.wav` | `wav` — right |

`ffprobe` cannot make anything of the raw `.bin` either (`Invalid data found
when processing input`); only with `-f s16le -ar 44100 -ch_layout stereo`
do the expected 20.000000 s come out. That is no flaw of the image but the
nature of a headerless file: it tells nobody what it is.

XLD registers `.cue` with the system, `.bin` not — so one opens the cue
sheet, not the raw file.

Hence a hint below the format picker (`DiscImageFormat.hint`): BIN is for
archiving and burning, WAV and FLAC for listening. Without it one picks BIN —
"raw, as on the CD" sounds like the most faithful choice, and it is — and then
wonders why nothing plays. That is exactly how the question came up.

#### Evidence

A complete image of the test disc: 236218 sectors, 555,584,736 bytes plus 44
bytes of WAV header, in 136 s with burst and offset +6. Afterwards three
tracks across the disc (1, 7, 14) cut out of the image and compared with a
fresh single-track rip — **byte for byte identical**. `ffprobe` reports
`pcm_s16le`, 44100 Hz, 2 channels, 3149.57 s against 52:30 from the TOC.

#### Known limitation

Only `INDEX 01` is written. Where exactly a pause begins (`INDEX 00`) the TOC
does not say — that would need the subchannel, which the test drive does not
deliver reliably (§6.1.1). The image stays gapless anyway, because nothing is
cut out; only the pause markers are missing from the cue sheet.

### 6.10 Burning back

Via **DiscRecording**, without a third-party library. The numbers fit without
conversion: `kDRBlockSizeAudio` is 2352, exactly the sector size used for
reading as well. One `DRTrack` per track, fed by a `DRTrackDataProduction`
object that fetches the bytes from the image; burning uses
`kDRBurnStrategyCDSAO` — session-at-once, so that the transitions stay
gapless.

**Addresses are byte offsets from the start of the track.** Apple's header
for `produceDataForTrack:…atAddress:` calls the value "the sector address on
the disc from the start of the track" — relative to the track is right, but
it counts **bytes**, not sectors. Measured on the first test run: the calls
come at 0, 129360, 258720, steps of exactly 55 sectors of 2352 bytes. Taken
for a sector number, the third call pointed far beyond the end of the image;
the producer delivered nothing and the engine stopped with "an error occurred
while producing data for the burn". The producer also never reads past the
end of its track, so a request reaching further cannot repeat the next
track's audio.

**The pause before track 1 is produced by us.** A producer that implements
`producePreGapForTrack:` has to fill it (here: silence); returning 0 bytes
counts as an error.

**"Unsupported" is no obstacle.** The test drive reports
`DRDeviceSupportLevelUnsupported`. Apple's header distinguishes:

| Value | Meaning according to the header |
|---|---|
| `…LevelNone` | "the engine does not support the device and it **cannot be used**" |
| `…LevelUnsupported` | "the device is unsupported but the engine **will try to use it anyway**" |

Only `None` locks. `CDBurner.info(of:)` therefore checks exactly that and not
"is it supported".

The drive itself can do what is needed:
`CD-Write: -R, -RW, BUFE, CDText, Test, IndexPts, ISRC`, strategies
`CD-TAO, CD-SAO, CD-Raw`.

### 6.10.1 Verified on the first blank

Until October 2026 this was the only place in Sleeve that had never run on
real hardware. Since then it has, with one drive and one disc:

| | |
|---|---|
| Drive | ASUS BW-16D1X-U, USB, `DRDeviceSupportLevelUnsupported` |
| Blank | CD-R, 79:57:69 |
| Image | 10 tracks, 236015 sectors, 52:27, BIN, read in secure mode with offset 0 |
| Strategy | SAO, test run first, then the real burn |

**Result: the burned disc reads back byte for byte identical to the image** —
all 555,107,280 bytes, the same CRC per track, the same track starts in the
TOC, the same MusicBrainz disc ID. Read back with the same drive and the same
read offset, so a write offset of the drive would cancel out against its
read offset; with a second drive the comparison could show a constant
shift of a few samples, which is not an error of Sleeve.

**What the test run found.** The first test run failed with "an error
occurred while producing data for the burn". A trace of what the engine asked
for (`BurnTrace`, debug builds only, in the temporary folder) showed the
address counting bytes, not sectors (§6.10). That is exactly the mistake the
test run is there for: it costs no blank. The second test run went through,
then the real burn.

What was checked without a drive, and still is in the test suite:

| What | How |
|---|---|
| Parsing the cue sheet | round trip: written, read, all 14 start sectors and lengths against the TOC |
| The producer's address arithmetic | an image of recognizable sectors; the fifth sector of the track (address 5 × 2352) has to deliver sector 15 |
| Not reading past the track | a request beyond the end of the track stops at its last sector |
| Skipping the WAV header | a 44-byte shift in every address |
| End of file | nothing is invented beyond the end |
| Track layout | the sum of the `DRTrack` lengths matches the TOC; a pause only before track 1 |
| Drive detection | on the real device |
| Refusing unsuitable media | on the real device, **both** branches: a written audio CD and an empty blank of the wrong type |

Not verified: other drives, CD-RW, buffer underruns at high speed, CD-Text
and ISRC (not written).

**macOS does not verify audio tracks.** `DRBurnVerifyDiscKey` is set, but a
track without `DRVerificationTypeKey` is not verified, according to Apple's
header. The proof is reading the disc back and comparing — Sleeve does not do
that by itself yet.

**A DVD does not help with burning.** An audio CD is Red Book — CD format,
2352-byte sectors, CDDA tracks, SAO. None of that exists on DVD media. An
empty DVD blank does, however, cover another branch that occurs more often in
practice than the burn itself: **empty medium, wrong type.** Measured on an
empty DVD-R:

```
type (raw) : DRDeviceMediaTypeDVDR      blank: 1      free: 2297888 blocks
message    : "This is a DVD-R. An audio CD needs a CD-R or CD-RW."
ready      : false
```

The earlier version said "This is not a writable CD blank" — misleading for
an empty blank with 4.38 GiB of free space. That is why `CDBurner.mediaName`
now names the medium. By the way: the media type constants are `CFString?`
and cannot serve as `case` patterns in a `switch`.

One pitfall came up while checking: **`DRMSF.frames()` is the frame
component of a time value (0–74), not the total** — that is what
`sectors()` is for. The first attempt summed 493 instead of 236218 over
fourteen tracks. The check found the mistake before it could make its way
into the burner code.

**Repeating the check** (debug builds):

```sh
Sleeve.app/Contents/MacOS/Sleeve -SleeveDebugBurnTest /path/to/image.cue    # test run only
Sleeve.app/Contents/MacOS/Sleeve -SleeveDebugImage /path/to/folder -SleeveDebugImageName Copy
```

The first starts a test run — never a real burn — and writes the trace; the
second reads the inserted disc into a BIN image with the current read
settings, without changing the stored ones. Then compare per track.

### 6.10.2 Controls

**File → Burn Image to CD…**, a sheet as for creating.

The **test run** is the prominent button, not the real burn: laser off, the
whole process, the blank stays unwritten and reusable as often as needed. The
real burn sits next to it and asks for confirmation — it is the only function
in Sleeve that irrevocably uses up something physical.

FLAC images are unpacked to WAV first — the drive only takes raw PCM. The
temporary file disappears afterwards.

### 6.11 Copying a disc

**File → Copy CD…**: an audio CD 1:1 onto a blank, with one button. It is
§6.9 and §6.10 in one go, with everything decided that the two sheets let one
set:

| Question | Answer in the copy |
|---|---|
| Format | BIN — nothing to convert, nothing to lose |
| Where | a temporary folder; it goes when the sheet closes |
| Read settings | those of the Rip section — mode, offset, retries — without a log |
| Test run | none; "Copy" burns for real. The click is the consent |

**With one drive** the original has to make room: after reading Sleeve
ejects it (§6.5.1) and asks for a blank. The burner is checked every second;
what is wrong with the disc in it is shown while waiting — the original put
back in, a DVD, a blank that is too small — so that it does not just look
like waiting. As soon as a blank is recognized the burn starts. Whether one
drive is used is decided while the original is still in: once it is out its
BSD name is gone and the drives can no longer be matched.

**With two drives** reading and burning use different ones, and with a blank
already in the burner the copy runs through without a stop.

**Copy Again** burns the same image once more — the original is not needed,
the temporary image stays until the sheet closes. An image left behind by a
Sleeve that quit or crashed mid-copy is removed when the sheet opens again. After every burn the drive
ejects, so the next round starts with an empty tray.

Not copied: **CD-TEXT** — the burner writes none (§6.10). The sheet says so
when the original carries some. A disc that did not read cleanly is copied
with the same gaps; the sheet says that too.

Checked on the test drive, first with the burn as a test run (debug builds,
`-SleeveDebugCopy YES -SleeveDebugCopySimulated YES -SleeveDebugCopyStart
YES`): reading 236015 sectors, ejecting, waiting, recognizing the inserted
blank, burning through, ejecting again. Then a real copy, started by hand
with one drive: the copy read back **byte for byte identical** to the
original's image — the same disc ID, the same CRC for all ten tracks.

### 6.12 Several drives

Rarely more than one, but then the question is which one is meant. Two lists,
both cheap to ask for because only the registry is read, not the drives:

- **Reading**: the drives whose disc has a table of contents
  (`CDDriveFinder.audioDrives`), by BSD name. The Rip section, the image and
  the copy read from the picked one; the snapshot remembers its drive, so
  that a rip reads from the drive whose disc is shown.
- **Burning**: DiscRecording's drives that write CDs, by IORegistry path —
  that stays the same with and without a disc.

`DRDevice(forBSDName:)` connects the two: it takes the name of the medium
(`disk4`) and returns the drive it is in — measured. That is how the copy
knows whether original and blank share a drive.

A picker appears only with a second drive; with one, only its name is shown.
Two drives of the same model are numbered. A picked drive that disappears is
never quietly replaced by another — the pick falls back to "the first" and
the picker shows it.

Not testable here: the test machine has one drive. What can be checked
without a second one is in the burn tests — finding a burner by its id, a
vanished id giving no drive, the disc's drive matching the burner.

### 6.6 AccurateRip — open

The database belongs to Illustrate. Whether a GPLv3 program may query it has
to be settled **before the first line of code**, not afterwards. Without it
two things are missing: the comparison against other people's rips of the
same pressing and the list of models for the automatic read offset.

The second pass partly replaces the first point — it shows that the disc
reads reproducibly, but not that the offset is right.

### 6.7 Codec licenses

All unproblematic for GPLv3:

| Codec | Situation |
|---|---|
| FLAC | BSD-like, patent-free |
| MP3 | patents expired in 2017, LAME is LGPL |
| AAC / ALAC | AudioToolbox encodes on the system side, Apple has licensed it |
| Opus / Vorbis | BSD |

Should ffmpeg ever be shipped after all: use an `--enable-gpl` build, then
LAME is right in there and the GPLv3 fits.

### 6.8 Legal design rules

No legal advice, only the points that shape the design.

In Germany, §53 UrhG covers the private copy: copies for private use are
allowed as long as the original is not obviously unlawful. Ripping a CD one
has bought clearly falls under that.

The critical point is **§95a: circumventing effective technical protection
measures** — offering software that does so is prohibited too. Two hard
design rules follow from this:

1. **Read standard CDDA only.** Normal audio CDs have no copy protection;
   that is uncritical. Sleeve lets copy-protected discs (roughly 2001–2006)
   fail with a clear error message — nothing is circumvented. The code reads
   `kCDSectorTypeCDDA` exclusively and evaluates the control nibble; data
   tracks are skipped, not extracted.
2. **No DVDs, no CSS, nothing in that direction.**

Under these rules Sleeve is in the same position as XLD, which has existed
unchallenged for years.

---

## 7. Track Splitter

Splitting a long recording into individual tracks at the silences between
them, without re-encoding. **File → Split Into Tracks…**

Silence detection and edge buffer come from the Track Splitter in NeonRost's
toolbox and have been proven there over a long time. What was taken over is
what had proven itself, **not** the surroundings there.

### 7.1 The core is "cut at these positions"

Not "find silence". Where the boundaries come from is interchangeable: today
from silence, later from a cue sheet (§9.1). Otherwise reading cue sheets
would one day stand next to it as a second tool instead of being one more
source in front of it.

### 7.2 What was taken over and what was not

| From the toolbox | Status in Sleeve |
|---|---|
| `silencedetect` call and parsing | taken over |
| Edge buffer 2 s | taken over — silence right at the start or end is dead air |
| Defaults −30 dB, 0.5 s | taken over |
| `-ss`/`-to` before `-c copy` | taken over |
| ffmpeg as tag writer including its format table | **no** — Sleeve tags with TagLib and can do more there |
| Pattern syntax `%n` / `%t` | **no** — Sleeve has `%track%` and eight more |
| A tag block of its own for artist, album, cover | **no** — the pieces land in the track list, the Tag section does that better |

**`-c copy` inherits the source's tags.** Whatever describes the whole
recording — artist, year, genre — may stay. Whatever describes the **source
file** may not, and is replaced or deleted via TagLib after cutting:

| Tag | Why |
|---|---|
| Title | otherwise every piece would be named like the whole album |
| Track number | assigned anew, `n/total` |
| Comment | for downloads almost always the URL it came from |

Measured on the real album video: without this, **all 13 pieces** carried
`comment=https://www.youtube.com/watch?v=…` and the album title as their
title.

### 7.3 Finding boundaries

Three rules, each measured on a real album and each against a first version
that failed there. Cross-checked against the track list the album's uploader
gave (§7.11).

**1. Nothing is discarded.** The tracks lie against each other without gaps;
a pause belongs to the end of the previous track — as is usual with CD
rippers. The first version left out the pauses, and with them everything
quieter than the threshold: **66 s of the album were in no file**, including
the quiet intro of "Slider" (six seconds at −35 to −49 dB). Now the pieces add
up to the file — exact to the AAC frames.

**2. The cut goes at the end of the deepest silence**, not at the end of the
threshold silence (`cutPosition`). The threshold alone does not separate
cleanly: a quiet intro lies below it and still belongs to the next piece. For
"LR-7" the digital zero ends at 32:35, then the intro sets in, which keeps
dipping briefly below −30 dB — the threshold silence reached to 32:40. The
floor is whatever lies at most 6 dB above the deepest point or below −60 dB;
if there are several stretches, the longest counts. Without an envelope the
cut goes at the end of the silence.

**3. Short pieces go to the neighbour they lie closer to** (`thin`). If
several too-short pieces lie between two long tracks, exactly one of the cuts
there remains: the one at the longest pause.

| Case | longest pause | Result |
|---|---|---|
| Applause right after a live piece | after it | stays with the piece |
| Jagged intro after a long pause ("LUV") | before it | belongs to the next piece |

The first version attached everything to the predecessor — so the intro of
"LUV" belonged to the track before, 15 s off.

Also: silences with less than a second of sound between them count as one
(`bridge`) — a click in the pause does not split it. At the start and end of
the file there is only one neighbour; short pieces go there. The default
minimum length is 10 s.

**What no silence detection finds:** transitions without a pause. For
"Lynch" the level at 16:33 only jumps from −2 to −20 dB, nothing more. That
is what "Split here" is for.

### 7.4 Album as a video

A downloaded "full album" is often a **video** — YouTube delivers picture and
sound together. Rejecting such files would be wrong: the audio stream can be
extracted losslessly.

`-c copy` alone is **not** enough for that — measured: with an MP4 it copies
*both* streams, the pieces stay videos with h264 and AAC. Hence
`-map 0:a:0 -c:a copy`, and the container follows the audio format
(`AudioSplitter.SourceInfo.outputExtension`): AAC and ALAC to m4a, MP3 stays
MP3, Vorbis to ogg, raw PCM to wav. A video never becomes a video again.

Proven: the audio stream extracted this way is **bit-identical** to the one
in the video — the same MD5 over the raw samples, compared without cutting.
(With cutting they differ, but that is the known frame rounding effect and no
loss.)

For analysis, `-vn` saves decoding the picture — the lion's share of the time
for an album video lasting hours.

### 7.5 Target format

The default is **same as the source** — a pure cut, nothing is re-encoded.
The picker shows the actual extension ("Same as the source (M4A)"), so that
nobody has to guess.

Every other format **re-encodes**. With a lossy source that is a second loss,
and that is stated as a warning in the UI, not in the fine print. It is still
wanted sometimes — an MP3 for the car radio stick — which is why the choice
exists at all.

The encoder choice comes from the same source as for converting
(`FFmpegTool.encoder(for:)`), including `-strict -2` for the native Opus and
Vorbis encoders. If the encoder is missing, the button is locked with the
same hint as in the Convert section.

### 7.6 Window layout

A window of its own, not a sheet: the splitter is not tied to a disc in the
main window, and a sheet can be neither moved nor resized.

```
┌──────────────────────────────────────────────────────────────┐
│ File · duration · codec · video                    [Choose…] │
│ Threshold ─●─   Min. silence ─●─   Shortest track ─●─  [Analyse again] │
│ ▁▃▇▅▃▁│▂▅▇▆▃│▁▃▇▇▅│ …   overview, fixed, never scrolls away   │
├────────────────────────┬─────────────────────────────────────┤
│ ▶ 01 Title      1:33   │ Track 3 · 05:16.7 – 09:31.7    4:15 │
│ ▶ 02 Title      3:37   │ ● Start [05:16.7]⇅  ● End [09:31.7]⇅ │
│ ▶ 03 Title ◀    4:15   │ [ magnifier ±10 s ]  [ magnifier ±10 s ] │
│ …                      │ ▶ Play from mark  ⏮ ⏭  05:12.0   Preview 14 s │
│                        │ Start here · End here · Split here  │
│                        │ Join with previous · Reset boundaries │
├────────────────────────┴─────────────────────────────────────┤
│ Folder … · Format … · File name … → 03.m4a                   │
│ ✓ 13 tracks written — in the track list   [Split into 13 tracks] │
└──────────────────────────────────────────────────────────────┘
```

A principle that has proven itself twice already (rip progress, disc image):
**what one needs to see while working must not scroll away.** Overview,
editor and messages are therefore fixed; only the track list scrolls.

### 7.7 Envelope

Computed once, at a fixed resolution: ffmpeg decodes to mono at 4000 Hz, and
from that come **a hundred peak values per second** (10 ms per value). Both
views draw from it — the overview combines many values per pixel, the
magnifiers few.

- **Peak, not mean** — the mean would smooth out short loud spots, and those
  are exactly what one is looking for.
- **4000 Hz is enough** — against the full resolution the envelope deviates
  by 0.002 (at 2000 Hz by 0.023). An hour yields a 29 MB intermediate file
  instead of 635 MB.
- **Normalized to the loudest point of the whole file**, in the magnifier
  too. Without normalization a quiet recording becomes a flat line (ffmpeg's
  `sine` only delivers −18 dBFS). If every magnifier normalized to itself, a
  quiet fade-out would look as loud as the chorus — and one would put the
  boundary in the wrong place.

Drawn in three layers: shading (cheap), envelope (expensive, `Equatable`,
only for a new file, a new window or a new size) and mark plus playhead
(cheap, ten times a second). Without the separation, a quarter of a million
values would be run through again at every step of the playhead.

Only what was cut off at the edges of the file stays dark — there are no gaps
between the tracks (§7.3).

### 7.8 Magnifiers, mark, boundaries

Over 45 minutes, one pixel of the overview is about two seconds: good for
orientation, too coarse for cutting. The editor therefore shows **two
magnifiers** of ±10 s each — on the start (green) and the end (orange) of the
selected track, about 30 ms per pixel.

**One mark for the whole window** (dashed). Untouched, it sits **at the
start** of the selected track, on the green line. A click into a magnifier or
into the overview sets it; in the overview the click also selects the track.

Listening **across** a boundary is a route of its own: ⏮ and ⏭ as well as the
button in the track list play from a third of the preview before it. The
first version left the mark itself this lead-in before the start, so that
"Play from mark" would play across the boundary by itself — nobody could
guess that: whoever plays a track expects it from the green line.

**Boundaries are shared.** The start of track 3 is the end of track 2;
whoever moves it moves both (`moveBoundary`). Moving only one side would open
a gap again, and whatever lies in it would end up in no file. Cutting off is
only possible at the edges of the file — an announcement before the first
piece, say. After splitting or merging, the new state counts as the starting
point for "Reset", otherwise it would lead to a boundary that no longer
exists.

Setting boundaries, three routes — all on the same track, all immediately
visible in both views:

1. **Drag the colored line in the magnifier.** The pointer shows where it can
   be grabbed. Whether it is dragged or clicked is decided on first contact —
   otherwise the gesture would switch as soon as the finger leaves the line.
2. **"Start here" / "End here"** — takes what one hears: while playing the
   red head, otherwise the mark.
3. **Time field in steps of a tenth** — the exact route.

Plus **"Split here"** (a new boundary at the mark) and **"Join with
previous"**. Only with both is editing complete: boundaries can appear and
disappear.

#### Listening

`AVPlayer` with a boundary observer that stops after the preview length, and
a periodic observer for the playhead. No player: no scrubbing, no volume, no
list.

- Playback runs **past the end of the track**, limited only by the file —
  otherwise the rear boundary could not be judged.
- **Stopping by hand takes the position over into the mark**, the preview
  running out does not. This is how one works: listen, stop at the right
  spot, "End here". If instead every preview kept going, the mark would march
  forward a bit with every playback.
- Playability is checked **at runtime**, not guessed from the extension.
  Measured: AVFoundation takes everything the splitter accepts — Opus too,
  which a list of extensions would have excluded by mistake. `isPlayable`
  **throws** for some containers instead of returning `false`.

### 7.9 Discarded intermediate stages

The window came about in several rounds, each of which failed in use.
Recorded so that nobody builds them again:

| Attempt | Why discarded |
|---|---|
| Long form, envelope at the top | scrolled away as soon as one got to the tracks — "nothing to see" |
| Two play buttons on top of each other | different meanings, impossible to guess |
| Scrub bar per row | did not move along; stop jumped back; ended at the end of the track |
| Slider ±15 s per row | blind — one could not see where one was pushing; replaced by draggable lines in the magnifier |
| A fixed number of 2000 values | 1.35 s per value at 45 minutes, useless for a magnifier |
| Discarding pauses | discarded quiet intros with them — 66 s of the album in no file |
| Short pieces always to the predecessor | an intro after a long pause landed in the wrong track |
| Discarding snippets under 1 s | cut up the intro of "LR-7"; replaced by merging the silences |

### 7.10 Checking on the real window

`App/DebugHooks.swift`, **debug builds only**: launch arguments open the
window in a fixed state so that it can be checked with a screenshot.

```
Sleeve -SleeveDebugSplit <file> [-SleeveDebugSelect <n>]
       [-SleeveDebugPlayEnd YES] [-SleeveDebugShiftEnd <s>]
       [-SleeveDebugSplitTo <folder>]
```

The reason: the envelope had been reported as "done", but only its
computation had been checked. Nobody had seen it. Since then this window has
a rule: statements about the UI only after a screenshot.

### 7.11 Evidence

#### Cross-check against the uploader's track list

Defaults (−30 dB, 0.5 s, 10 s). The uploader's times are whole seconds and
usually lie in the middle of the pause; Sleeve puts the start where the music
sets in and is therefore usually a second later.

| | Uploader | first version | now |
|---|---|---|---|
| Vision | 1:35 | +2.6 s | +0.8 s |
| LUV | 18:55 | +14.9 s | +1.7 s |
| LR-7 | 32:35 | +5.4 s | +1.0 s |
| Slider | 39:30 | +5.2 s | −0.7 s |
| seven others | | within 1.5 s | within 1.5 s |
| Lynch | 16:33 | not found | not found — no pause |

12 of 13 within 1.7 s. For "Slider" Sleeve is **ahead** of the uploader: the
quiet intro starts at 39:29.3, he rounded. The additional boundary at 14:46
is an intentional pause in the middle of "48k Rate Change[Freeze]".

#### Built file

The end-to-end run works with a built file — three tones of 12 s, 3 s of
silence between them — because there every boundary is known beforehand.
With real music "roughly right" would be the best that could be checked.

The three tracks are found to within ±0.3 s, cut with the expected length,
and title and track number are in the file afterwards.

Plus the run on the **real album video** (44:49, H.264 + AAC):

| | Result |
|---|---|
| Tracks | 13, pure AAC in `.m4a`, **no picture** |
| Track numbers | `1/13` … `13/13` |
| "Slider" | starts with its quiet intro (−35 dB), discarded before |
| Title, comment | no longer inherited from the source |
| Artist, year | taken over from the source |
| Sum of the pieces | 2689.5 s for a 2689.3 s file — nothing lost, +0.2 s from AAC frames |
| Message | in the footer, with "Show in Finder" |

A pitfall while checking: `Timecode.format(61.25)` gives `01:01.2`, not `.3`.
Exactly `.x5` is a tie in binary, and `%.1f` then rounds to the even digit.
IEEE behaviour, not a bug — recorded so that nobody takes it for one.

### 7.12 Track titles from outside

**Look Up Titles…** opens a sheet with three sources — built like "Look Up
Album" when tagging (§4.6), from the same parts. All of them deliver a
`TrackListing`; what one can do with it is the same.

| Source | delivers | when |
|---|---|---|
| MusicBrainz | titles, **lengths**, album, artist, year, genre | albums listed there |
| Discogs (with a token) | the same, genre or style by choice | albums listed only there |
| Track list (pasted) | titles, **start times** | album videos — the list is almost always in the description |

The pasted list was not ordered, but it is the source that carries the
actual occasion: the test album is **not** on MusicBrainz. Searched with and
without artist, with and without the ∞ — MusicBrainz splits
"IMagination∞lenS" at the ∞ and only finds albums called "Lens". When
opening, the sheet searches right away with a suggestion from the file name
("Artist - Album", without appended parentheses like "(Full Album)") and, if
nothing comes, points to pasting right away. Search and results are kept
until another file comes.

**Pasted text** (`TrackListing(pasted:)`): one time value per line, at the
front or at the end, with or without hours, number and punctuation around
it. Lines without a time — link, heading — and lines that have no title left
once the time is removed — "(44:49)", the total length — are skipped; times
jumping backwards do not belong to the list. Checked with exactly the text
from the video description.

**Before applying,** the list stands next to what was found, with the
deviation per row. The count alone reassures too early: on the test album 13
matched 13, and still one boundary was 106 s off. That is why the footer also
reports orange rows, not only a wrong count.

**Take over** as when tagging: title, artist, album, year, genre — whatever
the source does not deliver is greyed out (a pasted list only has titles) —
and, as the sixth switch, **Boundaries**. Whatever is not ticked stays as it
was.

**Aligning boundaries** (the default for start times; for lengths only when
the count does not match): every time value snaps to a detected silence
within 5 s; if there is none nearby, the given time applies. This is exactly
how the list finds what no silence detection finds — Lynch at 16:33. From
lengths the boundaries are added up continuously, but each one anew from its
snapped predecessor: a recording rarely has the same pauses as the CD the
lengths refer to, and added up blindly the error would carry on with every
track. After aligning, the result counts as the starting point for "Reset".

Album, artist, year and genre from the list end up in the tags when cutting.
Without them, whatever the source carried stays.

**Result on the test album** with the pasted list: 13 files, named and tagged
("05 - 48k Rate Change[Freeze]⇒Convert22.m4a" — special characters stay),
"48k" one track again (2:25), Lynch 2:24 from 16:33. The magnifier shows that
the transition lies just under half a second **after** 16:33: the uploader
rounded to whole seconds; one drag of the green line is enough.

---

## 8. Project structure

```
Sleeve/
├── Sleeve.xcodeproj
├── Sleeve/
│   ├── App/
│   │   ├── SleeveApp.swift
│   │   ├── AppState.swift            // activeMode, mode selection
│   │   ├── AppState+*.swift          // one extension per area: Convert, Rip, Split, …
│   │   ├── DebugHooks.swift          // debug builds only, see §7.10
│   │   └── ModeSwitcher.swift
│   ├── Model/
│   │   ├── AudioTags.swift
│   │   ├── TrackFile.swift
│   │   ├── TrackListModel.swift      // shared by all modes
│   │   └── Artwork.swift
│   ├── TagEngine/
│   │   ├── TagEngine.swift           // actor, TagLib facade
│   │   ├── TagLibBridge.swift        // C API, unsafe encapsulated
│   │   └── PropertyKeys.swift
│   ├── Pattern/
│   │   ├── PatternToken.swift
│   │   ├── PatternRenderer.swift     // tags → string
│   │   ├── PatternParser.swift       // string → tags
│   │   ├── TextReplacement.swift     // find and replace, §4.3.1
│   │   └── FieldFormat.swift         // fill a field, §4.3.2
│   ├── Lookup/
│   │   ├── LookupModels.swift        // common model of both sources
│   │   ├── LookupService.swift       // facade in front of them
│   │   ├── JSONSanitizer.swift       // see §4.6.1, control characters
│   │   ├── RateLimiter.swift
│   │   ├── DiscogsModels.swift
│   │   ├── DiscogsClient.swift
│   │   ├── MusicBrainzClient.swift
│   │   ├── KeychainStore.swift
│   │   ├── ReleaseSearch.swift       // the search of both lookup sheets
│   │   ├── LookupSession.swift       // "Look Up Album": matching, fields
│   │   └── ReleaseMatcher.swift
│   ├── Convert/                      // 1.1
│   │   ├── AudioFormat.swift         // target formats, encoder candidates
│   │   ├── ProcessRunner.swift       // the only place that starts other programs
│   │   ├── FFmpegLocator.swift
│   │   ├── ConversionPlanner.swift   // arguments and target paths, pure computation
│   │   └── ConversionQueue.swift
│   ├── Rip/                          // 1.2
│   │   ├── DiscTOC.swift             // TOC, disc ID, FreeDB — pure computation
│   │   ├── CDText.swift              // Latin-1, see §6.1.1
│   │   ├── CDDrive.swift             // the only place with device access
│   │   ├── CDReader.swift            // offset, burst/secure, C2 fallback
│   │   ├── RipEngine.swift           // actor, orchestrates one pass
│   │   ├── RipSettings.swift
│   │   ├── RipReport.swift           // log and cue sheet
│   │   ├── WAVWriter.swift
│   │   ├── DiscImage.swift           // §6.9
│   │   ├── CueSheet.swift            // reading cue sheets, for burning
│   │   └── CDBurner.swift            // §6.10, DiscRecording; drives §6.12
│   ├── Split/                        // §7
│   │   ├── AudioSplitter.swift       // silence, boundaries, cutting
│   │   ├── SplitTrack.swift
│   │   ├── SplitPreview.swift        // listening across a boundary
│   │   ├── TrackListing.swift        // track lists from outside, §7.12
│   │   └── WaveformSampler.swift
│   ├── Views/
│   │   ├── TrackTableView.swift      // shared by all modes
│   │   ├── Inspectors/
│   │   │   ├── TagInspector.swift
│   │   │   ├── ConvertInspector.swift
│   │   │   └── RipInspector.swift
│   │   ├── Popovers/
│   │   ├── Sheets/                   // disc image, burning, copying, drive pickers, Track Splitter
│   │   ├── About/                    // "About Sleeve" and licenses
│   │   └── Lookup/                   // LookupSheet + LookupParts (also used by the splitter)
│   ├── Localization/  (en, de, es)
│   └── Resources/
│       ├── Sleeve.icon/          // app icon, generated by Scripts/build-icon.sh
│       └── Licenses/             // license texts for the "Licenses" window
├── Vendor/
│   ├── taglib/
│   │   ├── include/taglib/    // headers
│   │   ├── lib/               // libtag.a, libtag_c.a
│   │   └── module.modulemap
│   ├── cdshim/                // resolves the _IOWR macros, see §6.1.1
│   │   ├── CDShim.h
│   │   └── module.modulemap
│   └── src/                   // TagLib sources, not checked in
├── Scripts/
│   ├── build-taglib.sh
│   ├── build-icon.sh          // + make-icon-svg.py, make-icon-preview.py
│   ├── run-bridge-test.sh     // the test suite, see bridge-test/
│   ├── check-strings.sh       // every UI string translated
│   ├── build-manual.sh        // the PDF manual, printed by headless Chrome
│   ├── run-smoketest.sh
│   └── taglib-smoketest.swift
├── Icon/                      // icon design: brief, SVG master, layers, .icns, preview
├── docs/                      // the website (GitHub Pages) and Sleeve-Manual.pdf, as for MIKE and TOM
├── manual/                    // source.html + screenshots of the manual; Scripts/build-manual.sh
├── images/                    // icon and screenshots for the README
├── TestFiles/                 // §10 — self-made, checked in: the tests need them
├── LICENSE  (GPLv3)
├── LICENSES/
│   ├── taglib-LGPL-2.1.txt
│   ├── taglib-MPL-1.1.txt
│   └── utfcpp-BSL-1.0.txt
├── CLAUDE.md                  // standing rules for working on the project
├── README.md
└── Sleeve-SPEC.md             // this document
```

---

## 9. Order

**Weekend — as far as it gets:**

1. **Build TagLib, module map, a single test:** read the title of an MP3 and
   print it to the console. That first. If the build step does not run
   cleanly, everything else is wasted time.
2. `TagLibBridge` — reading all fields for MP3, M4A, FLAC
3. Writing, against a **copy** of a test file
4. `AppState` + `TrackListModel` + mode switcher (only "Tag" active)
5. Track list + drag and drop
6. TagInspector with multiple selection and the `touchedFields` logic
7. Saving with progress and error collection

Everything from here on is a bonus: numbering, capitalization, pattern engine
in both directions, cover pictures, Discogs, the Music app, localization,
icon, website, Ko-fi, AlternativeTo.

Then 1.1 Convert, 1.2 Rip.

### 9.1 Noted, not built

None of this is decided — recorded is only what would have to be kept in
mind when building it. (**Creating** an image has been built by now, see
§6.9.)

| Idea | Note |
|---|---|
| **Opening an image** | an entry point, not a section of its own: drag a `.cue` onto the track list. |

**The splitter (§7) and reading cue sheets are the same tool** — once the cut
boundaries come from the cue, once by hand, once from silence (ffmpeg comes
with `silencedetect`). Whoever builds reading cue sheets should therefore set
up the core as "cut this file at this list of positions" and not as "read a
cue" — otherwise the splitter later stands next to it as a second tool
instead of as a UI in front of it.

**Where such functions belong:** in the **File** menu, with "Add Files…" and
"Add to Music" — not in the Sleeve menu, which on macOS belongs to the program
itself (About, Settings, Quit). From about four media functions on, a menu of
their own, "Medium", is worth it; an "Extras" menu is a Windows habit.

---

## 10. Test files

Before the first write attempt, create a folder with test material:

- MP3 with ID3v2.3, ID3v2.4, ID3v1 and without any tag
- MP3 with several APIC frames
- M4A from the Music app
- FLAC with Vorbis comments
- A file with umlauts and emoji in the title
- A read-only file
- A deliberately damaged file
- A file with a 6 MB cover

The last three are the ones taggers usually die on.

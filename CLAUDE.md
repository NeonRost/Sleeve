# Sleeve

A native macOS audio tagger (SwiftUI, Swift 6, macOS 14+, Apple Silicon only)
that also converts, rips CDs, writes and burns disc images, and splits long
recordings into tracks. One track list is shared by the three modes Tag,
Convert and Rip; disc images and the Track Splitter live in the File menu.

`Sleeve-SPEC.md` is the design document: what Sleeve does, why, and what was
measured. Read the relevant section before changing an area, and update it
when behaviour changes. `README.md` is the public description.

The project is open source on GitHub (`NeonRost/Sleeve`), licensed under the
GPLv3 or later.

## Language

- Everything in the repository is **English**: code, comments, docs, test
  output, commit messages.
- The maintainer writes in **German** — answer in German.
- UI strings are English in the code and translated to German and Spanish in
  `Sleeve/Localization/Localizable.xcstrings`. Every visible string needs both
  translations; run `Scripts/check-strings.sh` after changing UI text.
- German test data (umlauts, ß, "Peter und der Wolf") is deliberate — that is
  what breaks taggers.

## Commands

```sh
xcodebuild -project Sleeve.xcodeproj -scheme Sleeve -configuration Debug build
Scripts/run-bridge-test.sh      # the test suite, against copies of TestFiles/
Scripts/check-strings.sh        # every UI string in the catalog, with de/es
Scripts/run-smoketest.sh        # TagLib from Swift, after a TagLib update
Scripts/build-taglib.sh         # rebuild Vendor/taglib (needs cmake)
Scripts/build-manual.sh         # docs/Sleeve-Manual.pdf from manual/source.html
```

The test suite compiles the app's model and engine files directly (see the
file list in `run-bridge-test.sh`). A new file that those files depend on has
to be added there. The Xcode project uses a synchronized folder group — new
files under `Sleeve/` need no project edits.

## Standing rules

### Tags

- **A field is only written if it is in `touchedFields`.** Never decide what
  to write by comparing values (spec §4.1). This is the single most important
  rule.
- All TagLib access goes through the PropertyMap in `TagLibBridge`, never the
  legacy tag API (spec §2.1.1).

### External tools are never bundled or installed

- ffmpeg is expected on the system, not shipped. It is located via the
  settings path, `/opt/homebrew/bin`, `/usr/local/bin` and `PATH` — apps
  launched from the Finder do not inherit the shell's `PATH`.
- Install commands (Homebrew, ffmpeg) are shown as **copyable text only**.
  Neither the app nor you run them.
- No App Sandbox: Homebrew's ffmpeg loads dylibs a sandboxed child process
  may not read (spec §2.2).

### Secrets and privacy

- The Discogs personal access token lives in the **keychain** only (service
  `de.neonrost.Sleeve`, account `discogs.token`), never in `UserDefaults`,
  logs or the repository. Do not read it for testing.
- No personal data in the repository: no user names in paths, no e-mail
  addresses. Use placeholders such as `<user>`. Commits use the GitHub
  no-reply address configured in the local git config.

### CD drive and burning

- Only standard CDDA is read; copy protection is never circumvented, data
  tracks and DVDs are refused (spec §6.8).
- **Never trigger a real burn.** It uses up a blank. Only the test run
  (`simulated: true`) may be used — for "Copy CD" via
  `-SleeveDebugCopySimulated YES`. A real burn or copy is always started by
  the user in the app.
- The user's own media files are read-only for testing; write outputs to a
  temporary folder.

### Checking the UI

Statements about the UI only after a screenshot. `App/DebugHooks.swift`
(debug builds only) opens windows in a defined state via launch arguments,
for example:

```sh
Sleeve.app/Contents/MacOS/Sleeve -SleeveDebugSplit /path/to/file -SleeveDebugSelect 3
Sleeve.app/Contents/MacOS/Sleeve -SleeveDebugTagLookup /path/to/folder -SleeveDebugPick 1
Sleeve.app/Contents/MacOS/Sleeve -SleeveDebugAbout YES
```

Screenshots for the README, the website (`docs/`) and the manual (`manual/`)
show **made-up data only** — no real album, no real drive, no path with a
user name. `-SleeveDebugStageDisc tracks.txt` (with `…StageAlbum`,
`…StageArtist`, `…StageBlank`) stands in a disc and a burner,
`-SleeveDebugWindowSize 1512x880` fixes the size, `-SleeveDebugSelectAll`,
`-SleeveDebugMode`, `-SleeveDebugPopover <id>`, `-SleeveDebugImageSheet`,
`-SleeveDebugCopy` and `-SleeveDebugBurnSheet` open the rest. Settings can be
overridden for one launch with `-<key> <value>` (e.g. `-rip.destination`)
without touching the stored ones.

Capture the window with `screencapture -x -o -l <windowID>`. Add
`-NSRequiresAquaSystemAppearance YES` to check light mode,
`-AppleLanguages '(en)'` for another language and
`-ApplePersistenceIgnoreState YES` to skip window restoration.

### Build settings

- `ARCHS = arm64` is required: the vendored TagLib is arm64-only, and a
  universal build silently links without it (spec §2.1.1).
- `STRING_CATALOG_GENERATE_SYMBOLS = NO`: the UI uses string keys, and keys
  such as "#", "—" or "Look Up" next to "Look Up…" cannot become symbols —
  the build fails.
- Xcode's "Update to recommended settings" removes `ARCHS` and switches
  symbol generation on. After accepting it, check both and restore them.
- Every source file starts with the GPL notice; keep it when creating files.

## Git

- Commit or push only when asked.
- Third-party license texts are in `LICENSES/` and
  `Sleeve/Resources/Licenses/`; the app shows them under About Sleeve → Show
  License.

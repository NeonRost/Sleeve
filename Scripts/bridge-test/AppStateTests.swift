//
//  AppStateTests.swift
//
//  Copyright (C) 2026 NeonRost
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
//  Checks the layers above the bridge: reading folders, editing several
//  tracks, saving with error collection, undo. What is not checked here is
//  the SwiftUI rendering itself.
//

import Foundation

enum AppStateTests {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ label: String, detail: @autoclosure () -> String = "") {
        checks += 1
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            let extra = detail()
            print("  ✗ \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, label, detail: "is \(actual), expected \(expected)")
    }

    static func section(_ title: String) { print("\n━━ \(title)") }

    /// File names and tags of a rip come from the same source — otherwise
    /// the file is named differently from what it contains.
    @MainActor
    static func ripNaming() {
        print("\n━━ Rip — file names from the pattern")
        let state = AppState()
        state.discAlbum = "Peter und der Wolf"
        state.discArtist = "Malte Arkona, Dresdner Philharmonie"
        state.discTitles = [3: "Andantino", 7: "Der Großvater", 9: ""]
        state.selectedRipTracks = [3, 7, 9]

        state.ripSettings.filenamePattern = "%track% - %title%"
        state.ripSettings.format = .flac
        equal(state.previewFilename(forTrack: 3), "03 - Andantino.flac",
              "track number gets two digits, title appended")
        equal(state.previewFilename(forTrack: 7), "07 - Der Großvater.flac",
              "umlauts stay in the file name")

        state.ripSettings.format = .mp3
        equal(state.previewFilename(forTrack: 3), "03 - Andantino.mp3",
              "extension follows the target format")

        // Without a title only a separator would be left of the pattern.
        equal(state.previewFilename(forTrack: 9), "09.mp3",
              "without a title the track number remains")

        state.ripSettings.filenamePattern = ""
        equal(state.previewFilename(forTrack: 3), "03.mp3",
              "an empty pattern means: just the track number")

        state.ripSettings.filenamePattern = "%artist% - %album% - %title%"
        equal(state.previewFilename(forTrack: 3),
              "Malte Arkona, Dresdner Philharmonie - Peter und der Wolf - Andantino.mp3",
              "several placeholders")

        // The tags have to match the name.
        let tags = state.tags(forTrack: 3)
        equal(tags.title, "Andantino", "title in the tag")
        equal(tags.album, "Peter und der Wolf", "album in the tag")
        equal(tags.trackNumber, 3, "track number in the tag")

        print("\n━━ Rip — year, genre, composer, multi-disc set")
        state.discYear = "2021"
        state.discGenre = "Classical"
        state.discComposer = "Sergej Prokofjew"
        let full = state.tags(forTrack: 3)
        equal(full.year, 2021, "year ends up in the tag")
        equal(full.genre, "Classical", "genre ends up in the tag")
        equal(full.composer, "Sergej Prokofjew", "composer ends up in the tag")
        check(full.discNumber == nil, "a single CD gets no disc number")

        state.discTotal = 2
        state.discNumber = 2
        let set = state.tags(forTrack: 3)
        equal(set.discNumber, 2, "in a multi-disc set the disc number is in there")
        equal(set.discTotal, 2, "and the total")
        state.discTotal = 1

        // The placeholders now all have to produce something — a pattern
        // that leads nowhere is worse than none.
        state.ripSettings.format = .flac
        state.ripSettings.filenamePattern = "%year% %genre% %composer% %track% %title%"
        equal(state.previewFilename(forTrack: 3),
              "2021 Classical Sergej Prokofjew 03 Andantino.flac",
              "year, genre and composer fill their placeholders")

        print("\n━━ Rip — a different artist per track")
        state.discTrackArtists = [7: "Peter Schreier, Walter Olberz"]
        equal(state.tags(forTrack: 7).artist, "Peter Schreier, Walter Olberz",
              "a track with an artist of its own keeps it")
        equal(state.tags(forTrack: 7).albumArtist, "Malte Arkona, Dresdner Philharmonie",
              "the album artist stays unaffected")
        equal(state.tags(forTrack: 3).artist, "Malte Arkona, Dresdner Philharmonie",
              "a track without an artist of its own inherits the album's")
        state.discTrackArtists = [:]
        state.ripSettings.filenamePattern = "%track% - %title%"

        print("\n━━ Rip — album folder")
        state.ripFolderName = ""
        equal(state.sanitizedAlbumFolderName,
              "Malte Arkona, Dresdner Philharmonie - Peter und der Wolf",
              "without an entry of one's own, from artist and album")
        equal(state.suggestedAlbumFolderName, state.sanitizedAlbumFolderName,
              "the suggestion is exactly what would be used otherwise")
        state.ripFolderName = "Prokofjew — Peter und der Wolf"
        equal(state.sanitizedAlbumFolderName, "Prokofjew — Peter und der Wolf",
              "an entry of one's own beats the suggestion")
        state.ripFolderName = "  With/Slash  "
        equal(state.sanitizedAlbumFolderName, "With_Slash",
              "an entry of one's own is made safe for the file system")
        state.ripFolderName = ""

        print("\n━━ Rip — default pattern and reset")
        equal(RipSettings.defaultFilenamePattern, "%track% - %title%",
              "the default is short")
        var fresh = RipSettings()
        equal(fresh.filenamePattern, RipSettings.defaultFilenamePattern,
              "a fresh settings object carries the default")
        fresh.filenamePattern = "%artist%"
        check(fresh.filenamePattern != RipSettings.defaultFilenamePattern,
              "and can be changed")

        print("\n━━ Rip — what prevents starting")
        state.disc = nil
        check(state.ripBlocker != nil, "no disc, no rip")
        state.ripSettings.format = .wav
        check(state.ripBlocker != nil, "not even with WAV without a disc")
    }

    @MainActor
    static func run() async throws -> Int32 {
        let root = FileManager.default.currentDirectoryPath
        let workDir = NSTemporaryDirectory() + "sleeve-appstate-" + UUID().uuidString
        let nested = workDir + "/Album/CD2"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }

        // Copy test material into a nested folder structure, plus a file
        // that is not audio at all.
        let sources = ["01 - id3v2.3 - full.mp3", "04 - vorbis.flac", "05 - mp4.m4a"]
        for (index, name) in sources.enumerated() {
            let target = index == 0 ? workDir + "/Album" : nested
            try FileManager.default.copyItem(
                atPath: root + "/TestFiles/" + name,
                toPath: target + "/" + name
            )
        }
        try "not audio".write(toFile: workDir + "/Album/readme.txt",
                              atomically: true, encoding: .utf8)

        let state = AppState()

        // MARK: - Reading folders recursively

        section("Loading files — folders recursively")
        await state.addFiles([URL(fileURLWithPath: workDir)])
        equal(state.trackList.tracks.count, 3, "three audio files found")
        check(!state.trackList.tracks.contains { $0.filename.hasSuffix(".txt") },
              "non-audio skipped")
        equal(state.failures.count, 0, "no errors while importing")
        check(state.trackList.tracks.allSatisfy { !$0.isDirty },
              "freshly loaded files are not changed")

        section("Loading files — the same paths again")
        await state.addFiles([URL(fileURLWithPath: workDir)])
        equal(state.trackList.tracks.count, 3, "no duplicates")

        // MARK: - Editing several tracks

        section("Multiple selection — album applied to all")
        state.trackList.selection = Set(state.trackList.tracks.map(\.id))
        let selection = state.trackList.selectedTracks
        equal(selection.count, 3, "three tracks selected")

        selection.forEach { $0.set("Sleeve Sampler", for: .album) }
        check(selection.allSatisfy { $0.edited.album == "Sleeve Sampler" },
              "album set on all of them")
        check(selection.allSatisfy { $0.touchedFields == [.album] },
              "exactly one field marked as touched")
        equal(state.trackList.changedCount, 3, "three changed tracks")

        section("Touching only on a real change")
        let probe = state.trackList.tracks[0]
        probe.touchedFields.removeAll()

        // This is what SwiftUI does on a mere click into the field: the setter
        // with the unchanged text. Must not mark anything.
        probe.set(probe.edited.title, for: .title)
        check(probe.touchedFields.isEmpty, "a click without a change marks nothing")

        probe.set("  \(probe.edited.album ?? "")  ", for: .album)
        check(probe.touchedFields.isEmpty, "whitespace around it alone does not count as a change")

        probe.set("Really new", for: .title)
        equal(probe.touchedFields, [.title], "a real change is marked")

        // Deliberately clearing a field is a change, not doing nothing.
        probe.set("", for: .comment)
        let commentBefore = probe.original.comment
        check(commentBefore == nil || probe.touchedFields.contains(.comment),
              "clearing an existing field is marked")
        probe.revert()
        equal(probe.touchedFields, [], "discarding cleans up")

        // Restore the selection as it was.
        selection.forEach { $0.set("Sleeve Sampler", for: .album) }

        // MARK: - Saving

        section("Saving")
        let titlesBefore = state.trackList.tracks.map(\.edited.title)
        await state.save()
        equal(state.failures.count, 0, "no errors while writing")
        equal(state.trackList.changedCount, 0, "nothing pending after saving")
        check(state.trackList.tracks.allSatisfy { $0.touchedFields.isEmpty },
              "touchedFields cleared")

        // Check against the disk, not against memory.
        for track in state.trackList.tracks {
            let onDisk = try TagLibBridge.read(from: track.url).tags
            equal(onDisk.album, "Sleeve Sampler", "  \(track.filename): album on disk")
        }
        equal(state.trackList.tracks.map(\.edited.title), titlesBefore,
              "titles untouched — only the album was touched")

        // MARK: - Undo

        section("Undo — last write undone")
        check(state.canUndo, "undo is ready")
        await state.undoLastSave()
        equal(state.failures.count, 0, "undo without errors")
        for track in state.trackList.tracks {
            let onDisk = try TagLibBridge.read(from: track.url).tags
            check(onDisk.album != "Sleeve Sampler",
                  "  \(track.filename): album reset",
                  detail: onDisk.album ?? "—")
        }
        check(!state.canUndo, "undo is used up")

        // MARK: - Discarding

        section("Discarding changes")
        let firstTrack = state.trackList.tracks[0]
        let originalTitle = firstTrack.edited.title
        firstTrack.set("Will be discarded", for: .title)
        equal(state.trackList.changedCount, 1, "one change pending")
        state.trackList.selection = []
        state.revertSelection()
        equal(firstTrack.edited.title, originalTitle, "title reset")
        equal(state.trackList.changedCount, 0, "nothing pending any more")

        section("Clearing a field across the whole selection")
        // The real-world case: downloaded MP3s carry the source's address in
        // the comment. Select all, clear the field, save.
        for (index, track) in state.trackList.tracks.enumerated() {
            // One stays empty on purpose — it must not count as touched.
            track.set(index == 0 ? nil : "https://getrockmusic.net", for: .comment)
        }
        await state.save()
        equal(state.trackList.tracks.compactMap(\.edited.comment).count, 2,
              "two tracks have a comment")

        let all = state.trackList.tracks
        all.forEach { $0.set(nil, for: .comment) }

        let touched = all.filter { $0.touchedFields.contains(.comment) }
        equal(touched.count, 2, "only the two with content count as touched")
        check(!all[0].touchedFields.contains(.comment),
              "an already empty field is not marked needlessly")

        await state.save()
        for track in all {
            let onDisk = try TagLibBridge.read(from: track.url).tags
            equal(onDisk.comment, nil, "  \(track.filename): comment gone from disk")
        }

        section("Find and replace")
        let titlesBeforeReplace = state.trackList.tracks.map(\.edited.title)
        let track = TextReplacement(find: "track", replacement: "Song")
        let changes = (try? state.replacementPreview(track, fields: [.title])) ?? []
        equal(changes.count, 1, "the preview finds exactly the one title containing \"Track\"")
        equal(changes.first?.new, "M4A Song", "and shows the result")
        equal((try? state.replacementPreview(track, fields: [.album]))?.count, 0,
              "fields not chosen stay out of it")
        let applied = (try? state.applyReplacement(track, fields: [.title])) ?? -1
        equal(applied, 1, "applying changes what the preview showed")
        let changed = state.trackList.tracks.filter { $0.touchedFields.contains(.title) }
        equal(changed.map(\.edited.title), ["M4A Song"], "only that title is marked as touched")
        changed.forEach { $0.revert() }
        equal(state.trackList.tracks.map(\.edited.title), titlesBeforeReplace, "and can be discarded")
        check((try? state.replacementPreview(TextReplacement(find: "(", usesRegularExpression: true),
                                             fields: [.title])) == nil,
              "an invalid regular expression throws instead of previewing")

        section("Fill a field from a pattern")
        let commentsBefore = state.trackList.tracks.map(\.edited.comment)
        let fromName = FieldFormat(pattern: "%filename%")
        let fills = state.formatPreview(fromName, field: .comment)
        equal(fills.count, state.operationTargets.filter {
            $0.edited.comment != $0.url.deletingPathExtension().lastPathComponent }.count,
              "every track whose comment differs from its file name")
        state.applyFormat(fromName, field: .comment)
        check(state.trackList.tracks.allSatisfy {
            $0.edited.comment == $0.url.deletingPathExtension().lastPathComponent },
              "applying puts the file name into the comment")
        check(state.trackList.tracks.allSatisfy { !$0.touchedFields.contains(.title) },
              "no other field is touched")
        equal(state.formatPreview(fromName, field: .comment).count, 0,
              "a second time there is nothing left to change")
        // One track without an album: the pattern gives nothing there.
        let bare = state.trackList.tracks[0]
        bare.set("", for: .album)
        let albumFills = state.formatPreview(FieldFormat(pattern: "%album%"), field: .comment)
        check(!albumFills.contains { $0.trackID == bare.id },
              "a track without the value is left out, not cleared")
        check(albumFills.contains { $0.trackID != bare.id },
              "the others are filled")
        state.trackList.tracks.forEach { $0.revert() }
        equal(state.trackList.tracks.map(\.edited.comment), commentsBefore, "and can be discarded")

        section("Several cover pictures")
        let picture = try Data(contentsOf: URL(fileURLWithPath: root + "/TestFiles/cover.jpg"))
        let front = ArtworkProcessor.prepare(picture, pictureType: .frontCover,
                                             options: .passthrough)!
        let booklet = ArtworkProcessor.prepare(picture, pictureType: .leafletPage,
                                               options: .passthrough)!
        let back = ArtworkProcessor.prepare(picture, pictureType: .backCover,
                                            options: .passthrough)!

        state.trackList.selection = [state.trackList.tracks[0].id]
        let one = state.trackList.tracks[0]

        state.applyArtwork(front, replacing: true)
        equal(one.edited.artwork.count, 1, "first picture set")

        state.applyArtwork(booklet, replacing: false)
        equal(one.edited.artwork.count, 2, "the second picture is added, does not replace")

        state.applyArtwork(back, replacing: false)
        equal(one.edited.artwork.count, 3, "the third picture is added")
        equal(Set(one.edited.artwork.map(\.pictureType)),
              Set([.frontCover, .leafletPage, .backCover]), "three different picture types")

        // The same type again replaces only that one.
        state.applyArtwork(front, replacing: false)
        equal(one.edited.artwork.count, 3, "the same picture type replaces instead of piling up")

        // The front cover has to be in front, even if it comes later:
        // players usually simply take the first picture.
        equal(one.edited.artwork.first?.pictureType, .frontCover,
              "the front cover is in first place")

        state.removeArtwork(at: 0)
        equal(one.edited.artwork.count, 2, "front cover removed")
        check(!one.edited.artwork.contains { $0.pictureType == .frontCover },
              "… and really gone")

        state.applyArtwork(front, replacing: false)
        equal(one.edited.artwork.first?.pictureType, .frontCover,
              "a front cover added later moves to the front again")
        equal(one.edited.artwork.count, 3, "the others are kept")
        equal(one.edited.artwork.dropFirst().map(\.pictureType), [.leafletPage, .backCover],
              "the order of the other pictures stays untouched")

        state.removeArtwork(at: 1)
        equal(one.edited.artwork.count, 2, "a single picture removed")

        state.applyArtwork(front, replacing: true)
        equal(one.edited.artwork.count, 1, "replacing clears away the others")

        state.removeArtwork()
        equal(one.edited.artwork.count, 0, "all removed")
        state.trackList.selection = []

        // MARK: - Errors do not abort the batch

        section("Error collection — one read-only file among three")
        let locked = state.trackList.tracks[1]
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: locked.url.path)
        state.trackList.tracks.forEach { $0.set("Batch", for: .genre) }
        await state.save()

        equal(state.failures.count, 1, "exactly one error collected")
        equal(state.failures.first?.filename, locked.filename, "the right file reported")
        check(state.isShowingFailureSheet, "error sheet is shown")
        check(locked.lastError != nil, "error noted on the track")
        equal(locked.status, .failed, "status is \"failed\"")

        let others = state.trackList.tracks.filter { $0.id != locked.id }
        check(others.allSatisfy { !$0.isDirty }, "the other two were written")
        for track in others {
            let onDisk = try TagLibBridge.read(from: track.url).tags
            equal(onDisk.genre, "Batch", "  \(track.filename): genre on disk")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: locked.url.path)

        // MARK: - Mode availability

        section("Modes")
        check(state.availability(of: .tag).isAvailable, "Tag is available")
        // Convert can be entered even without ffmpeg: the instructions for
        // installing ffmpeg are in exactly this section. Locking the mode for
        // that would be circular.
        check(state.availability(of: .convert).isAvailable,
              "Convert can be entered, even without ffmpeg")
        // As with converting: enterable even when no disc is inserted. What is
        // missing, the section says itself.
        check(state.availability(of: .rip).isAvailable,
              "Rip can be entered, even without a CD inserted")
        equal(AppMode.allCases.count, 3, "all three modes visible, none hidden")

        // The blocker prevents starting instead.
        state.ffmpeg = nil
        check(state.conversionBlocker != nil, "without ffmpeg the blocker reports the obstacle",
              detail: state.conversionBlocker ?? "—")

        // MARK: - Result

        ripNaming()

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("✗ \(failures) failed")
            return 1
        }
        print("✓ All green.")
        return 0
    }
}

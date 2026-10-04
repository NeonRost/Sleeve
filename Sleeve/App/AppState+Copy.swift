//
//  AppState+Copy.swift
//  Sleeve
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
//  Copying an audio CD 1:1 (spec §6.11): the image and the burn of §6.9 and
//  §6.10 in one go, without anything to set. Read with the Rip section's
//  settings into a temporary BIN image, then onto a blank — with one drive
//  the original comes out in between and Sleeve waits for the blank.
//

import Foundation

enum CopyStage: Sendable, Equatable {
    case idle
    case reading
    /// The image is read; waiting for a blank to appear in the burner. The
    /// text says why the disc that is in there now does not do.
    case waitingForBlank(problem: String?)
    case burning
    case done
}

/// The image of the original, kept until the sheet closes — for a second
/// copy without reading again.
struct CopyImage: Sendable {
    var folder: URL
    var layout: CDBurner.Layout
    var sourceName: String
    /// Decided while the original was still in: once it is out, its BSD
    /// name is gone and the drives can no longer be matched.
    var usesOneDrive: Bool
    var isClean: Bool

    var duration: Duration {
        .seconds(Double(layout.totalSectors) / Double(CDGeometry.sectorsPerSecond))
    }
}

extension AppState {

    func showCopySheet() {
        copyError = nil
        if copyTask == nil, copyImage == nil {
            copyStage = .idle
            copyProgress = 0
            removeLeftoverCopyImages()
        }
        isShowingCopySheet = true
        refreshCopyDrives()
    }

    /// Both lists — the drives with an audio CD and the burners. Neither
    /// asks the drives themselves, so the sheet can call it every second
    /// while nothing runs.
    func refreshCopyDrives() {
        refreshSourceDrives()
        refreshBurnMedia()
    }

    /// The table of contents of the disc to copy.
    var copySourceTOC: DiscTOC? {
        effectiveSourceDrive?.rawTOC.flatMap(DiscTOC.init(rawTOC:))
    }

    /// What prevents copying. A burner without a blank is no obstacle —
    /// Sleeve asks for one after reading.
    var copyBlocker: String? {
        guard let toc = copySourceTOC else {
            return String(localized: "Insert the audio CD to copy.")
        }
        guard !toc.hasDataTrack else {
            return String(localized: "This disc carries a data track. Sleeve copies audio discs only.")
        }
        guard let device = burnDevice else {
            return String(localized: "No drive found that can burn CDs.")
        }
        guard device.isUsable else {
            return String(localized: "macOS cannot use this drive for burning.")
        }
        return nil
    }

    /// Whether original and blank go into the same drive one after the other.
    var copyUsesOneDrive: Bool {
        if let image = copyImage { return image.usesOneDrive }
        guard let source = effectiveSourceDrive else { return true }
        return CDBurner.isDrive(of: source.bsdName, burner: burnDevice?.id)
    }

    func startCopy() {
        guard copyBlocker == nil, copyTask == nil,
              let source = effectiveSourceDrive else { return }

        discardCopyImage()
        copyError = nil
        copyProgress = 0
        copyStage = .reading

        let oneDrive = copyUsesOneDrive
        var settings = ripSettings
        settings.writesLog = false
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.copyFolderPrefix)\(UUID().uuidString)", isDirectory: true)

        copyTask = Task { [ripEngine] in
            defer { copyTask = nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                failCopy(String(localized: "Cannot create the destination folder"))
                return
            }

            var result: RipEngine.ImageResult?
            for await event in ripEngine.createImage(
                in: folder, baseName: "disc", format: .bin, settings: settings,
                albumTitle: nil, albumArtist: nil, trackTitles: [:], ffmpeg: nil,
                bsdName: source.bsdName)
            {
                switch event {
                case let .reading(fraction): copyProgress = fraction
                case .converting:            break
                case let .finished(image):   result = image
                case let .failed(reason):    copyError = reason
                }
            }
            guard !Task.isCancelled, let result,
                  let layout = CDBurner.layout(cueURL: result.cueURL) else {
                try? FileManager.default.removeItem(at: folder)
                if !Task.isCancelled {
                    failCopy(copyError ?? String(localized: "The disc could not be read."))
                }
                return
            }
            copyImage = CopyImage(folder: folder, layout: layout,
                                  sourceName: source.bsdName, usesOneDrive: oneDrive,
                                  isClean: result.isClean)
            await burnCopy()
        }
    }

    /// Another copy of the same image, without reading the original again.
    func copyAgain() {
        guard copyTask == nil, copyImage != nil else { return }
        copyError = nil
        copyTask = Task {
            defer { copyTask = nil }
            await burnCopy()
        }
    }

    private func burnCopy() async {
        guard let image = copyImage else { return }
        let target = burnDevice?.id

        // With one drive the original has to make room. After the burn the
        // drive ejects by itself, so a second round starts with an empty tray.
        if image.usesOneDrive {
            ripEngine.eject(bsdName: image.sourceName)
        }

        // Waiting for the blank. The disc that is in there is checked every
        // second; what is wrong with it is shown, so that a swapped-in
        // original or a DVD does not just look like waiting.
        copyProgress = 0
        copyStage = .waitingForBlank(problem: nil)
        while !Task.isCancelled {
            refreshBurnMedia()
            var ready = false
            switch burnMedia {
            case .blank(let free):
                // 0 means the drive did not say — then it is tried.
                ready = free == 0 || free >= image.layout.totalSectors
                copyStage = .waitingForBlank(problem: ready
                    ? nil : String(localized: "This blank is too small for the disc."))
            case .unusable(let reason):
                copyStage = .waitingForBlank(problem: reason)
            case .noDisc, .noDrive:
                copyStage = .waitingForBlank(problem: nil)
            }
            if ready { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard !Task.isCancelled else { return }

        copyStage = .burning
        var finished = false
        for await event in CDBurner.burn(image.layout, simulated: copyIsSimulated,
                                         deviceID: target) {
            switch event {
            case let .progress(fraction): copyProgress = fraction
            case .finished:               finished = true
            case let .failed(reason):     copyError = reason
            }
        }
        guard !Task.isCancelled else { return }
        copyStage = finished ? .done : .idle
        refreshCopyDrives()
    }

    private func failCopy(_ reason: String) {
        copyError = reason
        copyStage = .idle
    }

    /// Stops whatever runs. An image already read stays for "Copy Again".
    func cancelCopy() {
        copyTask?.cancel()
        copyTask = nil
        copyStage = .idle
        copyProgress = 0
    }

    /// When the sheet closes: stop, and the temporary image goes.
    func endCopy() {
        copyTask?.cancel()
        copyTask = nil
        discardCopyImage()
        copyStage = .idle
        copyProgress = 0
    }

    /// A copy that ended with Sleeve itself — quit, crashed — leaves its
    /// image behind, half a gigabyte each. Cleared when the sheet opens
    /// again; macOS would only get to it after days.
    private func removeLeftoverCopyImages() {
        let temporary = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix(Self.copyFolderPrefix) {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }

    private static let copyFolderPrefix = "sleeve-copy-"

    private func discardCopyImage() {
        if let folder = copyImage?.folder { try? FileManager.default.removeItem(at: folder) }
        copyImage = nil
    }

    /// Debug builds can run the burn of a copy as a test run, so that the
    /// whole process can be checked without using up a blank.
    private var copyIsSimulated: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "SleeveDebugCopySimulated")
        #else
        false
        #endif
    }
}

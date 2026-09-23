//
//  AppState+Burn.swift
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
//  An image back onto CD (spec §6.10).
//
//  **Untested until the first blank** — the burn itself is the only place
//  in Sleeve that has never run on real hardware. What has been checked is
//  listed in §6.10.1. That is why the test run is the default route and the
//  real burn needs explicit consent.
//

import AppKit
import Foundation
import SwiftUI

enum BurnStage: Sendable, Equatable {
    case idle
    case running(simulated: Bool)
    case done(simulated: Bool)
}

extension AppState {

    // MARK: - Choosing the image

    func showBurnSheet() {
        burnError = nil
        burnStage = .idle
        burnProgress = 0
        isShowingBurnSheet = true
        refreshBurnMedia()
    }

    func chooseBurnImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "cue") ?? .data]
        panel.allowsOtherFileTypes = false
        panel.message = String(localized: "Pick the cue sheet — it names the image file next to it.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadBurnImage(url)
    }

    /// Parses the cue sheet and looks for the audio file next to it.
    func loadBurnImage(_ cueURL: URL) {
        burnError = nil
        burnCue = nil
        burnLayout = nil

        guard let text = try? String(contentsOf: cueURL, encoding: .utf8),
              let cue = CueSheet(text: text) else {
            burnError = String(localized: "This cue sheet could not be read.")
            return
        }
        let audioURL = cueURL.deletingLastPathComponent()
            .appendingPathComponent(cue.audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) else {
            burnError = String(localized: "The image file named in the cue sheet is missing: \(cue.audioFileName)")
            return
        }

        burnCueURL = cueURL
        burnCue = cue
        buildBurnLayout(audioURL: audioURL, cue: cue)
    }

    private func buildBurnLayout(audioURL: URL, cue: CueSheet) {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: audioURL.path(percentEncoded: false))
        let size = (attributes?[.size] as? Int) ?? 0
        guard size > 0 else {
            burnError = String(localized: "The image file is empty.")
            return
        }

        // BIN has no header, WAV the usual 44 bytes. FLAC would have to be
        // unpacked first — `prepareBurn` does that before burning.
        let ext = audioURL.pathExtension.lowercased()
        let header: Int
        switch ext {
        case "bin":  header = 0
        case "wav":  header = 44
        case "flac": header = 0      // only valid after unpacking
        default:
            burnError = String(localized: "Sleeve can burn BIN, WAV and FLAC images.")
            return
        }
        burnNeedsDecoding = ext == "flac"

        let totalSectors = burnNeedsDecoding
            ? cue.tracks.last.map { $0.startLBA + 1 } ?? 0      // only exact after unpacking
            : (size - header) / CDGeometry.bytesPerSector
        burnLayout = CDBurner.Layout(imageURL: audioURL, headerBytes: header,
                                     tracks: cue.tracks,
                                     sectorCounts: cue.sectorCounts(totalSectors: totalSectors))
    }

    // MARK: - Media

    func refreshBurnMedia() {
        let device = CDBurner.firstDevice()
        burnDevice = device.map(CDBurner.info)
        burnMedia = CDBurner.mediaState(of: device)
    }

    /// What currently prevents burning.
    var burnBlocker: String? {
        guard let layout = burnLayout, !layout.tracks.isEmpty else {
            return String(localized: "Pick a cue sheet first.")
        }
        guard let device = burnDevice else { return String(localized: "No optical drive found.") }
        guard device.isUsable else {
            return String(localized: "macOS cannot use this drive for burning.")
        }
        guard case .blank(let free) = burnMedia else { return CDBurner.describe(burnMedia) }
        guard free == 0 || free >= layout.totalSectors else {
            return String(localized: "The image does not fit on this disc.")
        }
        return nil
    }

    var burnTotalDuration: Duration {
        .seconds(Double(burnLayout?.totalSectors ?? 0) / Double(CDGeometry.sectorsPerSecond))
    }

    // MARK: - Burning

    func startBurn(simulated: Bool) {
        guard var layout = burnLayout, burnBlocker == nil, burnTask == nil else { return }

        burnError = nil
        burnProgress = 0
        burnStage = .running(simulated: simulated)

        burnTask = Task {
            // FLAC has to be unpacked first — the drive only takes raw PCM.
            if burnNeedsDecoding {
                guard let decoded = await decodeImageForBurn(layout.imageURL) else {
                    burnError = String(localized: "The FLAC image could not be unpacked.")
                    burnStage = .idle
                    burnTask = nil
                    return
                }
                layout.imageURL = decoded
                layout.headerBytes = 44
            }
            let temporary = burnNeedsDecoding ? layout.imageURL : nil

            for await event in CDBurner.burn(layout, simulated: simulated) {
                switch event {
                case let .progress(fraction):
                    burnProgress = fraction
                case let .finished(wasSimulated):
                    burnStage = .done(simulated: wasSimulated)
                case let .failed(reason):
                    burnError = reason
                    burnStage = .idle
                }
            }
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            burnTask = nil
            refreshBurnMedia()
        }
    }

    func cancelBurn() {
        burnTask?.cancel()
        burnTask = nil
        burnStage = .idle
        burnProgress = 0
    }

    /// Unpacks a FLAC image into a WAV file so that the burner gets raw
    /// sectors.
    private func decodeImageForBurn(_ url: URL) async -> URL? {
        guard let ffmpeg else { return nil }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-burn-\(UUID().uuidString).wav")
        let result = try? await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-loglevel", "error",
            "-i", url.path(percentEncoded: false),
            "-c:a", "pcm_s16le", "-ar", "44100", "-ac", "2",
            target.path(percentEncoded: false),
        ])
        return result?.succeeded == true ? target : nil
    }
}

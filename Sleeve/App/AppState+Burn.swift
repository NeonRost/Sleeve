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
//  Verified on one drive so far (spec §6.10.1). The test run stays the
//  default route and the real burn needs explicit consent: it is the only
//  function that irrevocably uses up something physical.
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

        guard let cue = CueSheet.load(cueURL) else {
            burnError = String(localized: "This cue sheet could not be read.")
            return
        }
        guard cue.fileCount == 1 else {
            burnError = String(localized: "This cue sheet names several files. Sleeve burns images that are a single file.")
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
        // FLAC has to be unpacked first — `startBurn` does that and only
        // then knows the real length. Until then the last track counts as
        // one sector, which is enough to show the track list.
        burnNeedsDecoding = audioURL.pathExtension.lowercased() == "flac"
        if burnNeedsDecoding {
            let total = cue.tracks.last.map { $0.startLBA + 1 } ?? 0
            burnLayout = CDBurner.Layout(imageURL: audioURL, headerBytes: 0,
                                         tracks: cue.tracks,
                                         sectorCounts: cue.sectorCounts(totalSectors: total))
            return
        }

        do {
            let audio = try CDBurner.audioRange(of: audioURL)
            burnLayout = CDBurner.Layout(
                imageURL: audioURL, headerBytes: audio.offset, tracks: cue.tracks,
                sectorCounts: cue.sectorCounts(
                    totalSectors: audio.byteCount / CDGeometry.bytesPerSector))
        } catch CDBurner.ImageProblem.empty {
            burnError = String(localized: "The image file is empty.")
        } catch CDBurner.ImageProblem.notWAV {
            burnError = String(localized: "The image file is not a readable WAV file.")
        } catch CDBurner.ImageProblem.notCDAudio {
            burnError = String(localized: "The image is not CD audio — it has to be 44.1 kHz, 16 bit, stereo.")
        } catch {
            burnError = String(localized: "Sleeve can burn BIN, WAV and FLAC images.")
        }
    }

    // MARK: - Media

    func refreshBurnMedia() {
        #if DEBUG
        // The staged disc's drive also stands in as the burner, still
        // holding the original — no real drive shows in screenshots.
        if DebugHooks.isStagingDisc {
            let staged = BurnDeviceInfo(id: "staged", vendor: "External", product: "DVD Writer",
                                        supportLevel: "", isUsable: true)
            burnDevices = [staged]
            burnDevice = staged
            // -SleeveDebugStageBlank YES: a blank is in, for the burn sheet.
            burnMedia = UserDefaults.standard.bool(forKey: "SleeveDebugStageBlank")
                ? .blank(sectors: 359_844)
                : .unusable(reason: String(localized: "This disc already carries data."))
            return
        }
        #endif
        burnDevices = CDBurner.devices().map(CDBurner.info)
        if let id = burnDeviceID, !burnDevices.contains(where: { $0.id == id }) {
            burnDeviceID = nil
        }
        let device = CDBurner.device(id: burnDeviceID)
        burnDevice = device.map(CDBurner.info)
        burnMedia = CDBurner.mediaState(of: device)
    }

    func selectBurnDevice(_ id: String) {
        burnDeviceID = id
        refreshBurnMedia()
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
        isStoppingBurn = false
        let stop = CDBurner.Stop()
        burnStop = stop

        burnTask = Task {
            var temporary: URL?
            defer {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                burnTask = nil
                burnDecodeTask = nil
                burnStop = nil
                isStoppingBurn = false
            }

            // FLAC has to be unpacked first — the drive only takes raw PCM.
            if burnNeedsDecoding {
                let source = layout.imageURL
                let decoding = Task { await decodeImageForBurn(source) }
                burnDecodeTask = decoding
                temporary = await decoding.value
                guard !stop.isRequested else {
                    burnStage = .idle
                    return
                }
                let attributes = temporary.flatMap {
                    try? FileManager.default.attributesOfItem(atPath: $0.path(percentEncoded: false))
                }
                guard let decoded = temporary, let cue = burnCue,
                      let size = attributes?[.size] as? Int,
                      size >= CDGeometry.bytesPerSector else {
                    burnError = String(localized: "The FLAC image could not be unpacked.")
                    burnStage = .idle
                    return
                }
                // Raw samples, no header to guess at — and only now is the
                // length known, so the track lengths are worked out again.
                layout.imageURL = decoded
                layout.headerBytes = 0
                layout.sectorCounts = cue.sectorCounts(
                    totalSectors: size / CDGeometry.bytesPerSector)
                if case .blank(let free) = burnMedia, free > 0, free < layout.totalSectors {
                    burnError = String(localized: "The image does not fit on this disc.")
                    burnStage = .idle
                    return
                }
            }

            for await event in CDBurner.burn(layout, simulated: simulated,
                                             deviceID: burnDevice?.id, stop: stop) {
                switch event {
                case let .progress(fraction):
                    burnProgress = fraction
                case let .finished(wasSimulated):
                    burnStage = .done(simulated: wasSimulated)
                case let .failed(reason):
                    burnError = reason
                    burnStage = .idle
                case .stopped:
                    burnStage = .idle
                    burnProgress = 0
                }
            }
            refreshBurnMedia()
        }
    }

    /// Asks the burn to stop. The sheet stays on "Stopping…" until the drive
    /// has let go; only then can the next burn start.
    func cancelBurn() {
        guard burnTask != nil else { return }
        isStoppingBurn = true
        burnStop?.request()
        burnDecodeTask?.cancel()
    }

    /// Unpacks a FLAC image into raw samples, the form the burner takes.
    ///
    /// Raw, not WAV: ffmpeg's WAV header is 78 or 140 bytes long depending
    /// on the tags of the source (measured), and every byte of header taken
    /// for audio shifts the whole disc.
    private func decodeImageForBurn(_ url: URL) async -> URL? {
        guard let ffmpeg else { return nil }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-burn-\(UUID().uuidString).raw")
        let result = try? await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-loglevel", "error",
            "-i", url.path(percentEncoded: false),
            "-vn", "-f", "s16le", "-c:a", "pcm_s16le", "-ar", "44100", "-ac", "2",
            target.path(percentEncoded: false),
        ])
        guard result?.succeeded == true else {
            try? FileManager.default.removeItem(at: target)
            return nil
        }
        return target
    }
}

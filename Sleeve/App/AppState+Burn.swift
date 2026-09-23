//
//  AppState+Burn.swift
//  Sleeve
//
//  Ein Abbild zurück auf CD (Spec §6.10).
//
//  **Ungeprüft bis zum ersten Rohling** — der Brennvorgang selbst ist die
//  einzige Stelle in Sleeve, die nie an echter Hardware lief. Was geprüft ist,
//  steht in §6.10.1. Deshalb ist der Probelauf der voreingestellte Weg und der
//  echte Brand braucht eine ausdrückliche Zustimmung.
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

    // MARK: - Abbild wählen

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

    /// Wertet das Cue Sheet aus und sucht die Audiodatei daneben.
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

        // BIN hat keinen Kopf, WAV die üblichen 44 Byte. FLAC müsste erst
        // ausgepackt werden — das macht `prepareBurn` vor dem Brennen.
        let ext = audioURL.pathExtension.lowercased()
        let header: Int
        switch ext {
        case "bin":  header = 0
        case "wav":  header = 44
        case "flac": header = 0      // gilt erst nach dem Auspacken
        default:
            burnError = String(localized: "Sleeve can burn BIN, WAV and FLAC images.")
            return
        }
        burnNeedsDecoding = ext == "flac"

        let totalSectors = burnNeedsDecoding
            ? cue.tracks.last.map { $0.startLBA + 1 } ?? 0      // erst nach dem Auspacken genau
            : (size - header) / CDGeometry.bytesPerSector
        burnLayout = CDBurner.Layout(imageURL: audioURL, headerBytes: header,
                                     tracks: cue.tracks,
                                     sectorCounts: cue.sectorCounts(totalSectors: totalSectors))
    }

    // MARK: - Medium

    func refreshBurnMedia() {
        let device = CDBurner.firstDevice()
        burnDevice = device.map(CDBurner.info)
        burnMedia = CDBurner.mediaState(of: device)
    }

    /// Was den Brand gerade verhindert.
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

    // MARK: - Brennen

    func startBurn(simulated: Bool) {
        guard var layout = burnLayout, burnBlocker == nil, burnTask == nil else { return }

        burnError = nil
        burnProgress = 0
        burnStage = .running(simulated: simulated)

        burnTask = Task {
            // FLAC muss vorher ausgepackt werden — das Laufwerk nimmt nur
            // rohes PCM.
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

    /// Packt ein FLAC-Abbild in eine WAV-Datei aus, damit der Brenner rohe
    /// Sektoren bekommt.
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

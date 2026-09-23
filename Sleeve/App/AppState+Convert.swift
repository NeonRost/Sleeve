//
//  AppState+Convert.swift
//  Sleeve
//
//  Modus „Konvertieren" (Spec §5).
//

import AppKit
import Foundation

extension AppState {

    // MARK: - ffmpeg finden

    /// Sucht ffmpeg nach der Reihenfolge aus Spec §2.2 und erfasst dabei
    /// gleich, welche Encoder dieser Build mitbringt.
    func locateFFmpeg() async {
        guard !isLocatingFFmpeg else { return }
        isLocatingFFmpeg = true
        defer { isLocatingFFmpeg = false }

        let preferred = customFFmpegPath.map { URL(fileURLWithPath: $0) }
        ffmpeg = await ffmpegLocator.locate(preferred: preferred)
        homebrew = await ffmpegLocator.locateHomebrew()

        // Ein Format, das dieses ffmpeg nicht kann, darf nicht ausgewählt
        // bleiben — sonst scheitert der Batch erst beim Start.
        if let ffmpeg, !ffmpeg.supports(conversionSettings.format),
           let fallback = ffmpeg.availableFormats.first {
            conversionSettings.format = fallback
        }
    }

    /// „Manuell auswählen…" aus der Erklärkarte.
    func chooseFFmpegManually() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the ffmpeg executable")
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let tool = await ffmpegLocator.probe(url) else {
            failures.append(SaveFailure(
                filename: url.lastPathComponent,
                message: String(localized: "That file does not look like a working ffmpeg.")
            ))
            isShowingFailureSheet = true
            return
        }
        customFFmpegPath = url.path(percentEncoded: false)
        ffmpeg = tool
    }

    func forgetCustomFFmpegPath() async {
        customFFmpegPath = nil
        await locateFFmpeg()
    }

    // MARK: - Zielordner

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose where the converted files go")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        conversionSettings.destinationFolder = url
    }

    // MARK: - Umwandeln

    /// Fehlt ein Encoder, muss die App das **vor** dem Batch sagen (Spec §2.2).
    var conversionBlocker: String? {
        guard let ffmpeg else {
            return String(localized: "ffmpeg was not found.")
        }
        guard ffmpeg.supports(conversionSettings.format) else {
            return conversionSettings.format.missingEncoderHint
        }
        guard !operationTargets.isEmpty else {
            return String(localized: "No tracks to convert.")
        }
        return nil
    }

    func convert() async {
        guard !isBusy, conversionBlocker == nil, let ffmpeg else { return }

        let targets = operationTargetsInDisplayOrder
        let planner = ConversionPlanner(tool: ffmpeg, settings: conversionSettings)
        let inputs = targets.map {
            ConversionPlanner.Input(trackID: $0.id, url: $0.url, tags: $0.edited)
        }

        let jobs: [ConversionPlanner.Job]
        do {
            jobs = try planner.plan(inputs)
        } catch {
            failures.append(SaveFailure(
                filename: String(localized: "Conversion"),
                message: conversionSettings.format.missingEncoderHint
            ))
            isShowingFailureSheet = true
            return
        }

        isBusy = true
        progress = 0
        progressLabel = "Converting…"
        showsProgress = true      // hier immer, ein Lauf dauert spürbar lange
        failures.removeAll()
        defer {
            finishWork()
            conversionTask = nil
        }

        // Beim Stapel-Konvertieren wird nicht nachgefragt, also wird auch
        // nichts verändert: das Coverbild wandert unangetastet in die neue
        // Datei. Wer es kleiner will, macht das im Tag-Modus je Bild.
        let queue = ConversionQueue(planner: planner, artworkOptions: .passthrough)
        var done = 0

        let task = Task { [weak self] in
            for await outcome in queue.run(jobs) {
                guard let self else { return }
                await self.absorb(outcome)
                done += 1
                self.progress = Double(done) / Double(jobs.count)
                if Task.isCancelled { break }
            }
        }
        conversionTask = task
        await task.value

        if !failures.isEmpty { isShowingFailureSheet = true }
    }

    func cancelConversion() {
        conversionTask?.cancel()
        conversionTask = nil
    }

    /// Ein fertiges Ergebnis in die Liste einarbeiten.
    private func absorb(_ outcome: ConversionQueue.Outcome) async {
        guard let track = trackList.track(id: outcome.trackID) else { return }

        guard let destination = outcome.destination, outcome.succeeded else {
            failures.append(SaveFailure(
                filename: track.filename,
                message: Self.describe(outcome.error)
            ))
            return
        }

        // Die Liste folgt der Konvertierung: derselbe Track, neue Datei.
        // Neu eingelesen, damit Dauer und Bitrate stimmen.
        if let info = try? await engine.read(destination) {
            track.replaceFile(url: destination, info: info)
        } else {
            track.url = destination
        }
    }

    private static func describe(_ error: ConversionQueue.ConversionError?) -> String {
        switch error {
        case .ffmpegFailed(let message):
            message
        case .ffmpegMissing:
            String(localized: "ffmpeg could not be started.")
        case .taggingFailed:
            String(localized: "Converted, but the tags could not be written.")
        case .moveFailed:
            String(localized: "Converted, but the file could not be moved into place.")
        case .none:
            ""
        }
    }
}

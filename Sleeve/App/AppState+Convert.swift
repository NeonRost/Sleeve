//
//  AppState+Convert.swift
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
//  The Convert mode (spec §5).
//

import AppKit
import Foundation

extension AppState {

    // MARK: - Finding ffmpeg

    /// Looks for ffmpeg in the order of spec §2.2 and records right away
    /// which encoders this build has.
    func locateFFmpeg() async {
        guard !isLocatingFFmpeg else { return }
        isLocatingFFmpeg = true
        defer { isLocatingFFmpeg = false }

        let preferred = customFFmpegPath.map { URL(fileURLWithPath: $0) }
        ffmpeg = await ffmpegLocator.locate(preferred: preferred)
        homebrew = await ffmpegLocator.locateHomebrew()

        // A format this ffmpeg cannot do must not stay selected — otherwise
        // the batch only fails at the start.
        if let ffmpeg, !ffmpeg.supports(conversionSettings.format),
           let fallback = ffmpeg.availableFormats.first {
            conversionSettings.format = fallback
        }
    }

    /// "Choose Manually…" from the explanation card.
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

    // MARK: - Target folder

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

    // MARK: - Converting

    /// If an encoder is missing, the app has to say so **before** the batch
    /// (spec §2.2).
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
        showsProgress = true      // always here, a run takes noticeably long
        failures.removeAll()
        defer {
            finishWork()
            conversionTask = nil
        }

        // Batch conversion does not ask, so nothing gets changed either: the
        // cover picture moves into the new file untouched. Whoever wants it
        // smaller does that per picture in tag mode.
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

    /// Works a finished result into the list.
    private func absorb(_ outcome: ConversionQueue.Outcome) async {
        guard let track = trackList.track(id: outcome.trackID) else { return }

        guard let destination = outcome.destination, outcome.succeeded else {
            failures.append(SaveFailure(
                filename: track.filename,
                message: Self.describe(outcome.error)
            ))
            return
        }

        // The list follows the conversion: the same track, a new file.
        // Read again so that duration and bitrate are right.
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

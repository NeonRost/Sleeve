//
//  ConversionQueue.swift
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
//  Carries out the planned invocations (spec §5).
//
//  Per file: ffmpeg writes to a temporary file, then TagLib writes the tags
//  including the cover picture into it, then it moves into place. Only after
//  that is the original deleted, if requested — so a failure can never cost
//  data at any point.
//

import Foundation

struct ConversionQueue: Sendable {

    let planner: ConversionPlanner
    let artworkOptions: ArtworkProcessor.Options

    enum ConversionError: Error, Equatable, Sendable {
        case ffmpegFailed(String)
        case ffmpegMissing
        case taggingFailed
        case moveFailed
    }

    struct Outcome: Sendable {
        var trackID: UUID
        var source: URL
        /// The new path on success.
        var destination: URL?
        var error: ConversionError?
        var succeeded: Bool { error == nil }
    }

    /// Disk throughput is the bottleneck, not the CPU — two to three
    /// processes, no more (spec §5).
    static var recommendedConcurrency: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return cores <= 2 ? 1 : (cores <= 8 ? 2 : 3)
    }

    /// Works through the jobs and reports each result as soon as it is there.
    /// Cancellation happens through the consuming task.
    func run(_ jobs: [ConversionPlanner.Job],
             maxConcurrent: Int = recommendedConcurrency) -> AsyncStream<Outcome> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Outcome.self) { group in
                    var pending = jobs.makeIterator()
                    for _ in 0..<max(1, maxConcurrent) {
                        guard let job = pending.next() else { break }
                        group.addTask { await execute(job) }
                    }
                    while let outcome = await group.next() {
                        continuation.yield(outcome)
                        if Task.isCancelled { break }
                        if let job = pending.next() {
                            group.addTask { await execute(job) }
                        }
                    }
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - One file

    func execute(_ job: ConversionPlanner.Job) async -> Outcome {
        let folder = job.destination.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(
            ".sleeve-convert-\(UUID().uuidString).\(job.destination.pathExtension)"
        )

        func fail(_ error: ConversionError) -> Outcome {
            try? FileManager.default.removeItem(at: temporary)
            return Outcome(trackID: job.trackID, source: job.source,
                           destination: nil, error: error)
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return fail(.moveFailed)
        }

        // ── 1. Convert ──────────────────────────────────────────────────────
        var arguments = job.arguments
        // The last argument is the target path; it points to the temporary file.
        arguments[arguments.count - 1] = temporary.path(percentEncoded: false)

        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(planner.tool.url, arguments: arguments)
        } catch ProcessRunner.RunError.launchFailed {
            return fail(.ffmpegMissing)
        } catch {
            return fail(.ffmpegFailed(String(localized: "Cancelled")))
        }

        guard result.succeeded else {
            return fail(.ffmpegFailed(Self.firstMeaningfulLine(of: result.standardError)))
        }
        guard FileManager.default.fileExists(atPath: temporary.path(percentEncoded: false))
        else {
            return fail(.ffmpegFailed(String(localized: "ffmpeg produced no output file.")))
        }

        // ── 2. Write tags ───────────────────────────────────────────────────
        var tags = job.tags
        tags.artwork = tags.artwork.compactMap {
            ArtworkProcessor.prepare($0.data, pictureType: $0.pictureType,
                                     description: $0.description, options: artworkOptions)
        }
        do {
            // Every field that has a value at all — the target is fresh and has
            // no tags yet, `touchedFields` does not apply here.
            try TagLibBridge.write(tags, fields: Set(TagField.allCases), to: temporary)
        } catch {
            return fail(.taggingFailed)
        }

        // ── 3. Move into place ──────────────────────────────────────────────
        // First to a name that is guaranteed to be free, so that nothing is
        // ever overwritten — not even the source.
        let safeTarget = Self.freePath(for: job.destination, avoiding: [job.source])
        do {
            try FileManager.default.moveItem(at: temporary, to: safeTarget)
        } catch {
            return fail(.moveFailed)
        }

        // ── 4. Remove the original, if requested ────────────────────────────
        var finalURL = safeTarget
        if !planner.settings.keepsOriginals,
           job.source.standardizedFileURL != safeTarget.standardizedFileURL {
            try? FileManager.default.removeItem(at: job.source)
            // If the desired name has become free by now, take it after all.
            if safeTarget != job.destination,
               !FileManager.default.fileExists(atPath: job.destination.path(percentEncoded: false)),
               (try? FileManager.default.moveItem(at: safeTarget, to: job.destination)) != nil {
                finalURL = job.destination
            }
        }

        return Outcome(trackID: job.trackID, source: job.source,
                       destination: finalURL, error: nil)
    }

    // MARK: - Helpers

    /// Appends `" (2)"`, `" (3)"` … until the path is free.
    static func freePath(for url: URL, avoiding blocked: [URL] = []) -> URL {
        let blockedPaths = Set(blocked.map(\.standardizedFileURL.path))
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent

        var candidate = url
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
                || blockedPaths.contains(candidate.standardizedFileURL.path) {
            candidate = folder
                .appendingPathComponent("\(base) (\(counter))")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    /// With `-loglevel error`, ffmpeg often writes several lines; the first
    /// non-empty one is the meaningful one.
    static func firstMeaningfulLine(of text: String) -> String {
        let line = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? String(localized: "ffmpeg reported an unknown error.")
    }
}

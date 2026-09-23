//
//  ConversionQueue.swift
//  Sleeve
//
//  Führt die geplanten Aufrufe aus (Spec §5).
//
//  Ablauf je Datei: ffmpeg schreibt in eine Zwischendatei, dann schreibt
//  TagLib die Tags samt Coverbild hinein, dann wandert sie an ihren Platz.
//  Erst danach wird das Original gelöscht, falls gewünscht — so kann ein
//  Fehlschlag an keiner Stelle Daten kosten.
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
        /// Bei Erfolg der neue Pfad.
        var destination: URL?
        var error: ConversionError?
        var succeeded: Bool { error == nil }
    }

    /// Plattendurchsatz ist der Flaschenhals, nicht die CPU — zwei bis drei
    /// Prozesse, nicht mehr (Spec §5).
    static var recommendedConcurrency: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return cores <= 2 ? 1 : (cores <= 8 ? 2 : 3)
    }

    /// Arbeitet die Aufträge ab und meldet jedes Ergebnis, sobald es vorliegt.
    /// Abbrechen geschieht über die konsumierende Task.
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

    // MARK: - Eine Datei

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

        // ── 1. Umwandeln ────────────────────────────────────────────────────
        var arguments = job.arguments
        // Das letzte Argument ist der Zielpfad; er zeigt auf die Zwischendatei.
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

        // ── 2. Tags schreiben ───────────────────────────────────────────────
        var tags = job.tags
        tags.artwork = tags.artwork.compactMap {
            ArtworkProcessor.prepare($0.data, pictureType: $0.pictureType,
                                     description: $0.description, options: artworkOptions)
        }
        do {
            // Alle Felder, die überhaupt einen Wert haben — das Ziel ist frisch
            // und hat noch gar keine Tags, `touchedFields` gilt hier nicht.
            try TagLibBridge.write(tags, fields: Set(TagField.allCases), to: temporary)
        } catch {
            return fail(.taggingFailed)
        }

        // ── 3. An den Platz schieben ────────────────────────────────────────
        // Zuerst auf einen garantiert freien Namen, damit nie etwas überschrieben
        // wird — auch die Quelle nicht.
        let safeTarget = Self.freePath(for: job.destination, avoiding: [job.source])
        do {
            try FileManager.default.moveItem(at: temporary, to: safeTarget)
        } catch {
            return fail(.moveFailed)
        }

        // ── 4. Original entfernen, falls gewünscht ──────────────────────────
        var finalURL = safeTarget
        if !planner.settings.keepsOriginals,
           job.source.standardizedFileURL != safeTarget.standardizedFileURL {
            try? FileManager.default.removeItem(at: job.source)
            // Ist der Wunschname jetzt frei geworden, nimm ihn doch noch.
            if safeTarget != job.destination,
               !FileManager.default.fileExists(atPath: job.destination.path(percentEncoded: false)),
               (try? FileManager.default.moveItem(at: safeTarget, to: job.destination)) != nil {
                finalURL = job.destination
            }
        }

        return Outcome(trackID: job.trackID, source: job.source,
                       destination: finalURL, error: nil)
    }

    // MARK: - Hilfen

    /// Hängt `" (2)"`, `" (3)"` … an, bis der Pfad frei ist.
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

    /// ffmpeg schreibt bei `-loglevel error` oft mehrere Zeilen; die erste
    /// nicht-leere ist die aussagekräftige.
    static func firstMeaningfulLine(of text: String) -> String {
        let line = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? String(localized: "ffmpeg reported an unknown error.")
    }
}

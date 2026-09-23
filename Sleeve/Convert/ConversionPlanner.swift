//
//  ConversionPlanner.swift
//  Sleeve
//
//  Baut aus Einstellungen und Quelldateien die konkreten ffmpeg-Aufrufe und
//  Zielpfade. Rein rechnend — fasst nichts an, damit sich alles prüfen lässt,
//  bevor ein Prozess startet.
//

import Foundation

struct ConversionPlanner: Sendable {

    let tool: FFmpegTool
    let settings: ConversionSettings

    struct Input: Sendable {
        var trackID: UUID
        var url: URL
        var tags: AudioTags
    }

    struct Job: Sendable, Equatable {
        var trackID: UUID
        var source: URL
        /// Wunschziel. Ist es belegt, weicht die Ausführung aus.
        var destination: URL
        var arguments: [String]
        var tags: AudioTags
    }

    enum PlanError: Error, Equatable {
        case unsupportedFormat(AudioFormat)
    }

    // MARK: - Aufrufparameter

    func arguments(source: URL, destination: URL) throws -> [String] {
        guard let encoder = tool.encoder(for: settings.format) else {
            throw PlanError.unsupportedFormat(settings.format)
        }

        var args = [
            "-nostdin",                 // sonst wartet ffmpeg womöglich auf Eingaben
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", source.path(percentEncoded: false),
            // Das Coverbild ist ein Videostream, kein Metadatum: `-map_metadata`
            // wirft es nicht weg. Wir schreiben es nachher selbst per TagLib,
            // skaliert nach den Einstellungen.
            "-vn",
            // ffmpegs eigene Tag-Übernahme bewusst abschalten — sie ist über
            // Formatgrenzen hinweg unzuverlässig (Spec §5).
            "-map_metadata", "-1",
            "-c:a", encoder,
        ]

        if AudioFormat.experimentalEncoders.contains(encoder) {
            // Native Opus- und Vorbis-Encoder lässt ffmpeg sonst nicht zu.
            args += ["-strict", "-2"]
        }
        if settings.format.supportsBitrate {
            args += ["-b:a", "\(settings.bitrate)k"]
        }
        if settings.format.supportsCompressionLevel {
            args += ["-compression_level", "\(settings.compressionLevel)"]
        }

        args.append(destination.path(percentEncoded: false))
        return args
    }

    // MARK: - Zielpfade

    /// Wunschname ohne Rücksicht auf Kollisionen — die löst die Ausführung
    /// auf, weil sich der Bestand auf der Platte bis dahin ändern kann.
    func destination(for input: Input) -> URL {
        let folder = settings.destinationFolder ?? input.url.deletingLastPathComponent()

        var base = input.url.deletingPathExtension().lastPathComponent
        if !settings.filenamePattern.isEmpty,
           PatternSyntax.containsToken(settings.filenamePattern) {
            let rendered = PatternRenderer().render(settings.filenamePattern, tags: input.tags)
            if !rendered.isEmpty { base = rendered }
        }

        return folder
            .appendingPathComponent(base)
            .appendingPathExtension(settings.format.fileExtension)
    }

    func plan(_ inputs: [Input]) throws -> [Job] {
        try inputs.map { input in
            let destination = destination(for: input)
            return Job(
                trackID: input.trackID,
                source: input.url,
                destination: destination,
                arguments: try arguments(source: input.url, destination: destination),
                tags: input.tags
            )
        }
    }
}

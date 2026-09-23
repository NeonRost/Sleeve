//
//  FFmpegLocator.swift
//  Sleeve
//
//  ffmpeg wird nicht mitgeliefert, sondern vom System erwartet (Spec §2.2).
//  Damit der Konvertieren-Modus nicht stumm scheitert, wird es gesucht,
//  geprüft und sein Encoder-Bestand einmalig erfasst.
//

import Foundation

struct FFmpegTool: Sendable, Equatable {
    var url: URL
    /// Nur die Versionsnummer, z. B. "9.0.1".
    var version: String
    /// Vollständige erste Zeile von `ffmpeg -version`.
    var banner: String
    /// Alle verfügbaren Audio-Encoder, einmalig abgefragt und gehalten.
    var audioEncoders: Set<String>

    /// Der erste Encoder, den dieses ffmpeg für das Format anbietet.
    func encoder(for format: AudioFormat) -> String? {
        format.encoderCandidates.first { audioEncoders.contains($0) }
    }

    func supports(_ format: AudioFormat) -> Bool {
        encoder(for: format) != nil
    }

    var availableFormats: [AudioFormat] {
        AudioFormat.allCases.filter(supports)
    }
}

actor FFmpegLocator {

    /// Suchreihenfolge nach Spec §2.2. `PATH` allein reicht nicht: eine per
    /// Finder gestartete App erbt die Shell-Umgebung nicht und sieht die
    /// Homebrew-Pfade dort gar nicht.
    static let wellKnownPaths = [
        "/opt/homebrew/bin/ffmpeg",   // Apple-Silicon-Homebrew
        "/usr/local/bin/ffmpeg",      // Intel-Homebrew oder von Hand installiert
    ]

    /// Sucht ffmpeg und prüft es gleich mit.
    /// - Parameter preferred: Pfad aus den Einstellungen, falls gesetzt.
    func locate(preferred: URL? = nil) async -> FFmpegTool? {
        for candidate in candidates(preferred: preferred) {
            if let tool = await probe(candidate) { return tool }
        }
        return nil
    }

    /// Wo Homebrew selbst liegt — wenn überhaupt.
    ///
    /// Ohne diese Prüfung würde die Erklärkarte `brew install ffmpeg`
    /// vorschlagen, auch wenn gar kein brew installiert ist. Dann läuft die
    /// Anleitung ins Leere, und der Nutzer sucht den Fehler bei sich.
    static let homebrewPaths = [
        "/opt/homebrew/bin/brew",   // Apple Silicon
        "/usr/local/bin/brew",      // Intel
    ]

    func locateHomebrew() -> URL? {
        for path in Self.homebrewPaths
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Prüft genau einen Pfad — für „Manuell auswählen…".
    func probe(_ url: URL) async -> FFmpegTool? {
        guard FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false))
        else { return nil }

        guard let versionRun = try? await ProcessRunner.run(url, arguments: ["-version"]),
              versionRun.succeeded
        else { return nil }

        let banner = versionRun.standardOutput
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard banner.lowercased().contains("ffmpeg version") else { return nil }

        return FFmpegTool(
            url: url,
            version: Self.parseVersion(from: banner),
            banner: banner,
            audioEncoders: await audioEncoders(of: url)
        )
    }

    // MARK: - Intern

    private func candidates(preferred: URL?) -> [URL] {
        var result: [URL] = []
        if let preferred { result.append(preferred) }
        result += Self.wellKnownPaths.map { URL(fileURLWithPath: $0) }
        result += Self.pathEntries()
        // Reihenfolge erhalten, Doppelte entfernen.
        var seen: Set<String> = []
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func pathEntries() -> [URL] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("ffmpeg") }
    }

    /// `ffmpeg -encoders` listet Zeilen der Form
    /// ` A....D libmp3lame           libmp3lame MP3 …`.
    /// Das erste Zeichen des Flag-Blocks sagt, ob es ein Audio-Encoder ist.
    private func audioEncoders(of url: URL) async -> Set<String> {
        guard let run = try? await ProcessRunner.run(url, arguments: ["-hide_banner", "-encoders"]),
              run.succeeded
        else { return [] }

        var result: Set<String> = []
        for line in run.standardOutput.split(separator: "\n") {
            guard line.hasPrefix(" A") else { continue }
            let fields = line.dropFirst(7).split(separator: " ", maxSplits: 1,
                                                omittingEmptySubsequences: true)
            guard let name = fields.first, !name.isEmpty else { continue }
            result.insert(String(name))
        }
        return result
    }

    static func parseVersion(from banner: String) -> String {
        // "ffmpeg version 9.0.1 Copyright …" oder "ffmpeg version n7.1-… "
        let parts = banner.split(separator: " ")
        guard parts.count >= 3 else { return "?" }
        return String(parts[2])
    }
}

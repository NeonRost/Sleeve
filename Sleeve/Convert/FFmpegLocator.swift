//
//  FFmpegLocator.swift
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
//  ffmpeg is not shipped but expected on the system (spec §2.2). So that
//  the Convert mode does not fail silently, it is located, checked, and its
//  encoders are listed once.
//

import Foundation

struct FFmpegTool: Sendable, Equatable {
    var url: URL
    /// Just the version number, e.g. "9.0.1".
    var version: String
    /// Full first line of `ffmpeg -version`.
    var banner: String
    /// All available audio encoders, queried once and kept.
    var audioEncoders: Set<String>

    /// The first encoder this ffmpeg offers for the format.
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

    /// Search order as in spec §2.2. `PATH` alone is not enough: an app
    /// launched from the Finder does not inherit the shell environment and
    /// does not see the Homebrew paths there at all.
    static let wellKnownPaths = [
        "/opt/homebrew/bin/ffmpeg",   // Apple Silicon Homebrew
        "/usr/local/bin/ffmpeg",      // Intel Homebrew or installed by hand
    ]

    /// Looks for ffmpeg and checks it right away.
    /// - Parameter preferred: path from the settings, if set.
    func locate(preferred: URL? = nil) async -> FFmpegTool? {
        for candidate in candidates(preferred: preferred) {
            if let tool = await probe(candidate) { return tool }
        }
        return nil
    }

    /// Where Homebrew itself lives — if anywhere.
    ///
    /// Without this check the explanation card would suggest
    /// `brew install ffmpeg` even when brew is not installed at all. The
    /// instructions then lead nowhere, and the user looks for the mistake
    /// on their side.
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

    /// Checks exactly one path — for "Choose Manually…".
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

    // MARK: - Internal

    private func candidates(preferred: URL?) -> [URL] {
        var result: [URL] = []
        if let preferred { result.append(preferred) }
        result += Self.wellKnownPaths.map { URL(fileURLWithPath: $0) }
        result += Self.pathEntries()
        // Keep the order, drop duplicates.
        var seen: Set<String> = []
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func pathEntries() -> [URL] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("ffmpeg") }
    }

    /// `ffmpeg -encoders` lists lines of the form
    /// ` A....D libmp3lame           libmp3lame MP3 …`.
    /// The first character of the flag block says whether it is an audio
    /// encoder.
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
        // "ffmpeg version 9.0.1 Copyright …" or "ffmpeg version n7.1-… "
        let parts = banner.split(separator: " ")
        guard parts.count >= 3 else { return "?" }
        return String(parts[2])
    }
}

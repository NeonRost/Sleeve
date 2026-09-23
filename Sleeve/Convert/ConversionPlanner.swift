//
//  ConversionPlanner.swift
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
//  Turns settings and source files into concrete ffmpeg invocations and
//  target paths. Pure computation — touches nothing, so everything can be
//  checked before a process starts.
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
        /// Desired target. If it is taken, execution picks another name.
        var destination: URL
        var arguments: [String]
        var tags: AudioTags
    }

    enum PlanError: Error, Equatable {
        case unsupportedFormat(AudioFormat)
    }

    // MARK: - Arguments

    func arguments(source: URL, destination: URL) throws -> [String] {
        guard let encoder = tool.encoder(for: settings.format) else {
            throw PlanError.unsupportedFormat(settings.format)
        }

        var args = [
            "-nostdin",                 // otherwise ffmpeg may wait for input
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", source.path(percentEncoded: false),
            // The cover picture is a video stream, not metadata: `-map_metadata`
            // does not drop it. We write it ourselves afterwards via TagLib, scaled
            // according to the settings.
            "-vn",
            // Deliberately switch off ffmpeg's own tag copying — it is unreliable
            // across format boundaries (spec §5).
            "-map_metadata", "-1",
            "-c:a", encoder,
        ]

        if AudioFormat.experimentalEncoders.contains(encoder) {
            // ffmpeg does not allow the native Opus and Vorbis encoders otherwise.
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

    // MARK: - Target paths

    /// Desired name regardless of collisions — execution resolves those,
    /// because what is on disk may change until then.
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

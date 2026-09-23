//
//  AudioFormat.swift
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
//  Target formats for the Convert mode (spec §5).
//

import Foundation

enum AudioFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
    case mp3, aac, alac, flac, opus, vorbis, wav, aiff

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mp3:    "MP3"
        case .aac:    "AAC"
        case .alac:   "Apple Lossless"
        case .flac:   "FLAC"
        case .opus:   "Opus"
        case .vorbis: "Vorbis"
        case .wav:    "WAV"
        case .aiff:   "AIFF"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp3:    "mp3"
        case .aac:    "m4a"
        case .alac:   "m4a"
        case .flac:   "flac"
        case .opus:   "opus"
        case .vorbis: "ogg"
        case .wav:    "wav"
        case .aiff:   "aiff"
        }
    }

    var isLossless: Bool {
        switch self {
        case .alac, .flac, .wav, .aiff: true
        default: false
        }
    }

    /// Encoders in order of preference.
    ///
    /// AAC via AudioToolbox first: Apple has licensed the patents, and an LGPL
    /// ffmpeg often has no usable AAC encoder at all (spec §6.7). ALAC, on the
    /// other hand, is open and patent-free — there the native encoder is the
    /// more reliable choice.
    var encoderCandidates: [String] {
        switch self {
        case .mp3:    ["libmp3lame"]
        case .aac:    ["aac_at", "aac"]
        case .alac:   ["alac", "alac_at"]
        case .flac:   ["flac"]
        case .opus:   ["libopus", "opus"]
        case .vorbis: ["libvorbis", "vorbis"]
        case .wav:    ["pcm_s16le"]
        case .aiff:   ["pcm_s16be"]
        }
    }

    /// Encoders ffmpeg only allows with `-strict -2`. Without it the call
    /// aborts with "is experimental and might produce bad results".
    static let experimentalEncoders: Set<String> = ["opus", "vorbis"]

    var supportsBitrate: Bool { !isLossless }

    var bitrates: [Int] {
        switch self {
        case .mp3:    [128, 160, 192, 256, 320]
        case .aac:    [128, 160, 192, 256, 320]
        case .opus:   [96, 128, 160, 192, 256]
        case .vorbis: [128, 160, 192, 256, 320]
        default:      []
        }
    }

    var defaultBitrate: Int {
        switch self {
        case .opus: 160
        default:    256
        }
    }

    /// Only FLAC has an adjustable compression level.
    var supportsCompressionLevel: Bool { self == .flac }

    /// Why a format may be unavailable — for the explanation in the UI.
    var missingEncoderHint: String {
        switch self {
        case .mp3:
            String(localized: "This ffmpeg was built without libmp3lame and cannot write MP3.")
        case .aac:
            String(localized: "This ffmpeg has no AAC encoder.")
        case .vorbis:
            String(localized: "This ffmpeg was built without libvorbis.")
        case .opus:
            String(localized: "This ffmpeg was built without libopus.")
        default:
            String(localized: "This ffmpeg has no encoder for this format.")
        }
    }
}

/// Settings of one conversion run.
struct ConversionSettings: Equatable, Sendable {
    var format: AudioFormat = .mp3
    var bitrate: Int = 256
    /// FLAC compression level, 0–12.
    var compressionLevel: Int = 5
    /// `nil` means: next to the original.
    var destinationFolder: URL?
    /// Empty means: keep the original's file name.
    var filenamePattern: String = ""
    var keepsOriginals = true
}

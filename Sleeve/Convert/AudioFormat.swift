//
//  AudioFormat.swift
//  Sleeve
//
//  Zielformate für den Konvertieren-Modus (Spec §5).
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

    /// Encoder in der Reihenfolge, in der sie bevorzugt werden.
    ///
    /// AAC zuerst über AudioToolbox: Apple hat die Patente lizenziert, und ein
    /// LGPL-ffmpeg bringt oft gar keinen brauchbaren AAC-Encoder mit (Spec §6.4).
    /// ALAC dagegen ist offen und patentfrei — da ist der native Encoder die
    /// verlässlichere Wahl.
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

    /// Encoder, die ffmpeg nur mit `-strict -2` zulässt. Ohne das bricht der
    /// Aufruf mit „is experimental and might produce bad results" ab.
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

    /// Nur FLAC kennt eine einstellbare Packdichte.
    var supportsCompressionLevel: Bool { self == .flac }

    /// Warum ein Format fehlen kann — für die Erklärung in der Oberfläche.
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

/// Einstellungen eines Konvertierungslaufs.
struct ConversionSettings: Equatable, Sendable {
    var format: AudioFormat = .mp3
    var bitrate: Int = 256
    /// FLAC-Packdichte, 0–12.
    var compressionLevel: Int = 5
    /// `nil` bedeutet: neben das Original legen.
    var destinationFolder: URL?
    /// Leer bedeutet: Dateiname des Originals behalten.
    var filenamePattern: String = ""
    var keepsOriginals = true
}

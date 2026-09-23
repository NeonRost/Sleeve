//
//  RipSettings.swift
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

import Foundation

enum RipMode: String, CaseIterable, Identifiable, Sendable {
    /// One pass, no verification. For clean discs and when in a hurry.
    case burst
    /// Every block is read at least twice and compared; on a mismatch
    /// reading is repeated until a majority emerges.
    case secure

    var id: String { rawValue }

    /// Short — the text sits in the picker and would be cut off otherwise.
    var label: LocalizedStringResource {
        switch self {
        case .burst:  "Burst"
        case .secure: "Secure"
        }
    }

    /// The explanation sits below the picker, not in it.
    var explanation: LocalizedStringResource {
        switch self {
        case .burst:  "One pass, no verification. For clean discs and when time matters."
        case .secure: "Reads every block twice and repeats where the results differ."
        }
    }
}

struct RipSettings: Equatable, Sendable {
    var mode: RipMode = .secure
    /// How often a disputed block is re-read at most.
    var maxRetries: Int = 20
    /// Read C2 error pointers as well. Not every drive delivers them
    /// reliably, so this can be switched off.
    var usesC2 = false
    /// The drive's read offset in samples. Corrected for while reading.
    var readOffset = 0
    /// Read speed as a multiple; `nil` leaves it to the drive.
    var speedMultiplier: Int?
    /// Read every track twice completely and compare the checksums. Takes
    /// twice as long and needs no external database.
    var testBeforeCopy = false
    /// Read ISRC and MCN from the subchannel. Some drives take noticeably
    /// long for it.
    var readsSubchannel = true
    var writesLog = true
    var writesCueSheet = false
    var ejectsWhenDone = false

    // MARK: Output

    /// Target format. WAV means: store as read from the disc — then ffmpeg
    /// is not needed at all.
    var format: AudioFormat = .flac
    var bitrate = 256
    var compressionLevel = 5
    /// Empty means: just the two-digit track number.
    var filenamePattern = RipSettings.defaultFilenamePattern

    /// Deliberately short. Artist and album are already in the folder name;
    /// repeating them in every file name makes long names for no gain.
    static let defaultFilenamePattern = "%track% - %title%"

    var needsFFmpeg: Bool { format != .wav }
    /// Set while ripping when C2 was requested but the drive does not
    /// deliver it. Belongs in the log, not in the preferences.
    var c2WasRequestedButUnavailable = false

    // MARK: - Persistence

    private enum Key {
        static let mode = "rip.mode"
        static let retries = "rip.maxRetries"
        static let c2 = "rip.usesC2"
        static let offset = "rip.readOffset"
        static let speed = "rip.speedMultiplier"
        static let test = "rip.testBeforeCopy"
        static let subchannel = "rip.readsSubchannel"
        static let log = "rip.writesLog"
        static let cue = "rip.writesCueSheet"
        static let eject = "rip.ejectsWhenDone"
        static let format = "rip.format"
        static let bitrate = "rip.bitrate"
        static let compression = "rip.compressionLevel"
        static let pattern = "rip.filenamePattern"
    }

    static func load(from defaults: UserDefaults = .standard) -> RipSettings {
        var settings = RipSettings()
        if let raw = defaults.string(forKey: Key.mode), let mode = RipMode(rawValue: raw) {
            settings.mode = mode
        }
        if defaults.object(forKey: Key.retries) != nil {
            settings.maxRetries = max(1, min(100, defaults.integer(forKey: Key.retries)))
        }
        settings.usesC2 = defaults.bool(forKey: Key.c2)
        settings.readOffset = defaults.integer(forKey: Key.offset)
        // 0 is a valid value meaning "automatic", hence via object(forKey:).
        settings.speedMultiplier = defaults.object(forKey: Key.speed) as? Int
        settings.testBeforeCopy = defaults.bool(forKey: Key.test)
        settings.readsSubchannel = defaults.object(forKey: Key.subchannel) as? Bool ?? true
        settings.writesLog = defaults.object(forKey: Key.log) as? Bool ?? true
        settings.writesCueSheet = defaults.bool(forKey: Key.cue)
        settings.ejectsWhenDone = defaults.bool(forKey: Key.eject)
        settings.format = AudioFormat(rawValue: defaults.string(forKey: Key.format) ?? "")
            ?? .flac
        if defaults.object(forKey: Key.bitrate) != nil {
            settings.bitrate = defaults.integer(forKey: Key.bitrate)
        }
        if defaults.object(forKey: Key.compression) != nil {
            settings.compressionLevel = defaults.integer(forKey: Key.compression)
        }
        settings.filenamePattern = defaults.object(forKey: Key.pattern) as? String
            ?? defaultFilenamePattern
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(maxRetries, forKey: Key.retries)
        defaults.set(usesC2, forKey: Key.c2)
        defaults.set(readOffset, forKey: Key.offset)
        if let speedMultiplier {
            defaults.set(speedMultiplier, forKey: Key.speed)
        } else {
            defaults.removeObject(forKey: Key.speed)
        }
        defaults.set(testBeforeCopy, forKey: Key.test)
        defaults.set(readsSubchannel, forKey: Key.subchannel)
        defaults.set(writesLog, forKey: Key.log)
        defaults.set(writesCueSheet, forKey: Key.cue)
        defaults.set(ejectsWhenDone, forKey: Key.eject)
        defaults.set(format.rawValue, forKey: Key.format)
        defaults.set(bitrate, forKey: Key.bitrate)
        defaults.set(compressionLevel, forKey: Key.compression)
        defaults.set(filenamePattern, forKey: Key.pattern)
    }
}

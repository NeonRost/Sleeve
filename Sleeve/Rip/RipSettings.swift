//
//  RipSettings.swift
//  Sleeve
//

import Foundation

enum RipMode: String, CaseIterable, Identifiable, Sendable {
    /// Ein Durchgang, keine Prüfung. Für saubere Scheiben und Eile.
    case burst
    /// Jeder Block wird mindestens zweimal gelesen und verglichen; bei
    /// Abweichung wird wiederholt, bis sich eine Mehrheit findet.
    case secure

    var id: String { rawValue }

    /// Kurz — der Text steht im Auswahlmenü und wird sonst abgeschnitten.
    var label: LocalizedStringResource {
        switch self {
        case .burst:  "Burst"
        case .secure: "Secure"
        }
    }

    /// Die Erklärung steht unter der Auswahl, nicht darin.
    var explanation: LocalizedStringResource {
        switch self {
        case .burst:  "One pass, no verification. For clean discs and when time matters."
        case .secure: "Reads every block twice and repeats where the results differ."
        }
    }
}

struct RipSettings: Equatable, Sendable {
    var mode: RipMode = .secure
    /// Wie oft ein strittiger Block höchstens neu gelesen wird.
    var maxRetries: Int = 20
    /// C2-Fehlerzeiger mitlesen. Nicht jedes Laufwerk liefert sie
    /// zuverlässig, deshalb abschaltbar.
    var usesC2 = false
    /// Leseversatz des Laufwerks in Samples. Wird beim Lesen herausgerechnet.
    var readOffset = 0
    /// Lesegeschwindigkeit als Vielfaches; `nil` überlässt sie dem Laufwerk.
    var speedMultiplier: Int?
    /// Jede Spur zweimal vollständig lesen und die Prüfsummen vergleichen.
    /// Kostet die doppelte Zeit und braucht keine fremde Datenbank.
    var testBeforeCopy = false
    /// ISRC und MCN aus dem Subchannel lesen. Manche Laufwerke brauchen
    /// dafür spürbar lange.
    var readsSubchannel = true
    var writesLog = true
    var writesCueSheet = false
    var ejectsWhenDone = false

    // MARK: Ausgabe

    /// Zielformat. WAV heißt: so ablegen, wie von der Scheibe gelesen — dann
    /// wird ffmpeg gar nicht gebraucht.
    var format: AudioFormat = .flac
    var bitrate = 256
    var compressionLevel = 5
    /// Leer heißt: nur die zweistellige Tracknummer.
    var filenamePattern = RipSettings.defaultFilenamePattern

    /// Bewusst knapp. Interpret und Album stehen schon im Ordnernamen; sie
    /// in jeden Dateinamen zu wiederholen macht lange Namen ohne Gewinn.
    static let defaultFilenamePattern = "%track% - %title%"

    var needsFFmpeg: Bool { format != .wav }
    /// Wird beim Rippen gesetzt, wenn C2 gewünscht war, das Laufwerk es aber
    /// nicht liefert. Gehört ins Protokoll, nicht in die Voreinstellungen.
    var c2WasRequestedButUnavailable = false

    // MARK: - Sichern

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
        // 0 ist ein gültiger Wert für „automatisch", deshalb über object(forKey:).
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

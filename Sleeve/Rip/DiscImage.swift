//
//  DiscImage.swift
//  Sleeve
//
//  Ein Abbild der ganzen Scheibe statt einzelner Spuren (Spec §9.1).
//
//  **Kein ISO.** Eine Audio-CD trägt kein Dateisystem: bei Sektor 16, wo der
//  ISO-9660-Volume-Descriptor stünde, steht Musik statt der Kennung `CD001`.
//  Und von den 2352 Byte eines CDDA-Sektors sind alle 2352 Audio — ein
//  ISO-Container mit seinen 2048 Byte Nutzdaten würde ein Achtel wegwerfen.
//
//  Das passende Format ist ein durchgehender Audiostrom plus Cue Sheet mit
//  den Trackgrenzen.
//

import Foundation

enum DiscImageFormat: String, CaseIterable, Identifiable, Sendable {
    /// Roh, 2352 Byte je Sektor, ohne jeden Kopf. Das klassische BIN.
    case bin
    /// Dasselbe mit 44-Byte-WAV-Kopf — von jedem Abspielprogramm zu öffnen.
    case wav
    /// Verlustfrei gepackt, rund ein Drittel kleiner.
    case flac

    var id: String { rawValue }
    var fileExtension: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .bin:  "BIN — raw, as on the disc"
        case .wav:  "WAV — raw with a header"
        case .flac: "FLAC — lossless, smaller"
        }
    }

    /// Wofür das Format taugt — und wofür nicht.
    ///
    /// Gemessen mit VLC 3.0.23: bei `.bin` **und** bei `.cue` greift VLC zum
    /// `ps`-Demuxer (MPEG-Programmstrom), also zum Raten; nur die WAV bekommt
    /// den richtigen. Ohne diesen Hinweis wählt man BIN — „roh, wie auf der
    /// CD" klingt nach der treuesten Wahl — und wundert sich dann, dass sich
    /// nichts abspielen lässt.
    var hint: LocalizedStringResource {
        switch self {
        case .bin:
            "Exact copy for archiving or burning. Most players do not recognise a raw .bin — open the cue sheet instead, in a program that understands one."
        case .wav:
            "Plays in any program. The cue sheet next to it marks the track boundaries."
        case .flac:
            "Like WAV, about a third smaller, and just as lossless."
        }
    }

    /// Was im Cue Sheet hinter dem Dateinamen steht. `BINARY` für den rohen
    /// Strom, `WAVE` für alles mit Kopf — auch für FLAC, so halten es die
    /// gängigen Abspielprogramme.
    var cueFileType: String {
        self == .bin ? "BINARY" : "WAVE"
    }

    /// FLAC entsteht aus dem WAV-Zwischenstand und braucht deshalb ffmpeg.
    var needsFFmpeg: Bool { self == .flac }
}

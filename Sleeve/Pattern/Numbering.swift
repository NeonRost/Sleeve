//
//  Numbering.swift
//  Sleeve
//
//  Nummerierung (Spec §4.2).
//

import Foundation

struct NumberingOptions: Equatable, Sendable {
    /// Gesamtanzahl mitschreiben (03/12).
    var writesTotal = true
    /// Pro Disc neu bei 1 beginnen statt disc-übergreifend durchzuzählen.
    var restartsPerDisc = false
    /// Führende Nullen im Dateinamen (01 statt 1).
    var padsNumbers = true
    var startsAt = 1
}

enum Numbering {

    /// Nummeriert in der übergebenen Reihenfolge durch — die ist die aktuelle
    /// Sortierung der Tabelle, nicht die Ladereihenfolge.
    @MainActor
    static func apply(_ options: NumberingOptions, to tracks: [TrackFile]) {
        guard !tracks.isEmpty else { return }

        if options.restartsPerDisc {
            // Nach Disc gruppieren, Reihenfolge innerhalb der Gruppe erhalten.
            var groups: [Int: [TrackFile]] = [:]
            for track in tracks {
                groups[track.edited.discNumber ?? 1, default: []].append(track)
            }
            for group in groups.values {
                number(group, options: options)
            }
        } else {
            number(tracks, options: options)
        }
    }

    @MainActor
    private static func number(_ tracks: [TrackFile], options: NumberingOptions) {
        let total = tracks.count
        for (index, track) in tracks.enumerated() {
            track.set(String(options.startsAt + index), for: .trackNumber)
            if options.writesTotal {
                track.set(String(options.startsAt + total - 1), for: .trackTotal)
            }
        }
    }
}

//
//  TrackListing.swift
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
//  A track list from outside — from MusicBrainz, Discogs or pasted text —
//  and how it is laid onto the tracks found (spec §7.12).
//
//  The sources deliver different things: MusicBrainz knows the **length**
//  of every track, a YouTube description the **start time**. Either is
//  enough to align the boundaries — and either finds transitions where
//  there is no silence.
//

import Foundation

struct TrackListing: Equatable, Sendable {

    struct Entry: Equatable, Sendable {
        var title: String
        /// From a pasted list.
        var start: Double?
        /// From MusicBrainz or Discogs.
        var duration: Double?
    }

    var entries: [Entry]
    var album: String?
    var artist: String?
    var year: Int?
    var genre: String?

    var hasStarts: Bool { !entries.isEmpty && entries.allSatisfy { $0.start != nil } }
    var hasDurations: Bool { !entries.isEmpty && entries.allSatisfy { $0.duration != nil } }

    // MARK: - Pasted text

    /// Reads a track list as found below album videos:
    ///
    ///     Beast City 0:00
    ///     Vision (ISM∞Version) 1:35
    ///     01. Chemical – 5:16
    ///     [9:32] Spiral Cave
    ///
    /// Lines without a time are skipped — headings, links, the total length in
    /// parentheses. The time may be at the front or at the end.
    init(pasted text: String) {
        var result: [Entry] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let match = line.range(of: #"(?<![\d:])(\d{1,2}:)?\d{1,2}:\d{2}(?![\d:])"#,
                                         options: .regularExpression),
                  let seconds = Timecode.parse(String(line[match]))
            else { continue }

            var title = line
            title.removeSubrange(match)
            title = Self.clean(title)
            // "(44:49)" has no title left once the time is removed — that is the
            // total length, not a track.
            guard !title.isEmpty else { continue }
            result.append(Entry(title: title, start: seconds, duration: nil))
        }
        // A track list runs forwards. Whatever jumps backwards is something
        // else — a comment, a second list.
        var ordered: [Entry] = []
        for entry in result where (entry.start ?? 0) >= (ordered.last?.start ?? -1) {
            ordered.append(entry)
        }
        self.entries = ordered
    }

    init(entries: [Entry], album: String? = nil, artist: String? = nil, year: Int? = nil,
         genre: String? = nil) {
        self.entries = entries
        self.album = album
        self.artist = artist
        self.year = year
        self.genre = genre
    }

    /// Removes the punctuation and numbering left around the title:
    /// "01. ", " – ", "[]", "()".
    private static func clean(_ text: String) -> String {
        var title = text
        title = title.replacingOccurrences(of: #"[\[\(]\s*[\]\)]"#, with: "",
                                           options: .regularExpression)
        let edge = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—|:·•.,"))
        title = title.trimmingCharacters(in: edge)
        // Leading number ("01.", "1)", "#3") — but not when the title itself
        // is a number.
        if let number = title.range(of: #"^#?\d{1,3}[.)]\s+"#, options: .regularExpression) {
            title.removeSubrange(number)
        }
        return title.trimmingCharacters(in: edge)
    }

    // MARK: - From a release

    init(release: LookupRelease, genreSource: GenreSource = .style) {
        self.entries = release.tracks.map {
            Entry(title: $0.title ?? "", start: nil,
                  duration: $0.duration.flatMap { Timecode.parse($0) })
        }
        self.album = release.title
        self.artist = release.albumArtist
        self.year = release.year
        self.genre = genreSource.value(from: release)
    }

    /// Which tag fields this list can fill. A pasted list only knows titles;
    /// an album from MusicBrainz or Discogs usually everything.
    var availableFields: Set<TagField> {
        var fields: Set<TagField> = entries.contains { !$0.title.isEmpty } ? [.title] : []
        if artist != nil { fields.insert(.artist) }
        if album != nil { fields.insert(.album) }
        if year != nil { fields.insert(.year) }
        if genre != nil { fields.insert(.genre) }
        return fields
    }

    /// What the Track Splitter can take over from a list.
    static let takeOverFields: [TagField] = [.title, .artist, .album, .year, .genre]
}

// MARK: - Aligning boundaries

extension AudioSplitter {

    /// How far a time may be from a detected silence to snap to it. Uploaders
    /// write whole seconds, often into the middle of the pause.
    static let snapTolerance: Double = 5

    /// Every position where detection would place a cut — before thinning.
    /// Aligned boundaries snap to these.
    static func candidateCuts(silences: [SilenceInterval], duration: Double,
                              levels: WaveformSampler.Waveform?) -> [Double] {
        bridge(silences.sorted { $0.start < $1.start }, within: noiseLength)
            .filter { $0.start >= edgeBuffer && $0.end <= duration - edgeBuffer }
            .map { cutPosition(in: $0, levels: levels) }
    }

    /// Boundaries from **start times** — each snapped on its own.
    static func alignedRanges(starts: [Double], duration: Double,
                              candidates: [Double]) -> [TrackRange] {
        guard !starts.isEmpty else { return [] }
        var bounds = [0.0]
        for start in starts.dropFirst() {
            bounds.append(snap(start, to: candidates))
        }
        return ranges(from: bounds, duration: duration)
    }

    /// Boundaries from **lengths** — added up continuously, but each one
    /// computed anew from its snapped predecessor. Adding up blindly would
    /// carry an error forward with every track: a YouTube recording rarely has
    /// the same pauses as the CD the lengths refer to.
    static func alignedRanges(durations: [Double], duration: Double,
                              candidates: [Double]) -> [TrackRange] {
        guard !durations.isEmpty else { return [] }
        var bounds = [0.0]
        for length in durations.dropLast() {
            bounds.append(snap(bounds.last! + length, to: candidates))
        }
        return ranges(from: bounds, duration: duration)
    }

    private static func snap(_ target: Double, to candidates: [Double]) -> Double {
        guard let nearest = candidates.min(by: { abs($0 - target) < abs($1 - target) }),
              abs(nearest - target) <= snapTolerance else { return target }
        return nearest
    }

    /// Turns boundaries into gapless tracks; unusable ones — outside the file
    /// or going backwards — are dropped.
    private static func ranges(from bounds: [Double], duration: Double) -> [TrackRange] {
        var clean: [Double] = []
        for bound in bounds where bound >= 0 && bound < duration {
            if let last = clean.last, bound <= last + 0.5 { continue }
            clean.append(bound)
        }
        return clean.indices.map { index in
            TrackRange(start: clean[index],
                       end: index + 1 < clean.count ? clean[index + 1] : duration)
        }
    }
}

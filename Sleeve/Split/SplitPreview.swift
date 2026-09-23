//
//  SplitPreview.swift
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
//  Listening briefly across a track boundary (spec §7.8).
//
//  **Not an audio player.** No scrubbing, no volume, no playlist. The only
//  question that comes up when splitting is "is this boundary in the right
//  place", and one answers it by listening a few seconds **across** the
//  cut: the end of the previous piece, the silence, the start of the next.
//
//  That is why pressing the button does not play from the start of the
//  track but from a little before it.
//

import AVFoundation
import Foundation

@MainActor
@Observable
final class SplitPreview {

    /// How long the preview is in total. Adjustable, because seven seconds
    /// were too short to really judge a transition.
    var length: Double = 14 {
        didSet { UserDefaults.standard.set(length, forKey: "split.previewLength") }
    }

    /// A third of it lies **before** the boundary. One wants to hear the
    /// previous piece fade out, but above all how cleanly the new one starts.
    static let leadShare: Double = 1.0 / 3.0

    var lead: Double { length * Self.leadShare }
    var tail: Double { length - lead }

    init() {
        let stored = UserDefaults.standard.double(forKey: "split.previewLength")
        if stored >= 6, stored <= 60 { length = stored }
    }

    /// Which row is currently playing — the UI turns that into the stop
    /// button.
    private(set) var playingID: UUID?

    /// Where the playhead currently is, in absolute seconds. `nil` means
    /// nothing is playing.
    ///
    /// For display only — the position set on the scrub bar stays untouched.
    /// So the bar moves along while listening, and a second press on play
    /// hears **the same** spot again instead of marching on from wherever it
    /// happened to stop.
    private(set) var position: Double?

    private var player: AVPlayer?
    private var observer: Any?
    private var ticker: Any?

    /// Some files cannot be played even though ffmpeg reads them. That is
    /// checked at runtime, not guessed from the extension — a list of
    /// extensions would be both less accurate and unverified.
    private(set) var unplayableReason: String?

    /// Plays **from** a position, without lead-in.
    ///
    /// For the scrub bar: whoever dragged it to the end of a track wants to
    /// listen from there — and **past the end**, otherwise there is no way to
    /// judge whether the boundary sits right. So only the file length limits
    /// playback, not the end of the track.
    func playFrom(id: UUID, url: URL, position: Double, fileDuration: Double) {
        playRaw(id: id, url: url, from: max(0, position), fileDuration: fileDuration)
    }

    private func playRaw(id: UUID, url: URL, from: Double, fileDuration: Double) {
        stop()

        let until = min(fileDuration, from + length)
        guard until > from else { return }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playingID = id
        position = from

        // Ten times a second is enough for a bar that does not stutter, and it
        // costs nothing.
        ticker = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.playingID == id else { return }
                self.position = CMTimeGetSeconds(time)
            }
        }

        // Stop by ourselves, or the whole file would keep playing.
        let end = CMTime(seconds: until, preferredTimescale: 600)
        observer = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: end)], queue: .main
        ) { [weak self] in
            self?.stop()
        }

        player.seek(to: CMTime(seconds: from, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished, self?.playingID == id else { return }
            player.play()
        }
    }

    func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        if let ticker { player?.removeTimeObserver(ticker) }
        observer = nil
        ticker = nil
        player?.pause()
        player = nil
        playingID = nil
        position = nil
    }

    /// Checks when a file is loaded whether it can be previewed at all.
    func check(_ url: URL) async {
        unplayableReason = nil
        let asset = AVURLAsset(url: url)
        do {
            // `isPlayable` throws for some containers instead of cleanly returning
            // `false` — hence the full `do`/`catch` rather than `try?`.
            guard try await asset.load(.isPlayable) else {
                unplayableReason = String(localized: "This file cannot be previewed — splitting still works.")
                return
            }
        } catch {
            unplayableReason = String(localized: "This file cannot be previewed — splitting still works.")
        }
    }
}

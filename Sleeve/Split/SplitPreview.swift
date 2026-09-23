//
//  SplitPreview.swift
//  Sleeve
//
//  Kurz in eine Trackgrenze hineinhören (Spec §7.8).
//
//  **Kein Audioplayer.** Kein Scrubbing, keine Lautstärke, keine Wiedergabe-
//  liste. Die einzige Frage, die sich beim Aufteilen stellt, ist „sitzt diese
//  Grenze richtig", und die beantwortet man, indem man ein paar Sekunden
//  **über** den Schnitt hinweg hört: das Ende des vorigen Stücks, die Stille,
//  den Anfang des nächsten.
//
//  Deshalb spielt ein Druck auf den Knopf nicht ab Trackbeginn, sondern ein
//  Stück davor.
//

import AVFoundation
import Foundation

@MainActor
@Observable
final class SplitPreview {

    /// Wie lang die Hörprobe insgesamt ist. Einstellbar, weil sieben
    /// Sekunden zu knapp waren, um einen Übergang wirklich zu beurteilen.
    var length: Double = 14 {
        didSet { UserDefaults.standard.set(length, forKey: "split.previewLength") }
    }

    /// Ein Drittel davon liegt **vor** der Grenze. Man will den Ausklang des
    /// vorigen Stücks hören, aber vor allem, wie sauber das neue anfängt.
    static let leadShare: Double = 1.0 / 3.0

    var lead: Double { length * Self.leadShare }
    var tail: Double { length - lead }

    init() {
        let stored = UserDefaults.standard.double(forKey: "split.previewLength")
        if stored >= 6, stored <= 60 { length = stored }
    }

    /// Welche Zeile gerade klingt — die Oberfläche macht daraus den
    /// Stop-Knopf.
    private(set) var playingID: UUID?

    /// Wo der Abspielkopf gerade steht, absolut in Sekunden. `nil` heißt: es
    /// läuft nichts.
    ///
    /// Nur zur Anzeige — die gesetzte Position der Laufleiste bleibt davon
    /// unberührt. So wandert der Balken beim Hören mit, und ein zweiter Druck
    /// auf Abspielen hört wieder **dieselbe** Stelle statt dort
    /// weiterzumarschieren, wo es zufällig aufgehört hat.
    private(set) var position: Double?

    private var player: AVPlayer?
    private var observer: Any?
    private var ticker: Any?

    /// Manche Dateien lassen sich nicht abspielen, obwohl ffmpeg sie liest.
    /// Das wird zur Laufzeit geprüft, nicht an der Endung geraten — eine
    /// Endungsliste wäre sowohl ungenauer als auch ungeprüft.
    private(set) var unplayableReason: String?

    /// Hört **ab** einer Stelle, ohne Vorlauf.
    ///
    /// Für die Laufleiste: wer ans Trackende geschoben hat, will von dort
    /// hören — und zwar **über das Ende hinaus**, sonst lässt sich gar nicht
    /// beurteilen, ob die Grenze richtig sitzt. Deshalb begrenzt nur die
    /// Dateilänge, nicht das Trackende.
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

        // Zehnmal je Sekunde reicht für einen Balken, der nicht ruckelt, und
        // belastet nichts.
        ticker = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.playingID == id else { return }
                self.position = CMTimeGetSeconds(time)
            }
        }

        // Selbst anhalten, sonst liefe die ganze Datei weiter.
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

    /// Prüft beim Laden einer Datei, ob sich überhaupt hineinhören lässt.
    func check(_ url: URL) async {
        unplayableReason = nil
        let asset = AVURLAsset(url: url)
        do {
            // `isPlayable` wirft bei manchen Behältern, statt sauber `false`
            // zurückzugeben — deshalb der volle `do`/`catch` statt `try?`.
            guard try await asset.load(.isPlayable) else {
                unplayableReason = String(localized: "This file cannot be previewed — splitting still works.")
                return
            }
        } catch {
            unplayableReason = String(localized: "This file cannot be previewed — splitting still works.")
        }
    }
}

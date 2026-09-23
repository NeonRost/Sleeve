//
//  WaveformView.swift
//  Sleeve
//
//  Hüllkurve mit Trackgrenzen, Marke und Abspielkopf (Spec §7.7).
//
//  Dieselbe Ansicht dient als Übersicht über die ganze Datei und als Lupe auf
//  eine einzelne Grenze — nur das gezeigte Zeitfenster unterscheidet sich.
//
//  Drei Ebenen übereinander, damit das Teure nicht ständig neu entsteht:
//  Tönung der Tracks (billig), die Hüllkurve selbst (teuer, nur bei neuer
//  Datei, neuem Ausschnitt oder neuer Größe) und Marke samt Abspielkopf
//  (billig, zehnmal je Sekunde). Ohne diese Trennung liefe bei jedem Schritt
//  des Abspielkopfs die ganze Hüllkurve neu durch — bei 45 Minuten eine
//  Viertelmillion Werte.
//

import SwiftUI

struct WaveformView: View {
    let waveform: WaveformSampler.Waveform
    /// Welcher Zeitausschnitt zu sehen ist, absolut in Sekunden.
    let window: ClosedRange<Double>
    let tracks: [SplitTrack]
    let selectedID: UUID?
    let mark: Double
    let playhead: Double?
    /// Welche Grenze des gewählten Tracks sich hier ziehen lässt — in der
    /// Übersicht keine, in den Lupen je eine.
    var draggableEdge: Edge? = nil
    var onClick: (Double) -> Void = { _ in }
    var onDragEdge: (Double) -> Void = { _ in }

    enum Edge { case start, end }

    /// Ob gerade eine Grenze gezogen wird statt die Marke gesetzt. Beim ersten
    /// Kontakt entschieden, danach bleibt es dabei — sonst spränge die Geste
    /// um, sobald der Finger die Linie verlässt.
    @State private var draggingEdge: Bool?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack {
                ShadingLayer(window: window, tracks: tracks, selectedID: selectedID)
                EnvelopeLayer(waveform: waveform, window: window).equatable()
                MarkerLayer(window: window, tracks: tracks, selectedID: selectedID,
                            mark: mark, playhead: playhead, draggableEdge: draggableEdge)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let seconds = time(atX: value.location.x, width: width)
                        if draggingEdge == nil {
                            draggingEdge = isNearEdge(x: value.startLocation.x, width: width)
                        }
                        if draggingEdge == true { onDragEdge(seconds) } else { onClick(seconds) }
                    }
                    .onEnded { _ in draggingEdge = nil }
            )
            .onContinuousHover { phase in
                // Der Zeiger zeigt, dass sich die Linie ziehen lässt.
                if case let .active(point) = phase, isNearEdge(x: point.x, width: width) {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(max(Double(x / width), 0), 1)
        return window.lowerBound + fraction * (window.upperBound - window.lowerBound)
    }

    private func isNearEdge(x: CGFloat, width: CGFloat) -> Bool {
        guard let draggableEdge,
              let track = tracks.first(where: { $0.id == selectedID }) else { return false }
        let seconds = draggableEdge == .start ? track.range.start : track.range.end
        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return false }
        let edgeX = CGFloat((seconds - window.lowerBound) / span) * width
        return abs(edgeX - x) <= 10
    }
}

// MARK: - Ebenen

private func xPosition(_ seconds: Double, in window: ClosedRange<Double>, width: CGFloat) -> CGFloat {
    let span = window.upperBound - window.lowerBound
    guard span > 0 else { return 0 }
    return CGFloat((seconds - window.lowerBound) / span) * width
}

/// Tracks abwechselnd getönt, der gewählte hervorgehoben. Was zu keinem Track
/// gehört — die Stille dazwischen —, bleibt dunkel: das landet in keiner Datei.
private struct ShadingLayer: View {
    let window: ClosedRange<Double>
    let tracks: [SplitTrack]
    let selectedID: UUID?

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(.black.opacity(0.22)))
            for (index, track) in tracks.enumerated() {
                let from = xPosition(track.range.start, in: window, width: size.width)
                let to = xPosition(track.range.end, in: window, width: size.width)
                guard to > 0, from < size.width else { continue }
                let rect = CGRect(x: from, y: 0, width: max(1, to - from), height: size.height)
                let tint: Color = track.id == selectedID
                    ? .accentColor.opacity(0.28)
                    : .primary.opacity(index.isMultiple(of: 2) ? 0.07 : 0.035)
                context.fill(Path(rect), with: .color(tint))
            }
        }
    }
}

/// Die Hüllkurve: ein senkrechter Strich je Bildpunkt, um die Mitte. Hängt nur
/// an Datei und Ausschnitt — deshalb `Equatable`, damit SwiftUI sie beim
/// Mitlaufen des Abspielkopfs in Ruhe lässt.
private struct EnvelopeLayer: View, @preconcurrency Equatable {
    let waveform: WaveformSampler.Waveform
    let window: ClosedRange<Double>

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.waveform.id == rhs.waveform.id && lhs.window == rhs.window
    }

    var body: some View {
        Canvas { context, size in
            let columns = max(1, Int(size.width))
            let envelope = waveform.envelope(from: window.lowerBound, to: window.upperBound,
                                             columns: columns)
            let middle = size.height / 2
            var path = Path()
            for (column, value) in envelope.enumerated() {
                let half = max(CGFloat(value) * middle * 0.92, 0.5)
                let x = CGFloat(column) + 0.5
                path.move(to: CGPoint(x: x, y: middle - half))
                path.addLine(to: CGPoint(x: x, y: middle + half))
            }
            context.stroke(path, with: .color(.primary.opacity(0.6)), lineWidth: 1)
        }
    }
}

/// Grenzen, Marke und Abspielkopf.
private struct MarkerLayer: View {
    let window: ClosedRange<Double>
    let tracks: [SplitTrack]
    let selectedID: UUID?
    let mark: Double
    let playhead: Double?
    let draggableEdge: WaveformView.Edge?

    var body: some View {
        Canvas { context, size in
            func line(at seconds: Double, color: Color, width: CGFloat, dash: [CGFloat] = []) {
                let x = xPosition(seconds, in: window, width: size.width)
                guard x >= -2, x <= size.width + 2 else { return }
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: width, dash: dash))
            }

            for track in tracks where track.id != selectedID {
                line(at: track.range.start, color: .accentColor.opacity(0.55), width: 1)
                line(at: track.range.end, color: .accentColor.opacity(0.55), width: 1)
            }
            if let selected = tracks.first(where: { $0.id == selectedID }) {
                line(at: selected.range.start, color: .green, width: 2)
                line(at: selected.range.end, color: .orange, width: 2)

                // Ein Griff oben an der Linie, die sich hier ziehen lässt.
                if let draggableEdge {
                    let seconds = draggableEdge == .start ? selected.range.start : selected.range.end
                    let x = xPosition(seconds, in: window, width: size.width)
                    var grip = Path()
                    grip.move(to: CGPoint(x: x - 6, y: 0))
                    grip.addLine(to: CGPoint(x: x + 6, y: 0))
                    grip.addLine(to: CGPoint(x: x, y: 9))
                    grip.closeSubpath()
                    context.fill(grip, with: .color(draggableEdge == .start ? .green : .orange))
                }
            }

            line(at: mark, color: .primary.opacity(0.8), width: 1, dash: [3, 3])
            if let playhead { line(at: playhead, color: .red, width: 1.5) }
        }
        .allowsHitTesting(false)
    }
}

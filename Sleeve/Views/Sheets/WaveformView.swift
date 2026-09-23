//
//  WaveformView.swift
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
//  Envelope with track boundaries, mark and playhead (spec §7.7).
//
//  The same view serves as the overview of the whole file and as the
//  magnifier on a single boundary — only the time window shown differs.
//
//  Three layers on top of each other, so that the expensive part is not
//  rebuilt all the time: the track shading (cheap), the envelope itself
//  (expensive, only for a new file, a new window or a new size) and mark
//  plus playhead (cheap, ten times a second). Without this separation every
//  step of the playhead would run through the whole envelope again — a
//  quarter of a million values for 45 minutes.
//

import SwiftUI

struct WaveformView: View {
    let waveform: WaveformSampler.Waveform
    /// Which time window is visible, in absolute seconds.
    let window: ClosedRange<Double>
    let tracks: [SplitTrack]
    let selectedID: UUID?
    let mark: Double
    let playhead: Double?
    /// Which boundary of the selected track can be dragged here — none in
    /// the overview, one in each magnifier.
    var draggableEdge: Edge? = nil
    var onClick: (Double) -> Void = { _ in }
    var onDragEdge: (Double) -> Void = { _ in }

    enum Edge { case start, end }

    /// Whether a boundary is being dragged instead of the mark being set.
    /// Decided on first contact and kept after that — otherwise the gesture
    /// would switch as soon as the finger leaves the line.
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
                // The pointer shows that the line can be dragged.
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

// MARK: - Layers

private func xPosition(_ seconds: Double, in window: ClosedRange<Double>, width: CGFloat) -> CGFloat {
    let span = window.upperBound - window.lowerBound
    guard span > 0 else { return 0 }
    return CGFloat((seconds - window.lowerBound) / span) * width
}

/// Tracks shaded alternately, the selected one highlighted. Whatever belongs
/// to no track — the silence in between — stays dark: it ends up in no
/// file.
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

/// The envelope: one vertical stroke per pixel, around the middle. Depends
/// only on file and window — hence `Equatable`, so that SwiftUI leaves it
/// alone while the playhead moves.
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

/// Boundaries, mark and playhead.
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

                // A handle at the top of the line that can be dragged here.
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

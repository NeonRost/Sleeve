//
//  FlowLayout.swift
//  Sleeve
//
//  Legt Elemente nebeneinander und bricht um, wenn die Zeile voll ist.
//
//  `HStack` kann das nicht: er quetscht stattdessen, bis die Beschriftungen
//  mitten im Wort umbrechen. Ein `LazyVGrid` wäre die naheliegende Alternative,
//  vergibt aber gleich breite Spalten — bei Platzhaltern von „%year%" bis
//  „%albumartist%" verschenkt das die halbe Breite.
//

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout Void) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = arrange(subviews: subviews, in: width)
        guard let last = rows.last else { return .zero }
        return CGSize(width: width, height: last.y + last.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        for row in arrange(subviews: subviews, in: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size))
            }
        }
    }

    // MARK: - Umbruch

    private struct Row {
        var y: CGFloat
        var height: CGFloat
        var items: [(index: Int, x: CGFloat, size: CGSize)]
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, items: [])
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            // Passt es nicht mehr, neue Zeile — aber nie eine leere Zeile
            // erzwingen, sonst hängt ein zu breites Element in der Luft.
            if x + size.width > width, !current.items.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + lineSpacing,
                              height: 0, items: [])
                x = 0
            }
            current.items.append((index, x, size))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

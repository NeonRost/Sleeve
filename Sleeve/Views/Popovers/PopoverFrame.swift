//
//  PopoverFrame.swift
//  Sleeve
//
//  Gemeinsamer Rahmen für die Toolbar-Popover — Titel oben, Inhalt, rechts
//  unten die Aktion. Tagr macht das genauso.
//

import SwiftUI

struct PopoverFrame<Content: View, Actions: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            content

            HStack {
                Spacer()
                actions
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(minWidth: 260)
    }
}

/// Menü, das die Platzhalter in ein Pattern-Feld einsetzt — man muss sich die
/// Token nicht merken.
struct TokenMenu: View {
    @Binding var pattern: String

    var body: some View {
        Menu {
            ForEach(PatternToken.allCases) { token in
                Button(token.placeholder) { pattern += token.placeholder }
            }
        } label: {
            Image(systemName: "curlybraces")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Insert a placeholder")
    }
}

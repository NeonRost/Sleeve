//
//  PopoverFrame.swift
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
//  Shared frame for the toolbar popovers — title at the top, content, the
//  action at the bottom right. Tagr does it the same way.
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

/// Menu that inserts the placeholders into a pattern field — nobody has to
/// remember the tokens.
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

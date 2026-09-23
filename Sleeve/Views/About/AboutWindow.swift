//
//  AboutWindow.swift
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
//  "About Sleeve" and the licenses. A window of its own instead of the
//  standard panel: that one shows the build number in parentheses after the
//  version ("1.0 (1)") and has no room for the license text the GPL requires
//  to be supplied.
//

import AppKit
import SwiftUI

/// The licenses of what is inside the program: its own and those of the
/// libraries compiled into it. ffmpeg is not among them — Sleeve does not
/// ship it, the user installs it.
enum BundledLicense: String, CaseIterable, Identifiable {
    case sleeve, taglib, utfcpp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sleeve: "Sleeve (GPL v3)"
        // TagLib can be used under LGPL 2.1 or MPL 1.1. Only the LGPL is
        // compatible with the GPL — so that one applies.
        case .taglib: "TagLib (LGPL 2.1)"
        // Part of TagLib (UTF-8 ↔ UTF-16 conversion).
        case .utfcpp: "utfcpp (Boost 1.0)"
        }
    }

    private var resource: String {
        switch self {
        case .sleeve: "Sleeve-GPL-3.0"
        case .taglib: "TagLib-LGPL-2.1"
        case .utfcpp: "utfcpp-BSL-1.0"
        }
    }

    var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}

struct AboutView: View {
    @Environment(\.openWindow) private var openWindow

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(verbatim: "Sleeve")
                .font(.title2.bold())
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Sleeve comes with absolutely no warranty. You may redistribute and modify it under the terms of the GNU GPL v3 or later.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Button("Show License") { openWindow(id: SleeveApp.licensesWindowID) }
                .buttonStyle(.link)
            Text(verbatim: copyright)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 400)
    }
}

struct LicensesView: View {
    @State private var selection: BundledLicense = .sleeve

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(BundledLicense.allCases) { license in
                    Text(verbatim: license.label).tag(license)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(12)
            Divider()
            ScrollView {
                Text(verbatim: selection.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            // Start at the top when switching, not in the middle of the previous text.
            .id(selection)
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

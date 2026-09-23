//
//  AboutWindow.swift
//  Sleeve
//
//  „Über Sleeve" und die Lizenzen. Eigenes Fenster statt des Standardfelds:
//  das zeigt die Build-Nummer in Klammern hinter der Version („1.0 (1)") und
//  hat keinen Platz für den Lizenztext, den die GPL mitzuliefern verlangt.
//

import AppKit
import SwiftUI

/// Die Lizenzen, die im Programm stecken: die eigene und die der Bibliotheken,
/// die hineinkompiliert sind. ffmpeg gehört nicht dazu — Sleeve liefert es
/// nicht mit, der Nutzer installiert es selbst.
enum BundledLicense: String, CaseIterable, Identifiable {
    case sleeve, taglib, utfcpp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sleeve: "Sleeve (GPL v3)"
        // TagLib steht unter LGPL 2.1 oder MPL 1.1 zur Wahl. Mit der GPL
        // verträglich ist nur die LGPL — also gilt die.
        case .taglib: "TagLib (LGPL 2.1)"
        // Steckt in TagLib (Umwandlung UTF-8 ↔ UTF-16).
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
            // Beim Wechsel oben anfangen, nicht mitten im vorigen Text.
            .id(selection)
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

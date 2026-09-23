//
//  MusicApp.swift
//  Sleeve
//
//  Music.app-Anbindung (Spec §4.7). Bewusst klein — reines Convenience.
//

import Foundation

enum MusicApp {

    enum MusicError: Error, LocalizedError {
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message):
                String(localized: "Music could not add the files: \(message)")
            }
        }
    }

    /// Fügt die Dateien der Music-Mediathek hinzu.
    ///
    /// Braucht `NSAppleEventsUsageDescription` in der Info.plist und
    /// `com.apple.security.automation.apple-events` in den Entitlements —
    /// ohne beides scheitert das im Sandbox stumm.
    @MainActor
    static func add(_ urls: [URL]) throws {
        guard !urls.isEmpty else { return }

        let fileList = urls
            .map { "POSIX file \"\(escape($0.path(percentEncoded: false)))\"" }
            .joined(separator: ", ")

        let source = """
        tell application "Music"
            add {\(fileList)}
        end tell
        """

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw MusicError.scriptFailed("script could not be compiled")
        }
        script.executeAndReturnError(&errorInfo)

        if let errorInfo,
           let message = errorInfo[NSAppleScript.errorMessage] as? String {
            throw MusicError.scriptFailed(message)
        }
    }

    /// Anführungszeichen und Backslashes im Pfad maskieren, sonst bricht das
    /// AppleScript bei einem Album wie `Best Of "Live"` auseinander.
    private static func escape(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

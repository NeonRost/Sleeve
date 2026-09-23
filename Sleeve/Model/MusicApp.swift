//
//  MusicApp.swift
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
//  Music app integration (spec §4.7). Deliberately small — pure convenience.
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

    /// Adds the files to the Music library.
    ///
    /// Needs `NSAppleEventsUsageDescription` in Info.plist and
    /// `com.apple.security.automation.apple-events` in the entitlements —
    /// without both, this fails silently in the sandbox.
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

    /// Escape quotes and backslashes in the path, or the AppleScript falls apart
    /// on an album like `Best Of "Live"`.
    private static func escape(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

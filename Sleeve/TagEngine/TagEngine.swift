//
//  TagEngine.swift
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
//  Facade in front of `TagLibBridge`. An `actor`, so that no TagLib call
//  ever lands on the main thread (spec §4.1).
//

import Foundation

actor TagEngine {

    /// What Sleeve handles in tag mode. AIFF is included because macOS
    /// mounts audio CD tracks that way (spec §6.1).
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "flac", "ogg", "oga", "opus",
        "aiff", "aif", "aifc", "wav", "wv", "ape", "mpc", "wma", "dsf", "dff",
    ]

    struct WriteRequest: Sendable {
        let url: URL
        let tags: AudioTags
        let fields: Set<TagField>
    }

    // MARK: - Reading

    func read(_ url: URL) throws -> AudioFileInfo {
        try TagLibBridge.read(from: url)
    }

    // MARK: - Writing

    /// Writes one file. Throws `TagError` — the caller collects the errors and
    /// carries on, so that one broken file does not abort the batch.
    func write(_ request: WriteRequest) throws {
        try TagLibBridge.write(request.tags, fields: request.fields, to: request.url)
    }

    // MARK: - Renaming

    /// Renames and avoids collisions with `" (2)"`. Returns the new path so
    /// that `TrackFile.url` can be updated.
    func rename(_ url: URL, to newName: String) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let ext = (newName as NSString).pathExtension
        let base = (newName as NSString).deletingPathExtension
        guard !base.isEmpty else { throw TagError.renameFailed(url) }

        var target = folder.appendingPathComponent(newName)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            // The same path is no collision — then there is nothing to do.
            if target.standardizedFileURL == url.standardizedFileURL { return url }
            let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            target = folder.appendingPathComponent(candidate)
            counter += 1
        }

        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            throw TagError.renameFailed(url)
        }
        return target
    }

    // MARK: - Collecting files

    /// Resolves folders recursively and filters for supported extensions.
    /// Runs here on purpose and not on the main thread — a music folder
    /// dragged in can have tens of thousands of entries.
    func collectAudioFiles(from urls: [URL]) -> [URL] {
        var result: [URL] = []
        var seen: Set<URL> = []

        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard Self.supportedExtensions.contains(standardized.pathExtension.lowercased()),
                  seen.insert(standardized).inserted
            else { return }
            result.append(standardized)
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false),
                                                 isDirectory: &isDirectory)
            else { continue }

            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let child = enumerator?.nextObject() as? URL {
                    add(child)
                }
            } else {
                add(url)
            }
        }

        // Natural sort order, so that "Track 2" comes before "Track 10".
        return result.sorted {
            $0.path(percentEncoded: false).localizedStandardCompare(
                $1.path(percentEncoded: false)
            ) == .orderedAscending
        }
    }
}

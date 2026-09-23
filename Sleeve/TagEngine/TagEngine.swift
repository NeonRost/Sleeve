//
//  TagEngine.swift
//  Sleeve
//
//  Fassade vor `TagLibBridge`. Als `actor`, damit kein TagLib-Aufruf je auf
//  dem Main-Thread landet (Spec §4.1).
//

import Foundation

actor TagEngine {

    /// Was Sleeve im Tag-Modus anfasst. AIFF ist dabei, weil macOS
    /// Audio-CD-Tracks so einhängt (Spec §6.1).
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "flac", "ogg", "oga", "opus",
        "aiff", "aif", "aifc", "wav", "wv", "ape", "mpc", "wma", "dsf", "dff",
    ]

    struct WriteRequest: Sendable {
        let url: URL
        let tags: AudioTags
        let fields: Set<TagField>
    }

    // MARK: - Lesen

    func read(_ url: URL) throws -> AudioFileInfo {
        try TagLibBridge.read(from: url)
    }

    // MARK: - Schreiben

    /// Schreibt eine Datei. Wirft `TagError` — der Aufrufer sammelt die Fehler
    /// ein und macht weiter, damit eine kaputte Datei den Batch nicht abbricht.
    func write(_ request: WriteRequest) throws {
        try TagLibBridge.write(request.tags, fields: request.fields, to: request.url)
    }

    // MARK: - Umbenennen

    /// Benennt um und weicht Kollisionen mit `" (2)"` aus. Gibt den neuen
    /// Pfad zurück, damit `TrackFile.url` nachgezogen werden kann.
    func rename(_ url: URL, to newName: String) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let ext = (newName as NSString).pathExtension
        let base = (newName as NSString).deletingPathExtension
        guard !base.isEmpty else { throw TagError.renameFailed(url) }

        var target = folder.appendingPathComponent(newName)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            // Derselbe Pfad ist keine Kollision — dann ist nichts zu tun.
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

    // MARK: - Dateien einsammeln

    /// Löst Ordner rekursiv auf und filtert auf unterstützte Endungen.
    /// Läuft bewusst hier und nicht auf dem Main-Thread — ein
    /// hineingezogener Musikordner kann zehntausende Einträge haben.
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

        // Natürliche Sortierung, damit „Track 2" vor „Track 10" steht.
        return result.sorted {
            $0.path(percentEncoded: false).localizedStandardCompare(
                $1.path(percentEncoded: false)
            ) == .orderedAscending
        }
    }
}

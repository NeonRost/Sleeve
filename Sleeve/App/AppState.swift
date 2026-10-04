//
//  AppState.swift
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

import Foundation
import SwiftUI

/// The UI language is English (base); German and Spanish come from the
/// string catalog. Everything in the repository — code, comments, docs —
/// is English.
enum AppMode: String, CaseIterable, Identifiable {
    case tag, convert, rip

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .tag:     "Tag"
        case .convert: "Convert"
        case .rip:     "Rip"
        }
    }

    var symbol: String {
        switch self {
        case .tag:     "tag"
        case .convert: "arrow.triangle.2.circlepath"
        case .rip:     "opticaldisc"
        }
    }
}

/// Why a mode is unavailable. Modes are **not hidden** but disabled and
/// explained — hidden features look like bugs (spec §1.1).
enum ModeAvailability: Equatable {
    case available
    case unavailable(reason: LocalizedStringKey)

    var isAvailable: Bool { self == .available }
}

@Observable
@MainActor
final class AppState {

    var activeMode: AppMode = .tag

    /// Shared by all modes — survives every mode switch.
    let trackList = TrackListModel()

    let engine = TagEngine()
    let ffmpegLocator = FFmpegLocator()

    // MARK: - Discogs (§4.6)

    /// Lives in the keychain, not in the preferences.
    var discogsToken: String?
    let discogs: DiscogsClient
    let lookup: LookupService
    var genreSource: GenreSource {
        didSet { defaults.set(genreSource.rawValue, forKey: Keys.genreSource) }
    }
    var isShowingLookup = false
    #if DEBUG
    /// Which result in "Look Up Album" gets picked right away.
    var lookupDebugPick: Int?
    #endif

    // MARK: - Convert (§5)

    /// `nil` means: not found. The mode is then locked and the inspector
    /// explains what to do.
    var ffmpeg: FFmpegTool?
    var isLocatingFFmpeg = false
    /// `nil` means: Homebrew is missing too — then the explanation card needs
    /// one more step.
    var homebrew: URL?
    var conversionTask: Task<Void, Never>?

    var customFFmpegPath: String? {
        didSet { defaults.set(customFFmpegPath, forKey: Keys.ffmpegPath) }
    }

    var conversionSettings = ConversionSettings() {
        didSet { persistConversionSettings() }
    }

    // MARK: - Rip (§6)

    let ripEngine = RipEngine()
    let discWatcher = DiscWatcher()

    /// The drives with an audio CD, and which one the Rip section, the
    /// image and the copy read from. `nil` takes the first.
    var sourceDrives: [CDDriveInfo] = []
    var sourceDriveName: String?

    /// What is known about the inserted disc. `nil` means: none inserted.
    var disc: DiscSnapshot?
    var discError: String?
    var isInspectingDisc = false

    /// The metadata to rip with — from CD-TEXT, from MusicBrainz or edited
    /// by hand.
    var discAlbum = ""
    var discArtist = ""
    var discYear = ""
    var discGenre = ""
    var discComposer = ""
    var discNumber = 1
    var discTotal = 1
    /// Empty means: put it together from artist and album. Cleared when the
    /// disc changes — it belongs to this CD, not to the settings.
    var ripFolderName = ""
    var discTitles: [Int: String] = [:]
    /// A different artist per track. Classical music and compilations have
    /// that, and CD-TEXT delivers it — throwing it away would be a pity.
    var discTrackArtists: [Int: String] = [:]
    var discMetadataSource: DiscMetadataSource?
    var isShowingDiscLookup = false

    var selectedRipTracks: Set<Int> = []
    var ripSettings = RipSettings.load() {
        didSet { ripSettings.save() }
    }
    var ripDestination: URL? {
        didSet { defaults.set(ripDestination?.path, forKey: Keys.ripDestination) }
    }
    var isRipping = false
    var ripStage: RipStage = .idle
    var ripConversionProgress: Double = 0
    var ripCurrentTrack: Int?
    var ripProgress: [Int: Double] = [:]
    var ripReport: RipReport?
    var ripFailures: [SaveFailure] = []
    var ripTask: Task<Void, Never>?

    // MARK: - Disc image (§6.9)

    var isShowingImageSheet = false
    var imageFormat: DiscImageFormat = .flac {
        didSet { defaults.set(imageFormat.rawValue, forKey: Keys.imageFormat) }
    }
    /// Empty means: the same suggestion as for the album folder.
    var imageBaseName = ""
    var imageStage: DiscImageStage = .idle
    var imageProgress: Double = 0
    var imageResult: RipEngine.ImageResult?
    var imageError: String?
    var imageTask: Task<Void, Never>?

    // MARK: - Burning back (§6.10)

    var isShowingBurnSheet = false
    var burnCueURL: URL?
    var burnCue: CueSheet?
    var burnLayout: CDBurner.Layout?
    var burnNeedsDecoding = false
    var burnDevices: [BurnDeviceInfo] = []
    /// The picked burner; `nil` takes the first.
    var burnDeviceID: String?
    var burnDevice: BurnDeviceInfo?
    var burnMedia: BurnMediaState = .noDrive
    var burnStage: BurnStage = .idle
    var burnProgress: Double = 0
    var burnError: String?
    var burnTask: Task<Void, Never>?
    var isConfirmingBurn = false

    // MARK: - Copying a disc (§6.11)

    var isShowingCopySheet = false
    var copyStage: CopyStage = .idle
    var copyProgress: Double = 0
    var copyError: String?
    var copyImage: CopyImage?
    var copyTask: Task<Void, Never>?

    // MARK: - Track Splitter (§7)

    var splitSource: URL?
    var splitDestination: URL?
    var splitAnalysis: SilenceAnalysis?
    var splitSourceInfo: AudioSplitter.SourceInfo?
    var splitTracks: [SplitTrack] = []
    var splitThresholdDB: Double = -30
    var splitMinimumSilence: Double = 0.5
    var splitMinimumTrackLength = AudioSplitter.defaultMinimumTrackLength
    var splitOutput: SplitOutput = .keepSource
    var splitBitrate = 256
    var splitCompressionLevel = 5
    var splitPattern = "%track% - %title%"
    var splitStage: SplitStage = .idle
    var splitError: String?
    var splitFailures: [SaveFailure] = []
    var splitTask: Task<Void, Never>?
    let splitPreview = SplitPreview()
    var splitWaveform: WaveformSampler.Waveform?
    var splitSelectionID: UUID?
    var splitMark: Double?
    var splitCompleted: SplitResult?
    /// Album, artist, year and genre from an applied track list — end up in
    /// the tags when cutting.
    var splitMetadata: TrackListing?
    var isShowingSplitLookup = false
    var splitLookupMode: SplitLookupMode = .musicBrainz
    var splitPasteText = ""
    /// The search from "Look Up Titles" — stays with its results until
    /// another file comes.
    var splitSearch: ReleaseSearch?
    #if DEBUG
    var splitDebugPick: Int?
    #endif
    var isLoadingWaveform = false

    // MARK: - Preferences

    /// Keys in `UserDefaults`. The Discogs token is deliberately **not**
    /// here but in the keychain.
    private enum Keys {
        static let ffmpegPath = "ffmpeg.path"
        static let convertFormat = "convert.format"
        static let convertBitrate = "convert.bitrate"
        static let convertCompression = "convert.compressionLevel"
        static let convertKeepsOriginals = "convert.keepsOriginals"
        static let convertPattern = "convert.filenamePattern"
        static let convertDestination = "convert.destinationFolder"
        static let genreSource = "discogs.genreSource"
        static let ripDestination = "rip.destination"
        static let imageFormat = "image.format"
    }

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            Keys.convertBitrate: 256,
            Keys.convertCompression: 5,
            Keys.convertKeepsOriginals: true,
        ])
        customFFmpegPath = defaults.string(forKey: Keys.ffmpegPath)
        ripDestination = defaults.string(forKey: Keys.ripDestination).map {
            URL(fileURLWithPath: $0)
        }
        imageFormat = DiscImageFormat(rawValue: defaults.string(forKey: Keys.imageFormat) ?? "")
            ?? .flac
        genreSource = GenreSource(rawValue: defaults.string(forKey: Keys.genreSource) ?? "")
            ?? .style

        let token = KeychainStore.get(KeychainStore.discogsToken)
        discogsToken = token
        let client = DiscogsClient(token: token)
        discogs = client
        lookup = LookupService(discogs: client)

        var settings = ConversionSettings()
        settings.format = AudioFormat(rawValue: defaults.string(forKey: Keys.convertFormat) ?? "")
            ?? .mp3
        settings.bitrate = defaults.integer(forKey: Keys.convertBitrate)
        settings.compressionLevel = defaults.integer(forKey: Keys.convertCompression)
        settings.keepsOriginals = defaults.bool(forKey: Keys.convertKeepsOriginals)
        settings.filenamePattern = defaults.string(forKey: Keys.convertPattern) ?? ""
        settings.destinationFolder = defaults.string(forKey: Keys.convertDestination)
            .map { URL(fileURLWithPath: $0) }
        conversionSettings = settings
    }

    private func persistConversionSettings() {
        defaults.set(conversionSettings.format.rawValue, forKey: Keys.convertFormat)
        defaults.set(conversionSettings.bitrate, forKey: Keys.convertBitrate)
        defaults.set(conversionSettings.compressionLevel, forKey: Keys.convertCompression)
        defaults.set(conversionSettings.keepsOriginals, forKey: Keys.convertKeepsOriginals)
        defaults.set(conversionSettings.filenamePattern, forKey: Keys.convertPattern)
        defaults.set(conversionSettings.destinationFolder?.path(percentEncoded: false),
                     forKey: Keys.convertDestination)
    }

    // MARK: - Work in progress

    var isBusy = false
    var progress: Double = 0
    var progressLabel: LocalizedStringKey = ""
    /// Progress only from this count on (spec §4.1).
    static let progressThreshold = 20
    var showsProgress = false

    // MARK: - Errors

    struct SaveFailure: Identifiable {
        let id = UUID()
        let filename: String
        let message: String
    }

    var failures: [SaveFailure] = []
    var isShowingFailureSheet = false

    // MARK: - Undo

    private struct UndoEntry {
        let trackID: TrackFile.ID
        let tags: AudioTags
        let fields: Set<TagField>
    }

    private var undoStack: [UndoEntry] = []

    /// One session-wide step is enough (spec §4.1).
    var canUndo: Bool { !undoStack.isEmpty && !isBusy }

    // MARK: - Mode availability

    func availability(of mode: AppMode) -> ModeAvailability {
        switch mode {
        case .tag:
            .available
        case .convert:
            // Always enterable, even without ffmpeg. Locking the mode would be
            // circular: the instructions for installing ffmpeg are in exactly
            // this section. The `conversionBlocker` prevents starting
            // instead.
            .available
        case .rip:
            // As with converting: always enterable. Whether a disc is inserted
            // is something the section says itself — locking would only hide
            // what the matter is.
            .available
        }
    }

    // MARK: - Loading files

    func addFiles(_ urls: [URL]) async {
        guard !isBusy else { return }
        isBusy = true
        progress = 0
        progressLabel = "Reading files…"
        defer { finishWork() }

        let audioFiles = await engine.collectAudioFiles(from: urls)
        let newFiles = audioFiles.filter { !trackList.contains(url: $0) }
        guard !newFiles.isEmpty else { return }

        showsProgress = newFiles.count >= Self.progressThreshold

        var loaded: [TrackFile] = []
        loaded.reserveCapacity(newFiles.count)

        for (index, url) in newFiles.enumerated() {
            if Task.isCancelled { break }
            do {
                let info = try await engine.read(url)
                loaded.append(TrackFile(url: url, info: info))
            } catch {
                // An unreadable file must not abort the import.
                failures.append(SaveFailure(
                    filename: url.lastPathComponent,
                    message: Self.describe(error)
                ))
            }
            progress = Double(index + 1) / Double(newFiles.count)
        }

        trackList.append(contentsOf: loaded)
        if !failures.isEmpty { isShowingFailureSheet = true }
    }

    // MARK: - Saving

    func save() async {
        guard !isBusy else { return }
        let dirty = trackList.dirtyTracks
        guard !dirty.isEmpty else { return }

        isBusy = true
        progress = 0
        progressLabel = "Writing tags…"
        showsProgress = dirty.count >= Self.progressThreshold
        failures.removeAll()
        defer { finishWork() }

        var undo: [UndoEntry] = []

        for (index, track) in dirty.enumerated() {
            if Task.isCancelled { break }

            let request = TagEngine.WriteRequest(
                url: track.url,
                tags: track.edited,
                fields: track.touchedFields
            )
            // Back up the state on disk before writing — that is the undo
            // step.
            let snapshot = UndoEntry(
                trackID: track.id,
                tags: track.original,
                fields: track.touchedFields
            )

            do {
                if !track.touchedFields.isEmpty {
                    try await engine.write(request)
                }
                // Rename after writing — if writing fails, the file should
                // remain findable under its old name.
                if let proposed = track.proposedFilename, proposed != track.filename {
                    track.url = try await engine.rename(track.url, to: proposed)
                }
                track.commit()
                undo.append(snapshot)
            } catch {
                track.lastError = error as? TagError
                failures.append(SaveFailure(
                    filename: track.filename,
                    message: Self.describe(error)
                ))
            }
            progress = Double(index + 1) / Double(dirty.count)
        }

        if !undo.isEmpty { undoStack = undo }
        if !failures.isEmpty { isShowingFailureSheet = true }
    }

    /// Undoes the last write by writing the backed-up state to disk again.
    func undoLastSave() async {
        guard canUndo else { return }
        let entries = undoStack
        undoStack.removeAll()

        isBusy = true
        progress = 0
        progressLabel = "Undoing…"
        showsProgress = entries.count >= Self.progressThreshold
        failures.removeAll()
        defer { finishWork() }

        for (index, entry) in entries.enumerated() {
            guard let track = trackList.track(id: entry.trackID) else { continue }
            track.restore(entry.tags, fields: entry.fields)
            do {
                try await engine.write(TagEngine.WriteRequest(
                    url: track.url, tags: entry.tags, fields: entry.fields
                ))
                track.commit()
            } catch {
                track.lastError = error as? TagError
                failures.append(SaveFailure(
                    filename: track.filename,
                    message: Self.describe(error)
                ))
            }
            progress = Double(index + 1) / Double(entries.count)
        }

        if !failures.isEmpty { isShowingFailureSheet = true }
    }

    func revertSelection() {
        let targets = trackList.selection.isEmpty
            ? trackList.dirtyTracks
            : trackList.selectedTracks
        targets.forEach { $0.revert() }
    }

    // MARK: - Internal

    func finishWork() {
        isBusy = false
        showsProgress = false
        progress = 0
        progressLabel = ""
    }

    static func describe(_ error: Error) -> String {
        guard let tagError = error as? TagError else { return error.localizedDescription }
        switch tagError {
        case .cannotOpen:  return String(localized: "File could not be opened.")
        case .invalidFile: return String(localized: "Not a readable audio file.")
        case .saveFailed:  return String(localized: "Writing failed — check file permissions.")
        case .renameFailed: return String(localized: "Renaming failed — check file permissions.")
        }
    }
}

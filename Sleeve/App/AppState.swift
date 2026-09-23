//
//  AppState.swift
//  Sleeve
//

import Foundation
import SwiftUI

/// UI-Sprache ist Englisch (Basis), Deutsch und Spanisch kommen als
/// String-Catalogs dazu. Kommentare bleiben deutsch.
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

/// Warum ein Modus nicht verfügbar ist. Modi werden **nicht ausgeblendet**,
/// sondern deaktiviert und erklärt — ausgeblendete Funktionen wirken wie Bugs
/// (Spec §1.1).
enum ModeAvailability: Equatable {
    case available
    case unavailable(reason: LocalizedStringKey)

    var isAvailable: Bool { self == .available }
}

@Observable
@MainActor
final class AppState {

    var activeMode: AppMode = .tag

    /// Modusübergreifend — überlebt jeden Moduswechsel.
    let trackList = TrackListModel()

    let engine = TagEngine()
    let ffmpegLocator = FFmpegLocator()

    // MARK: - Discogs (§4.6)

    /// Liegt im Schlüsselbund, nicht in den Voreinstellungen.
    var discogsToken: String?
    let discogs: DiscogsClient
    let lookup: LookupService
    var genreSource: GenreSource {
        didSet { defaults.set(genreSource.rawValue, forKey: Keys.genreSource) }
    }
    var isShowingLookup = false
    #if DEBUG
    /// Welcher Treffer in „Album nachschlagen" gleich gewählt wird.
    var lookupDebugPick: Int?
    #endif

    // MARK: - Konvertieren (§5)

    /// `nil` heißt: nicht gefunden. Der Modus ist dann gesperrt und der
    /// Inspector erklärt, was zu tun ist.
    var ffmpeg: FFmpegTool?
    var isLocatingFFmpeg = false
    /// `nil` heißt: auch Homebrew fehlt — dann braucht die Erklärkarte einen
    /// Schritt mehr.
    var homebrew: URL?
    var conversionTask: Task<Void, Never>?

    var customFFmpegPath: String? {
        didSet { defaults.set(customFFmpegPath, forKey: Keys.ffmpegPath) }
    }

    var conversionSettings = ConversionSettings() {
        didSet { persistConversionSettings() }
    }

    // MARK: - Rippen (§6)

    let ripEngine = RipEngine()
    let discWatcher = DiscWatcher()

    /// Was über die eingelegte Scheibe bekannt ist. `nil` heißt: keine drin.
    var disc: DiscSnapshot?
    var discError: String?
    var isInspectingDisc = false

    /// Die Metadaten, die gerippt werden sollen — aus CD-TEXT, aus
    /// MusicBrainz oder von Hand geändert.
    var discAlbum = ""
    var discArtist = ""
    var discYear = ""
    var discGenre = ""
    var discComposer = ""
    var discNumber = 1
    var discTotal = 1
    /// Leer heißt: aus Interpret und Album zusammensetzen. Wird beim
    /// Scheibenwechsel geleert — er gehört zu dieser CD, nicht zur Einstellung.
    var ripFolderName = ""
    var discTitles: [Int: String] = [:]
    /// Abweichender Interpret je Track. Klassik und Sampler haben das, und
    /// CD-TEXT liefert es — es wegzuwerfen wäre schade.
    var discTrackArtists: [Int: String] = [:]
    var discMetadataSource: DiscMetadataSource?
    var discLookupCandidates: [LookupRelease] = []
    var discLookupMessage: String?
    var isLookingUpDisc = false

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

    // MARK: - Abbild (§9.1)

    var isShowingImageSheet = false
    var imageFormat: DiscImageFormat = .flac {
        didSet { defaults.set(imageFormat.rawValue, forKey: Keys.imageFormat) }
    }
    /// Leer heißt: derselbe Vorschlag wie beim Albumordner.
    var imageBaseName = ""
    var imageStage: DiscImageStage = .idle
    var imageProgress: Double = 0
    var imageResult: RipEngine.ImageResult?
    var imageError: String?
    var imageTask: Task<Void, Never>?

    // MARK: - Zurückbrennen (§6.10)

    var isShowingBurnSheet = false
    var burnCueURL: URL?
    var burnCue: CueSheet?
    var burnLayout: CDBurner.Layout?
    var burnNeedsDecoding = false
    var burnDevice: BurnDeviceInfo?
    var burnMedia: BurnMediaState = .noDrive
    var burnStage: BurnStage = .idle
    var burnProgress: Double = 0
    var burnError: String?
    var burnTask: Task<Void, Never>?
    var isConfirmingBurn = false

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
    /// Album, Interpret, Jahr und Genre aus einer übernommenen Trackliste —
    /// landen beim Schneiden in den Tags.
    var splitMetadata: TrackListing?
    var isShowingSplitLookup = false
    var splitLookupMode: SplitLookupMode = .musicBrainz
    var splitPasteText = ""
    /// Die Suche aus „Titel nachschlagen" — bleibt mit ihren Treffern
    /// erhalten, bis eine andere Datei kommt.
    var splitSearch: ReleaseSearch?
    #if DEBUG
    var splitDebugPick: Int?
    #endif
    var isLoadingWaveform = false

    // MARK: - Voreinstellungen

    /// Schlüssel in `UserDefaults`. Der Discogs-Token steht bewusst **nicht**
    /// hier, sondern im Schlüsselbund.
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

    // MARK: - Laufende Arbeit

    var isBusy = false
    var progress: Double = 0
    var progressLabel: LocalizedStringKey = ""
    /// Fortschrittsanzeige erst ab dieser Anzahl (Spec §4.1).
    static let progressThreshold = 20
    var showsProgress = false

    // MARK: - Fehler

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

    /// Ein Session-weiter Schritt reicht (Spec §4.1).
    var canUndo: Bool { !undoStack.isEmpty && !isBusy }

    // MARK: - Modusverfügbarkeit

    func availability(of mode: AppMode) -> ModeAvailability {
        switch mode {
        case .tag:
            .available
        case .convert:
            // Immer betretbar, auch ohne ffmpeg. Den Modus zu sperren wäre ein
            // Zirkelschluss: die Anleitung, wie man ffmpeg installiert, steht
            // genau in diesem Bereich. Am Starten hindert stattdessen der
            // `conversionBlocker`.
            .available
        case .rip:
            // Wie beim Konvertieren: immer betretbar. Ob eine Scheibe drin
            // liegt, sagt der Bereich selbst — sperren würde nur verbergen,
            // woran es liegt.
            .available
        }
    }

    // MARK: - Dateien laden

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
                // Eine unlesbare Datei darf den Import nicht abbrechen.
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

    // MARK: - Speichern

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
            // Vor dem Schreiben den Plattenstand sichern — das ist der
            // Undo-Schritt.
            let snapshot = UndoEntry(
                trackID: track.id,
                tags: track.original,
                fields: track.touchedFields
            )

            do {
                if !track.touchedFields.isEmpty {
                    try await engine.write(request)
                }
                // Umbenennen nach dem Schreiben — schlägt das Schreiben fehl,
                // soll die Datei unter ihrem alten Namen auffindbar bleiben.
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

    /// Nimmt den letzten Schreibvorgang zurück, indem der gesicherte Stand
    /// wieder auf die Platte geschrieben wird.
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

    // MARK: - Intern

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

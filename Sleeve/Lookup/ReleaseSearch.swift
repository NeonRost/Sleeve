//
//  ReleaseSearch.swift
//  Sleeve
//
//  Die Suche nach einem Album — dieselbe beim Taggen (Spec §4.6) und im
//  Track Splitter (§7.12). Quelle wählen, suchen, einen Treffer anklicken,
//  das Album laden. Was danach mit dem Album passiert, entscheidet das Blatt.
//

import Foundation

@MainActor
@Observable
final class ReleaseSearch {

    let service: LookupService
    var hasDiscogsToken: Bool

    private(set) var provider: LookupProvider
    var query: DiscogsClient.SearchQuery

    private(set) var results: [LookupSearchResult] = []
    private(set) var selectedID: String?
    private(set) var release: LookupRelease? {
        didSet { onReleaseChange?(release) }
    }
    /// Wer am geladenen Album hängt — beim Taggen die Zuordnung der Dateien.
    @ObservationIgnored var onReleaseChange: ((LookupRelease?) -> Void)?
    /// Zählt statt zu schalten: ein zweiter Klick, während der erste noch
    /// lädt, darf den Zeiger nicht vorzeitig ausschalten.
    private var pending = 0
    var isWorking: Bool { pending > 0 }
    private(set) var message: String?

    /// Was unter einer leeren Trefferliste steht. Der Splitter verweist dort
    /// aufs Einfügen einer Trackliste.
    var nothingFoundMessage = String(localized: "Nothing found. Try fewer words.")

    init(service: LookupService, provider: LookupProvider,
         query: DiscogsClient.SearchQuery, hasDiscogsToken: Bool) {
        self.service = service
        self.provider = provider
        self.query = query
        self.hasDiscogsToken = hasDiscogsToken
    }

    /// Discogs ohne Token ist nicht benutzbar — das muss vor dem Suchen klar sein.
    var providerBlocker: String? {
        guard provider.needsToken, !hasDiscogsToken else { return nil }
        return String(localized: "No Discogs token — add one in Settings.")
    }

    var canSearch: Bool { !query.isEmpty && !isWorking && providerBlocker == nil }

    /// Die Quelle wechseln heißt: neue Treffer. Die alten gehören zur anderen
    /// Quelle, und ein geladenes Album von dort passt nicht mehr zur Auswahl.
    func switchProvider(to newProvider: LookupProvider) async {
        guard newProvider != provider else { return }
        provider = newProvider
        results = []
        selectedID = nil
        release = nil
        message = nil
        await search()
    }

    func search() async {
        guard canSearch else { return }
        pending += 1
        message = nil
        release = nil
        selectedID = nil
        defer { pending -= 1 }

        do {
            results = try await service.search(query, using: provider)
            if results.isEmpty { message = nothingFoundMessage }
        } catch {
            results = []
            message = LookupService.describe(error)
        }
    }

    /// Einen Treffer wählen und sein Album laden. Wird inzwischen ein anderer
    /// gewählt, verfällt das Ergebnis — sonst gewänne der langsamere Abruf.
    func select(_ id: String?) async {
        selectedID = id
        release = nil
        guard let id, let result = results.first(where: { $0.id == id }) else { return }
        pending += 1
        message = nil
        defer { pending -= 1 }

        do {
            let loaded = try await service.release(result)
            if selectedID == id { release = loaded }
        } catch {
            if selectedID == id { message = LookupService.describe(error) }
        }
    }
}

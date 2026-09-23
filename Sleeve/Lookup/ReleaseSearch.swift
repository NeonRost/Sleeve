//
//  ReleaseSearch.swift
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
//  Searching for an album — the same when tagging (spec §4.6) and in the
//  Track Splitter (§7.12). Choose a source, search, click a result, load the
//  album. What happens with the album afterwards is up to the sheet.
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
    /// Whoever depends on the loaded album — when tagging, the file matching.
    @ObservationIgnored var onReleaseChange: ((LookupRelease?) -> Void)?
    /// Counts instead of toggling: a second click while the first is still
    /// loading must not switch the spinner off early.
    private var pending = 0
    var isWorking: Bool { pending > 0 }
    private(set) var message: String?

    /// What appears below an empty result list. The splitter points to pasting
    /// a track list there.
    var nothingFoundMessage = String(localized: "Nothing found. Try fewer words.")

    init(service: LookupService, provider: LookupProvider,
         query: DiscogsClient.SearchQuery, hasDiscogsToken: Bool) {
        self.service = service
        self.provider = provider
        self.query = query
        self.hasDiscogsToken = hasDiscogsToken
    }

    /// Discogs without a token cannot be used — that has to be clear before
    /// searching.
    var providerBlocker: String? {
        guard provider.needsToken, !hasDiscogsToken else { return nil }
        return String(localized: "No Discogs token — add one in Settings.")
    }

    var canSearch: Bool { !query.isEmpty && !isWorking && providerBlocker == nil }

    /// Switching the source means new results. The old ones belong to the other
    /// source, and an album loaded from there no longer matches the selection.
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

    /// Selects a result and loads its album. If another one gets selected in
    /// the meantime, the result is dropped — otherwise the slower request
    /// would win.
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

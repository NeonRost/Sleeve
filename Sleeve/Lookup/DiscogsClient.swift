//
//  DiscogsClient.swift
//  Sleeve
//

import Foundation

actor DiscogsClient {

    enum ClientError: Error, Equatable, Sendable {
        case missingToken
        case unauthorized
        case forbidden(String)
        case rateLimited
        case notFound
        case server(Int)
        case decoding(String)
        case transport(String)
    }

    struct SearchQuery: Sendable, Equatable {
        var artist = ""
        var releaseTitle = ""
        var year = ""
        var catalogNumber = ""

        var isEmpty: Bool {
            [artist, releaseTitle, year, catalogNumber]
                .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    /// Ohne eigenen User-Agent antwortet Discogs mit 403 — nachgeprüft, nicht
    /// nur behauptet (Spec §4.6).
    static let userAgent = "Sleeve/1.0 +https://github.com/NeonRost/Sleeve"

    private static let baseURL = URL(string: "https://api.discogs.com")!

    private let session: URLSession
    private var token: String?
    private var limiter: RateLimiter

    init(token: String?, session: URLSession = .shared) {
        self.session = session
        self.token = token
        self.limiter = RateLimiter.forDiscogs(authenticated: token?.isEmpty == false)
    }

    func updateToken(_ newToken: String?) {
        let normalized = newToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        token = (normalized?.isEmpty == false) ? normalized : nil
        limiter = RateLimiter.forDiscogs(authenticated: token != nil)
    }

    var hasToken: Bool { token != nil }

    // MARK: - Endpunkte

    /// Die Suche verlangt zwingend ein Token.
    func search(_ query: SearchQuery, limit: Int = 25) async throws -> [DiscogsSearchResult] {
        guard token != nil else { throw ClientError.missingToken }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: String(limit)),
        ]
        func add(_ name: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: trimmed))
        }
        add("artist", query.artist)
        add("release_title", query.releaseTitle)
        add("year", query.year)
        add("catno", query.catalogNumber)

        let response: DiscogsSearchResponse = try await get("/database/search", items: items)
        return (response.results ?? []).filter(\.isRelease)
    }

    /// Release-Details. Geht auch ohne Token, dann mit strengerem Limit.
    func release(id: Int) async throws -> DiscogsRelease {
        try await get("/releases/\(id)", items: [])
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, items: [URLQueryItem]) async throws -> T {
        await limiter.acquire()

        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !items.isEmpty { components.queryItems = items }

        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401:       throw ClientError.unauthorized
            case 403:       throw ClientError.forbidden(Self.message(in: data))
            case 404:       throw ClientError.notFound
            case 429:       throw ClientError.rateLimited
            default:        throw ClientError.server(http.statusCode)
            }
        }

        do {
            // Erst begradigen: Discogs schickt rohe Steuerzeichen in
            // Freitextfeldern, an denen JSONDecoder sonst scheitert.
            return try JSONDecoder().decode(
                T.self, from: JSONSanitizer.escapingControlCharactersInStrings(data))
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
    }

    private static func message(in data: Data) -> String {
        struct Envelope: Decodable { let message: String? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.message ?? ""
    }
}

extension DiscogsClient.ClientError {
    var readableDescription: String {
        switch self {
        case .missingToken:
            String(localized: "No Discogs token — add one in Settings.")
        case .unauthorized:
            String(localized: "Discogs rejected the token.")
        case .forbidden(let message):
            message.isEmpty ? String(localized: "Discogs refused the request.") : message
        case .rateLimited:
            String(localized: "Too many requests — try again in a moment.")
        case .notFound:
            String(localized: "Not found on Discogs.")
        case .server(let code):
            String(localized: "Discogs returned an error (\(code)).")
        case .decoding:
            String(localized: "The Discogs response could not be read.")
        case .transport(let message):
            message
        }
    }
}

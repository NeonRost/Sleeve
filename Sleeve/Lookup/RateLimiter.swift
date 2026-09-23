//
//  RateLimiter.swift
//  Sleeve
//

import Foundation

/// Hält das Discogs-Limit ein, **bevor** es zuschlägt (Spec §4.6).
///
/// Auf 429 zu reagieren wäre die schlechtere Lösung: Discogs sperrt dann
/// kurzzeitig ganz, und bei einem Album mit zwanzig Anfragen fällt das mitten
/// im Vorgang auf. Stattdessen ein gleitendes Fenster — die Anfrage wartet,
/// bis wieder Platz ist.
actor RateLimiter {

    private let limit: Int
    private let window: Duration
    private var timestamps: [ContinuousClock.Instant] = []
    private let clock = ContinuousClock()

    /// Discogs: 60 Anfragen pro Minute mit Token, 25 ohne.
    init(limit: Int, per window: Duration = .seconds(60)) {
        self.limit = max(1, limit)
        self.window = window
    }

    static func forDiscogs(authenticated: Bool) -> RateLimiter {
        // Ein Stück unter dem Limit bleiben — Discogs zählt serverseitig und
        // etwas anders als wir.
        RateLimiter(limit: authenticated ? 55 : 22)
    }

    /// Kehrt zurück, sobald eine Anfrage erlaubt ist.
    func acquire() async {
        while true {
            let now = clock.now
            timestamps.removeAll { now - $0 >= window }

            if timestamps.count < limit {
                timestamps.append(now)
                return
            }

            // Warten, bis die älteste Anfrage aus dem Fenster fällt.
            guard let oldest = timestamps.first else { continue }
            let wait = window - (now - oldest)
            try? await Task.sleep(for: wait > .zero ? wait : .milliseconds(50))
        }
    }

    /// Nur für Prüfungen: wie viele Anfragen im aktuellen Fenster stehen.
    var currentLoad: Int {
        let now = clock.now
        return timestamps.filter { now - $0 < window }.count
    }
}

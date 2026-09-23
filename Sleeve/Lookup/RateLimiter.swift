//
//  RateLimiter.swift
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

/// Keeps within the Discogs limit **before** it bites (spec §4.6).
///
/// Reacting to 429 would be the worse solution: Discogs then blocks entirely
/// for a while, and with an album of twenty requests that happens halfway
/// through. Instead a sliding window — a request waits until there is room
/// again.
actor RateLimiter {

    private let limit: Int
    private let window: Duration
    private var timestamps: [ContinuousClock.Instant] = []
    private let clock = ContinuousClock()

    /// Discogs: 60 requests per minute with a token, 25 without.
    init(limit: Int, per window: Duration = .seconds(60)) {
        self.limit = max(1, limit)
        self.window = window
    }

    static func forDiscogs(authenticated: Bool) -> RateLimiter {
        // Stay a little below the limit — Discogs counts on the server and slightly
        // differently from us.
        RateLimiter(limit: authenticated ? 55 : 22)
    }

    /// Returns as soon as a request is allowed.
    func acquire() async {
        while true {
            let now = clock.now
            timestamps.removeAll { now - $0 >= window }

            if timestamps.count < limit {
                timestamps.append(now)
                return
            }

            // Wait until the oldest request drops out of the window.
            guard let oldest = timestamps.first else { continue }
            let wait = window - (now - oldest)
            try? await Task.sleep(for: wait > .zero ? wait : .milliseconds(50))
        }
    }

    /// For checks only: how many requests are in the current window.
    var currentLoad: Int {
        let now = clock.now
        return timestamps.filter { now - $0 < window }.count
    }
}

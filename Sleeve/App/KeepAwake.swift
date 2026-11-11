//
//  KeepAwake.swift
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

/// Keeps the Mac from going to sleep while something runs that sleep would
/// ruin: a rip or an image (the drive spins down, the read fails), a burn
/// (the blank is lost), a long conversion or save. The display may still
/// sleep; only idle system sleep is held off.
///
/// Held for as long as the object lives:
///
///     let awake = KeepAwake("Ripping a CD")
///     defer { withExtendedLifetime(awake) {} }
final class KeepAwake: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ reason: String) {
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }

    deinit {
        ProcessInfo.processInfo.endActivity(token)
    }
}

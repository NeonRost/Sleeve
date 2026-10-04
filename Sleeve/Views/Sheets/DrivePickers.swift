//
//  DrivePickers.swift
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
//  Which drive to read from and which to burn with (spec §6.12). With one
//  drive — the normal case — there is nothing to pick and only its name is
//  shown; the picker appears with the second drive.
//

import SwiftUI

/// The drives holding an audio CD. Picking one reads its disc.
struct SourceDrivePicker: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let drives = state.sourceDrives
        Picker("Drive", selection: Binding(
            get: { state.effectiveSourceDrive?.bsdName ?? "" },
            set: { state.selectSourceDrive($0) })) {
            ForEach(Array(zip(drives, DriveNames.labels(for: drives.map(\.displayName)))),
                    id: \.0.id) { drive, label in
                Text(verbatim: label).tag(drive.bsdName)
            }
        }
    }
}

/// "Drive" in a form: the picker with several drives, the name with one.
struct SourceDriveRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.sourceDrives.count > 1 {
            SourceDrivePicker()
        } else {
            LabeledContent("Drive") {
                Text(state.effectiveSourceDrive?.displayName
                     ?? state.disc?.drive.displayName ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The burner, the same way.
struct BurnerRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let devices = state.burnDevices
        if devices.count > 1 {
            Picker("Drive", selection: Binding(
                get: { state.burnDevice?.id ?? "" },
                set: { state.selectBurnDevice($0) })) {
                ForEach(Array(zip(devices, DriveNames.labels(for: devices.map(\.displayName)))),
                        id: \.0.id) { device, label in
                    Text(verbatim: label).tag(device.id)
                }
            }
        } else {
            LabeledContent("Drive") {
                Text(state.burnDevice?.displayName ?? String(localized: "none found"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum DriveNames {
    /// Two drives of the same model would read the same in the picker, so
    /// they get numbered: "ASUS BW-16D1X-U (1)", "ASUS BW-16D1X-U (2)".
    static func labels(for names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            guard names.filter({ $0 == name }).count > 1 else { return name }
            seen[name, default: 0] += 1
            return "\(name) (\(seen[name]!))"
        }
    }
}

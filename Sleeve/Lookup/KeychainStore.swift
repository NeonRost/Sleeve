//
//  KeychainStore.swift
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
//  The Discogs token does not belong in the preferences but in the keychain
//  (spec §2, §4.6).
//

import Foundation
import Security

enum KeychainStore {

    private static let service = "de.neonrost.Sleeve"

    /// `false` when the keychain refused — locked, access denied. The
    /// caller has to say so instead of claiming the token is stored.
    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        guard let value, !value.isEmpty else {
            return remove(account)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
        ]

        // Update first; if the entry does not exist yet, create it.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updated == errSecItemNotFound else { return updated == errSecSuccess }
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func remove(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static let discogsToken = "discogs.token"
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

// Typed reads over a `JSONSerialization` object. `stringOrNull` collapses missing,
// JSON null (NSNull), and "" to nil — restoring the wire's distinction between an
// absent/empty string and a present one (e.g. a null topic vs. a real one), which a
// bare `as? String` on an NSNull would also give but which this makes explicit.
extension Dictionary where Key == String, Value == Any {
    func stringOrNull(_ key: String) -> String? {
        guard let value = self[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func string(_ key: String, _ fallback: String = "") -> String {
        self[key] as? String ?? fallback
    }

    /// nil for missing/null; used where absent (nil networkId → system buffer) must be
    /// distinguished from 0.
    func intOrNull(_ key: String) -> Int? {
        self[key] as? Int
    }

    func int(_ key: String, _ fallback: Int = 0) -> Int {
        self[key] as? Int ?? fallback
    }

    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        self[key] as? Bool ?? fallback
    }

    func objects(_ key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }

    /// A key present with a non-null value (`reset:false` still counts as present).
    func has(_ key: String) -> Bool {
        guard let value = self[key] else { return false }
        return !(value is NSNull)
    }
}

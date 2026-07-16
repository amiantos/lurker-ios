// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import LurkerKit

/// Non-secret UI config, in UserDefaults. The session *token* is a secret and lives in
/// the Keychain (`SessionStore`), never here. Typed accessors + registered defaults so
/// call sites read `UserPreferences.standard.lastServerURL`, not stringly-typed keys.
enum UserPreferences {
    fileprivate enum Key {
        static let lastServerURL = "lastServerURL"
        static let lastBackend = "lastBackend"
        static let recentBufferKeys = "recentBufferKeys"
        static let favoriteBufferKeys = "favoriteBufferKeys"
    }

    static var standard: UserDefaults {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.lastServerURL: Backend.selfHosted.defaultURL,
            Key.lastBackend: Backend.selfHosted.rawValue,
        ])
        return defaults
    }
}

extension UserDefaults {
    /// The server URL to prefill on the sign-in screen (last one used).
    var lastServerURL: String {
        string(forKey: UserPreferences.Key.lastServerURL) ?? Backend.selfHosted.defaultURL
    }

    func set(lastServerURL: String) {
        set(lastServerURL, forKey: UserPreferences.Key.lastServerURL)
    }

    /// The backend to preselect on the sign-in screen (last one used).
    var lastBackend: Backend {
        Backend(rawValue: string(forKey: UserPreferences.Key.lastBackend) ?? "") ?? .selfHosted
    }

    func set(lastBackend: Backend) {
        set(lastBackend.rawValue, forKey: UserPreferences.Key.lastBackend)
    }

    // MARK: - Quick switcher

    /// `BufferKey.id`s in most-recently-visited order, newest first.
    ///
    /// Stored rather than derived because recency is about what *you* did, which no server
    /// state records — a buffer's last message tells you the room was busy, not that you
    /// were in it. Kept as keys, not buffers, so a buffer that's since been closed simply
    /// fails to resolve and drops out of the list on its own.
    var recentBufferKeys: [String] {
        stringArray(forKey: UserPreferences.Key.recentBufferKeys) ?? []
    }

    /// Move a buffer to the front of the recency order.
    ///
    /// Unbounded: this is a list of buffer keys, a few dozen at most even for a heavy user,
    /// and truncating it would silently forget a buffer you'd visited. The *display* caps
    /// how many are shown; the record doesn't need to.
    func recordRecentBuffer(_ key: String) {
        var keys = recentBufferKeys
        keys.removeAll { $0 == key }
        keys.insert(key, at: 0)
        set(keys, forKey: UserPreferences.Key.recentBufferKeys)
    }

    /// `BufferKey.id`s the user pinned, in the order they pinned them.
    var favoriteBufferKeys: [String] {
        stringArray(forKey: UserPreferences.Key.favoriteBufferKeys) ?? []
    }

    func isFavorite(_ key: String) -> Bool {
        favoriteBufferKeys.contains(key)
    }

    /// Pin or unpin, returning the new state.
    @discardableResult
    func toggleFavorite(_ key: String) -> Bool {
        var keys = favoriteBufferKeys
        let wasFavorite = keys.contains(key)
        if wasFavorite {
            keys.removeAll { $0 == key }
        } else {
            keys.append(key)
        }
        set(keys, forKey: UserPreferences.Key.favoriteBufferKeys)
        return !wasFavorite
    }
}

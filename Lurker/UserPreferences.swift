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
        static let lastBufferTarget = "lastBufferTarget"
        static let lastBufferNetworkId = "lastBufferNetworkId"
    }

    /// Registration happens once, when this is first touched, rather than on every access.
    /// It used to be a computed property that re-registered the dictionary each time, which
    /// was free when the only readers were the sign-in screen — but the buffer list
    /// reaches through here several times per rebuild, and registering is idempotent
    /// work done to reach the same answer.
    static let standard: UserDefaults = {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.lastServerURL: Backend.selfHosted.defaultURL,
            Key.lastBackend: Backend.selfHosted.rawValue,
        ])
        return defaults
    }()
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

    // MARK: - State restoration

    /// The buffer that was on screen when the app was last used, so a relaunch lands where
    /// you left off instead of on the system buffer every time (#49).
    ///
    /// Stored as its parts rather than as a `BufferKey.id` like the lists above, because
    /// `id` lower-cases the target and this one is *reconstructed* into a buffer at launch
    /// — before any frame has arrived to correct the case. The lists only ever look keys up
    /// in state, so lossy is fine there and isn't here.
    ///
    /// A nil `networkId` is the system buffer, and is stored by *absence* — `object(forKey:)`
    /// returning nil is the only way UserDefaults can say "no integer here", since a missing
    /// integer key otherwise reads as 0, a real network id.
    var lastBufferKey: BufferKey? {
        guard let target = string(forKey: UserPreferences.Key.lastBufferTarget), !target.isEmpty else {
            return nil
        }
        return BufferKey(networkId: object(forKey: UserPreferences.Key.lastBufferNetworkId) as? Int, target: target)
    }

    func recordLastBuffer(_ key: BufferKey) {
        set(key.target, forKey: UserPreferences.Key.lastBufferTarget)
        if let networkId = key.networkId {
            set(networkId, forKey: UserPreferences.Key.lastBufferNetworkId)
        } else {
            removeObject(forKey: UserPreferences.Key.lastBufferNetworkId)
        }
    }

    /// Forgotten on sign-out. Restoration is the one preference here that *synthesizes* a
    /// buffer rather than looking one up, so a stale entry doesn't quietly fall out the way
    /// a stale recent does — signing in as somebody else would land them in a channel from
    /// the previous account.
    func forgetLastBuffer() {
        removeObject(forKey: UserPreferences.Key.lastBufferTarget)
        removeObject(forKey: UserPreferences.Key.lastBufferNetworkId)
    }

    /// Forgotten when the buffer itself is closed. That is the one case of "the buffer is
    /// gone" the client can actually *prove* — the user just left it from this device — and
    /// restoring into a buffer with no row sits on "Loading messages…" forever, because
    /// `hydrateIfNeeded` has nothing to ask about.
    ///
    /// Matched on `id`, not the key: the stored target keeps its original case while the
    /// store row carries whatever the server last said, and `#Lurker` is `#lurker`.
    func forgetLastBuffer(ifMatching key: BufferKey) {
        guard lastBufferKey?.id == key.id else { return }
        forgetLastBuffer()
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

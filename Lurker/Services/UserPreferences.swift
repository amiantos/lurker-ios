// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import LurkerKit

extension Notification.Name {
    /// A composer keyboard preference changed on this device.
    ///
    /// Settings is a sheet over the conversation, so the composer underneath it is never torn
    /// down and never re-appears — `viewWillAppear` doesn't fire for a `.pageSheet` dismissal,
    /// and there's no server frame to ride in on the way every other setting does. This is the
    /// signal that gets the new value onto a field that's already on screen.
    static let composerKeyboardPreferencesDidChange = Notification.Name(
        "composerKeyboardPreferencesDidChange"
    )
}

/// Non-secret UI config, in UserDefaults. The session *token* is a secret and lives in
/// the Keychain (`SessionStore`), never here. Typed accessors + registered defaults so
/// call sites read `UserPreferences.standard.lastServerURL`, not stringly-typed keys.
enum UserPreferences {
    fileprivate enum Key {
        static let lastServerURL = "lastServerURL"
        static let lastBackend = "lastBackend"
        static let recentBufferKeys = "recentBufferKeys"
        static let favoriteBufferKeys = "favoriteBufferKeys"
        static let migratedFavoritesToServer = "migratedFavoritesToServer"
        static let lastBufferTarget = "lastBufferTarget"
        static let lastBufferNetworkId = "lastBufferNetworkId"
        static let composerAutocapitalization = "composerAutocapitalization"
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
            // On by default — see `composerAutocapitalizes`. Registered rather than defaulted
            // at the call site because `bool(forKey:)` reads a missing key as false, which is
            // the opposite of what this one means when it hasn't been set.
            Key.composerAutocapitalization: true,
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

    // MARK: - Composer

    /// Whether the composer capitalizes sentences as you type. On by default.
    ///
    /// It was off outright for the app's first releases, on the reasoning that IRC is
    /// lowercase-native — nicks, `/commands`, `#channels`. That's true of the *first token of
    /// a line* and not of the prose after it, and it made this the one field on the phone that
    /// behaved unlike every other one, with no way to say otherwise. So: capitals by default,
    /// and off is something you ask for.
    ///
    /// Device-local, unlike the settings it sits under on that screen. It configures this
    /// phone's keyboard, and there is nothing on the other end of a sync to configure — the
    /// web client can't offer the choice at all, because Safari re-applies sentence caps
    /// whenever autocorrect is on (which is why its settings couple the two, and why UIKit
    /// keeping them independent is worth a switch of its own).
    var composerAutocapitalizes: Bool {
        bool(forKey: UserPreferences.Key.composerAutocapitalization)
    }

    func set(composerAutocapitalizes: Bool) {
        set(composerAutocapitalizes, forKey: UserPreferences.Key.composerAutocapitalization)
        NotificationCenter.default.post(name: .composerKeyboardPreferencesDidChange, object: nil)
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

    /// Favorites moved to the SERVER (lurker#721 — `favorite_buffers`, one global
    /// per-user order shared with the web client). These accessors exist only for the
    /// one-shot migration: the legacy device-local list is read once, pushed up as
    /// `favorite-buffer` verbs in stored order, and cleared behind the flag.
    var legacyFavoriteBufferKeys: [String] {
        stringArray(forKey: UserPreferences.Key.favoriteBufferKeys) ?? []
    }

    var migratedFavoritesToServer: Bool {
        get { bool(forKey: UserPreferences.Key.migratedFavoritesToServer) }
        set { set(newValue, forKey: UserPreferences.Key.migratedFavoritesToServer) }
    }

    func clearLegacyFavorites() {
        removeObject(forKey: UserPreferences.Key.favoriteBufferKeys)
    }

    // MARK: - Renames

    /// Follow a buffer rename through every preference that stores its key. Favorites no
    /// longer live here (server-side, keyed by buffer id — renames are free), so only the
    /// recents list and the last-buffer record need chasing.
    ///
    /// Substitution IN PLACE: a renamed recent keeps its recency. On a merge the new key
    /// may already be present; the first occurrence keeps its position and the later
    /// duplicate is dropped.
    ///
    /// A casing-only rename leaves the list alone — its keys are lowercased ids, so
    /// there is nothing to change — but still refreshes the last-buffer record, which is
    /// the one store that keeps the display casing (it *synthesizes* a buffer at launch).
    func rewriteBuffer(from: BufferKey, to: BufferKey) {
        if from.id != to.id {
            let recents = Self.substitute(from.id, with: to.id, in: recentBufferKeys)
            set(recents, forKey: UserPreferences.Key.recentBufferKeys)
        }
        if lastBufferKey?.id == from.id {
            recordLastBuffer(to)
        }
    }

    private static func substitute(_ old: String, with new: String, in keys: [String]) -> [String] {
        guard keys.contains(old) else { return keys }
        var seen = Set<String>()
        return keys.map { $0 == old ? new : $0 }.filter { seen.insert($0).inserted }
    }
}

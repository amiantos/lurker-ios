// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Last-known setting *values*, persisted across launches.
///
/// This exists for one reason, and it's a correctness one rather than a speed one:
/// `chat.send_typing_notifications` is a privacy switch, and without a cache the only answer
/// available before `/api/settings/bootstrap` returns is the registry default — `true`. So a
/// user who turned typing notifications **off** on the web would have their phone broadcast
/// `+typing` for the whole session any time that fetch failed: a flaky launch, or a
/// self-hosted server predating the endpoint. The setting used to be mirrored in
/// `UserPreferences` and survived relaunches; this is what replaces that guarantee.
///
/// It generalizes for free — every cached value is in force from the first frame, so the app
/// no longer starts under default rules and reflow into the user's real ones a moment later.
///
/// **Values only, not the registry.** A read consults `values` before the registry
/// (`Settings.effective`), so cached values alone are enough to make behavior correct with no
/// registry at all. The registry is only needed to *render controls*, and a settings screen
/// that needs the network once is a fair trade against silently broadcasting something the
/// user switched off.
/// Not `Sendable`: `UserDefaults` isn't, and this is only ever touched from the main actor
/// alongside the store it seeds.
public struct SettingsCache {
    private static let valuesKey = "lurker.settings.values"
    private let defaults: UserDefaults

    /// Injectable so tests get their own suite rather than scribbling on the app's defaults.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The values from the last session, or empty when there's nothing cached.
    public func load() -> [String: SettingValue] {
        guard let raw = defaults.dictionary(forKey: Self.valuesKey) else { return [:] }
        return raw.reduce(into: [:]) { out, pair in
            if let value = SettingValue.from(pair.value) { out[pair.key] = value }
        }
    }

    /// Replace the cache with the current values.
    ///
    /// A full replace rather than a merge, deliberately: this mirrors the server's stored set,
    /// and a setting reset to its default disappears from that set. Merging would keep the old
    /// value alive locally forever, which is exactly the kind of stale-forever state the cache
    /// is otherwise designed to avoid.
    public func save(_ values: [String: SettingValue]) {
        // `jsonValue` yields only String / Int / Bool / [String], all plist-legal.
        defaults.set(values.mapValues(\.jsonValue), forKey: Self.valuesKey)
    }

    /// Drop the cache. Called on sign-out: the next account's preferences are not this one's,
    /// and a privacy switch in particular must not carry across users.
    public func clear() {
        defaults.removeObject(forKey: Self.valuesKey)
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A stored setting value, in its decoded form. Mirrors the server's `SettingValue`
/// (`shared/settingsRegistry.ts`).
///
/// Modelled as a closed enum rather than `Any` so a value can survive the round trip —
/// bootstrap → store → a control → `PATCH` — without anything having to guess what it is
/// at each hop.
public enum SettingValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case stringList([String])

    /// Decode from the JSON shapes the server actually emits. `string`, `color`, `secret` and
    /// `enum` all arrive as strings; `int` as a number; `bool` as a boolean; `string-list` as
    /// an array of strings.
    ///
    /// Note `NSNumber` bridging: `JSONSerialization` decodes both `true` and `1` into
    /// `NSNumber`, so a bare `as? Int` would happily claim a boolean and a bare `as? Bool`
    /// would claim any nonzero int. The `CFBooleanGetTypeID` check is the only reliable way
    /// to tell them apart, and getting it wrong turns every `bool` setting into `int(1)`.
    public static func from(_ raw: Any) -> SettingValue? {
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .int(number.intValue)
        }
        if let text = raw as? String { return .string(text) }
        if let list = raw as? [String] { return .stringList(list) }
        // No lossy fallback for a mixed array. `compactMap`-ing the strings out of it would be
        // coercion wearing a decode's clothing: the value we'd hold — and write back — would be
        // a different list than the server sent. A key we can't represent exactly is one the
        // caller should skip, which is what returning nil gets it.
        return nil
    }

    /// Back to a JSON-encodable value for `PATCH /api/settings`.
    public var jsonValue: Any {
        switch self {
        case .string(let text): text
        case .int(let number): number
        case .bool(let flag): flag
        case .stringList(let list): list
        }
    }

    public var boolValue: Bool? { if case .bool(let flag) = self { flag } else { nil } }
    public var intValue: Int? { if case .int(let number) = self { number } else { nil } }
    public var stringValue: String? { if case .string(let text) = self { text } else { nil } }
}

/// How a setting is edited — the discriminant the settings screen renders from.
public enum SettingType: String, Sendable {
    case string
    case color
    case secret
    case int
    case bool
    case `enum`
    case stringList = "string-list"
}

/// One "this setting is live when…" clause from the registry's `dependsOn`.
///
/// The clauses on an option are ORed: it is live if any one of them holds. That matters for
/// the event tier, which is two keys (desktop and mobile) — a phone set to `none` must not
/// grey out consolidation knobs a desktop is actively using.
public struct SettingDependency: Equatable, Sendable {
    public let key: String
    public let values: [SettingValue]

    public init(key: String, values: [SettingValue]) {
        self.key = key
        self.values = values
    }
}

/// One entry from the server's settings registry.
///
/// Carried rather than duplicated in Swift: the registry is self-describing
/// (`CLIENT_PROTOCOL.md:723`), so labels, help text, bounds and choices come from the server
/// and can't drift out of sync with what it will actually accept. iOS curates *which* keys it
/// honors; the server describes them.
public struct SettingOption: Equatable, Sendable {
    public let key: String
    public let label: String
    public let description: String
    public let type: SettingType
    public let `default`: SettingValue
    /// `enum` only — the permitted choices, in the order the server lists them.
    public let choices: [String]
    /// `enum` only — display text per choice, for enums whose stored values are ids rather
    /// than English. A choice with no entry falls back to its raw value, so a partial (or
    /// absent) map is safe — which is also what an older server sends.
    public let choiceLabels: [String: String]
    /// `int` only — the server-enforced bounds, so a stepper can't offer a value that will be
    /// rejected on write.
    public let min: Int?
    public let max: Int?
    /// Conditions under which this setting does anything, ORed. Empty means unconditional.
    ///
    /// Registry data rather than a table maintained here (#666). This screen used to carry a
    /// hand-written `consolidate_max_names → consolidate_joins` map; the event tier added
    /// eight more dependencies, which is more than a hardcoded copy survives.
    public let dependsOn: [SettingDependency]

    public init(
        key: String, label: String, description: String, type: SettingType,
        default defaultValue: SettingValue, choices: [String] = [],
        choiceLabels: [String: String] = [:],
        min: Int? = nil, max: Int? = nil, dependsOn: [SettingDependency] = []
    ) {
        self.key = key
        self.label = label
        self.description = description
        self.type = type
        self.default = defaultValue
        self.choices = choices
        self.choiceLabels = choiceLabels
        self.min = min
        self.max = max
        self.dependsOn = dependsOn
    }

    /// The text to show for one of this option's `choices`, falling back to the raw value.
    public func label(forChoice choice: String) -> String {
        choiceLabels[choice] ?? choice
    }
}

/// The user's settings: the server's registry plus whatever they've actually stored.
///
/// **The two halves are not interchangeable.** `/api/settings/bootstrap` returns
/// `values: getUserSettings(userId)` — *stored* values only, with defaults NOT merged in
/// (`server/routes/settings.ts:14`). A user who has never opened settings gets `{}`. So a read
/// has to fall back through the registry, which is what `effective(_:)` is for and why nothing
/// should read `values` directly. Miss that and every bool reads false on a fresh account,
/// silently defaulting features off — the opposite of what the registry intends for most.
public struct Settings: Equatable, Sendable {
    /// Registry entries by key. Empty until bootstrap returns.
    public private(set) var registry: [String: SettingOption] = [:]
    /// Explicitly stored values by key — only what the user has actually changed.
    public private(set) var values: [String: SettingValue] = [:]
    /// Whether bootstrap has landed. Before it does, `effective` can only answer from the
    /// caller's fallback, so a screen can use this to avoid rendering controls it would have
    /// to correct a moment later.
    public private(set) var loaded = false

    public init() {}

    public init(registry: [String: SettingOption], values: [String: SettingValue], loaded: Bool = true) {
        self.registry = registry
        self.values = values
        self.loaded = loaded
    }

    /// The value in force for `key`: what the user stored, else the registry default, else nil
    /// for a key this server doesn't know. Mirrors the server's `effectiveSetting`
    /// (`settingsService.ts:14`) and the web's `settings.effective`.
    public func effective(_ key: String) -> SettingValue? {
        values[key] ?? registry[key]?.default
    }

    /// `effective` with a caller-supplied fallback for the window before bootstrap returns —
    /// and for a server too old to know the key at all. That second case is real rather than
    /// defensive: a self-hosted instance updates on its owner's schedule, so it can legitimately
    /// be older than the app talking to it, and a key it has never heard of is normal.
    ///
    /// The fallback should be the same default the registry carries, so behavior doesn't shift
    /// under the user when bootstrap lands a moment after launch.
    public func bool(_ key: String, default fallback: Bool) -> Bool {
        effective(key)?.boolValue ?? fallback
    }

    public func int(_ key: String, default fallback: Int) -> Int {
        effective(key)?.intValue ?? fallback
    }

    public func string(_ key: String, default fallback: String) -> String {
        effective(key)?.stringValue ?? fallback
    }

    /// How deep a `dependsOn` chain is followed before giving up. Real chains are two links
    /// (`consolidate_max_names → consolidate_joins → chat.events`); the cap only exists so a
    /// server-side registry edit that accidentally makes a cycle greys a row out instead of
    /// hanging the settings screen.
    private static let maxDependencyDepth = 8

    /// Whether a setting currently *does* anything, per its `dependsOn` clauses.
    ///
    /// Clauses are ORed; resolution is transitive, so an option whose dependency is itself
    /// inactive is inactive too and the registry states each link once. A clause naming a key
    /// this server doesn't know resolves on its value check alone — an older or newer server
    /// is a normal condition here, not an error.
    ///
    /// Presentation only, exactly as on the web: the stored value is untouched, because
    /// flipping the dependency back has to restore what the user had rather than a default.
    /// Mirrors `vue_client/src/utils/settingsRegistry.ts:optionEnabled`.
    public func isActive(_ key: String, depth: Int = 0) -> Bool {
        guard let option = registry[key], !option.dependsOn.isEmpty else { return true }
        guard depth < Self.maxDependencyDepth else { return false }
        return option.dependsOn.contains { dependency in
            guard let current = effective(dependency.key),
                  dependency.values.contains(current)
            else { return false }
            return isActive(dependency.key, depth: depth + 1)
        }
    }

    /// Replace everything — the bootstrap response.
    public mutating func load(registry: [String: SettingOption], values: [String: SettingValue]) {
        self.registry = registry
        self.values = values
        loaded = true
    }

    /// Merge a `settings` change frame (or a seed from the cache). A patch, never a replace:
    /// the frame carries only what changed (`wsHub.ts:1652`), so overwriting `values`
    /// wholesale would drop every other stored setting until the next bootstrap.
    public mutating func apply(changes: [String: SettingValue]) {
        for (key, value) in changes { values[key] = value }
    }

    /// Replace the stored values with an authoritative full set — the `{values}` a REST reply
    /// carries.
    ///
    /// Distinct from `apply(changes:)` because a full set can be *smaller* than what we hold,
    /// and merging would miss that. The server drops a row when a key is set back to its
    /// default — "no override" (`settingsService.ts:72`) — so a `PATCH` that returns to the
    /// default comes back as an ABSENCE, not as a value. Merged, the old override would
    /// survive locally (and get persisted to the cache) while the server has none; that's a
    /// setting stuck at a value the user has just cleared, for as long as it takes another
    /// bootstrap to land.
    public mutating func replaceValues(_ next: [String: SettingValue]) {
        values = next
    }
}

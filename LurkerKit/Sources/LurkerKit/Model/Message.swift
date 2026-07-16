// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// A line in a buffer. Faithful to the server's MessageEvent, trimmed to what a
/// client renders. `id` is the persisted message id (0 for ephemeral events).
public struct Message: Equatable, Sendable {
    public let id: Int
    public let type: EventType
    public let nick: String?
    public let text: String?
    public let isSelf: Bool
    public let time: String?
    /// A highlight rule matched this line — renders as a mention.
    public let matched: Bool

    public init(
        id: Int,
        type: EventType,
        nick: String?,
        text: String?,
        isSelf: Bool = false,
        time: String? = nil,
        matched: Bool = false
    ) {
        self.id = id
        self.type = type
        self.nick = nick
        self.text = text
        self.isSelf = isSelf
        self.time = time
        self.matched = matched
    }
}

/// The event enum the domain renders against. The server sends far more `type`s
/// than a 1.0 client special-cases (join/part/quit/mode/names/typing/presence/…);
/// everything not yet handled folds into `other` until a feature needs it.
public enum EventType: String, Sendable {
    case message
    case action
    case notice
    case error
    case system
    case join
    case part
    case quit
    case nick
    case kick
    case mode
    case topic
    case other = ""

    /// Types that render as someone speaking (vs. a structural/system line).
    public var isSpeech: Bool { self == .message || self == .action || self == .notice }

    public static func from(_ raw: String?) -> EventType {
        guard let raw, let type = EventType(rawValue: raw) else { return .other }
        return type
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A line in a buffer. Faithful to the server's MessageEvent, trimmed to what a
/// client renders. `id` is the persisted message id (0 for ephemeral events).
public struct Message: Equatable, Sendable {
    public let id: Int
    public let type: EventType
    public let nick: String?
    public let text: String?
    public let isSelf: Bool
    public let time: String?
    /// `time` parsed once, at the wire boundary. Rendering formats it and grouping
    /// compares it, and both run for every visible row on every reload — so it's parsed
    /// here rather than re-derived per read.
    public let date: Date?
    /// A highlight rule matched this line — renders as a mention.
    public let matched: Bool
    /// Severity, carried only by system-buffer lines. The server does NOT encode severity
    /// in `type` — an error is `type: "system"` with `level: "error"` — so styling a
    /// system line means reading this, never the type.
    public let level: SystemLevel?
    /// Which network a system line is *about*, when it's about one. The system buffer is
    /// app-scoped (`networkId == nil`), so this is what lets a line name its network in
    /// the prefix column instead of the generic "System".
    public let originNetworkId: Int?

    public init(
        id: Int,
        type: EventType,
        nick: String?,
        text: String?,
        isSelf: Bool = false,
        time: String? = nil,
        date: Date? = nil,
        matched: Bool = false,
        level: SystemLevel? = nil,
        originNetworkId: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.nick = nick
        self.text = text
        self.isSelf = isSelf
        self.time = time
        self.date = date
        self.matched = matched
        self.level = level
        self.originNetworkId = originNetworkId
    }
}

/// Severity of a system-buffer line. Absent/unrecognized → `info`, matching the server's
/// own default.
public enum SystemLevel: String, Sendable {
    case info
    case warn
    case error

    public static func from(_ raw: String?) -> SystemLevel {
        guard let raw, let level = SystemLevel(rawValue: raw) else { return .info }
        return level
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
    case motd
    case invite
    case e2e
    case ctcp
    case other = ""

    /// Types that render as someone speaking (vs. a structural/system line).
    public var isSpeech: Bool { self == .message || self == .action || self == .notice }

    /// Whether this renders as a bubble. Nearly everything does.
    ///
    /// The list is one thing — bubbles — rather than a bubble/line/box taxonomy sorted by
    /// how "conversational" a line was judged to be. That taxonomy kept drawing lines that
    /// were plainly a conversation as log output: your DM to NickServ bubbled while its
    /// reply didn't, and a `-SaslServ-` notice sat as a bare line under a run of bubbles
    /// for no reason a reader could see.
    ///
    /// An `action` is the exception: "* alice waves" puts the actor inside the sentence,
    /// so a bubble captioned with her nick would name her twice. It's narration about the
    /// room rather than speech in it, and stays a line — as it does in IRCCloud, Slack and
    /// Telegram.
    public var isBubble: Bool { self != .action }

    public static func from(_ raw: String?) -> EventType {
        guard let raw, let type = EventType(rawValue: raw) else { return .other }
        return type
    }
}

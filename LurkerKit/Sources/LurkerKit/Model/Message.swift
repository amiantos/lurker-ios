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
    /// The new name on a `nick` event. `nick` holds the old one, so a rename needs both to
    /// render "alice is now bob" and to follow an identity across a consolidation run.
    public let newNick: String?
    /// The target of a `kick` — who was removed. `nick` holds the actor doing the kicking.
    public let kicked: String?
    /// The target of an `invite` — who was invited. `nick` holds the inviter.
    public let invited: String?
    /// The parsed changes on a `mode` event (empty otherwise). `text` carries the same
    /// changes as a flat string; this is the structured form, so a consolidated run can
    /// group by flag ("+o alice, bob") rather than concatenating raw mode strings.
    public let modes: [ModeChange]

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
        originNetworkId: Int? = nil,
        newNick: String? = nil,
        kicked: String? = nil,
        invited: String? = nil,
        modes: [ModeChange] = []
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
        self.newNick = newNick
        self.kicked = kicked
        self.invited = invited
        self.modes = modes
    }

    /// Whether this event has anything to show.
    ///
    /// An activity line (join/part/nick/mode/…) synthesizes its body from structured
    /// fields — a join carries *no* `text` at all, yet renders "alice joined" — so it is
    /// always renderable regardless of `text`.
    ///
    /// Everything else draws its body from `text`, so an event with no text is a blank row.
    /// The server streams state-only events to a buffer alongside its log lines — a
    /// `usermode` carrying `modes`, an `away-state` carrying an `away` object, `lag`,
    /// `peer-presence` — none of which have a `text` field. The client parses them as
    /// `.other` (it consumes none of them yet) and, left in, each renders as an empty
    /// bubble. The web client either folds them into state or filters them; this is how
    /// the client keeps them off screen without modeling every one.
    public var isRenderable: Bool {
        if type.isActivity { return true }
        return !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One entry from a `mode` event's change list, e.g. `+o` on `alice`. `param` is nil for
/// paramless channel flags like `+n`/`+t`.
public struct ModeChange: Equatable, Sendable {
    /// The signed mode token, e.g. `"+o"` or `"-v"`.
    public let mode: String
    /// The argument the mode applies to, when it takes one (a nick for `+o`, a mask for
    /// `+b`, a key for `+k`). Nil for a bare channel flag.
    public let param: String?

    public init(mode: String, param: String?) {
        self.mode = mode
        self.param = param
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

    /// Structural "narration" about the room: membership churn and channel state. Each
    /// names its actor inside the synthesized sentence ("alice joined", "bob is now
    /// bob_afk", "mode by chan: +o"), so — exactly like an `action` — it renders as a
    /// full-width line rather than a nick-captioned bubble, which would say the name twice.
    ///
    /// This set also defines what participates in join consolidation (see `Consolidation`):
    /// a run of consecutive activity lines collapses into one net-effect summary.
    public var isActivity: Bool {
        switch self {
        case .join, .part, .quit, .nick, .kick, .mode, .topic, .invite: true
        default: false
        }
    }

    /// Whether this renders as a bubble. Speech and server text do; narration doesn't.
    ///
    /// Bubbles are one thing rather than a taxonomy sorted by how "conversational" a line
    /// was judged to be — that taxonomy kept drawing plain conversation as log output: your
    /// DM to NickServ bubbled while its reply didn't, and a `-SaslServ-` notice sat as a
    /// bare line under a run of bubbles for no reason a reader could see. So message,
    /// notice, and the server buffer's own text (motd/system/error/…) all bubble, captioned
    /// by their author — a nick, or the network speaking in its own voice.
    ///
    /// The exceptions are `action` and the `isActivity` events: they put the actor inside
    /// the sentence, so a nick-captioned bubble would name them twice. They stay full-width
    /// lines — as they do in IRCCloud, Slack and Telegram.
    public var isBubble: Bool { self != .action && !isActivity }

    public static func from(_ raw: String?) -> EventType {
        guard let raw, let type = EventType(rawValue: raw) else { return .other }
        return type
    }
}

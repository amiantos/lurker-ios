// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A line in a buffer. Faithful to the server's MessageEvent, trimmed to what a
/// client renders. `id` is the persisted message id (0 for ephemeral events).
public struct Message: Equatable, Sendable {
    public let id: Int
    public let type: EventType
    /// Who said it. **`var` only so `relayed(...)` can swap it for the speaker a relay bot was
    /// quoting** — like `matched`, it is writable from this file and nowhere else.
    public private(set) var nick: String?
    /// What they said. `var` for the same one reason `nick` is.
    public private(set) var text: String?
    public let isSelf: Bool
    public let time: String?
    /// `time` parsed once, at the wire boundary. Rendering formats it and grouping
    /// compares it, and both run for every visible row on every reload — so it's parsed
    /// here rather than re-derived per read.
    public let date: Date?
    /// A highlight rule matched this line — renders as a mention.
    ///
    /// Server-stamped, and writable only from this file, by `unhighlighted()`: the server
    /// decides what matched, and the one thing a client may do is take a match *off*. Scoped
    /// `private(set)` rather than `internal(set)` so even the store — the layer that must not
    /// write it — can't, which is where the invariant is actually stated.
    public private(set) var matched: Bool
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
    /// changes as a flat string; this is the structured form, so the line can render
    /// "+o alice" rather than a raw mode string.
    public let modes: [ModeChange]
    /// The post-change ident and host on a `chghost` event. Either half can be absent — the
    /// server stores an empty string when it lacks one — so the mask is built from whichever
    /// are present rather than assuming both.
    public let newIdent: String?
    public let newHost: String?
    /// The sender's `nick!ident@host` as the server stamped it, when it had one. Server
    /// messages and synthesized lines carry none.
    ///
    /// On a `chghost` line this is the mask *before* the change — the new one is `newIdent`/
    /// `newHost` — which is what makes "alice (old@mask) changed host to new@mask" readable.
    public let userhost: String?
    /// The joining user's services account, from extended-join. Nil on networks without the
    /// cap and for a logged-out user (the server stores the `*` sentinel as null), which are
    /// the same thing as far as a renderer is concerned: nothing to show.
    public let account: String?
    /// Whether this line was saved *as of the moment the server sent it*. Absent on the wire
    /// means unsaved (the server omits the field rather than sending false), so nearly every
    /// row costs nothing to carry it.
    ///
    /// **Don't render from this — ask `ChatState.isBookmarked(_:)`.** This is the wire seed,
    /// frozen at parse time; the store's id set is what also reflects a toggle made since,
    /// here or on another device. There is no bookmark snapshot in the connect burst, so this
    /// field is how the set learns about saves it didn't witness — for any line the client
    /// actually loads. The Bookmarks feed itself is the other source: its rows carry no flag
    /// (they're all saved) and seed the set through `noteBookmarked(ids:)`.
    public let bookmarked: Bool
    /// The relay bot this line actually came from, once it has been re-attributed (#277) — the
    /// only real IRC entity on the row, since `nick` now names someone with no presence here.
    ///
    /// Nil on every line that isn't a re-attributed one, which is nearly all of them. Absent from
    /// `init` on purpose: re-attribution is a *display* transform with exactly one producer
    /// (`relayed(...)`, below), so there is no path by which a line arrives from the wire already
    /// claiming to be relayed.
    public private(set) var relayBot: String?
    /// The `[source]` tag the envelope carried — "Discord", "Telegram", the bridged network's
    /// name. Nil when it carried none (a bare `<nick> message` relay), which is a real and common
    /// case, not a missing value: those envelopes simply don't say where the speaker was.
    public private(set) var relaySource: String?

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
        modes: [ModeChange] = [],
        newIdent: String? = nil,
        newHost: String? = nil,
        userhost: String? = nil,
        account: String? = nil,
        bookmarked: Bool = false
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
        self.newIdent = newIdent
        self.newHost = newHost
        self.userhost = userhost
        self.account = account
        self.bookmarked = bookmarked
    }

    /// This line with its highlight taken off — what a `NOHIGHLIGHT` ignore rule leaves behind
    /// (lurker #301): still visible, still counted, but never drawn as a mention.
    ///
    /// The server already suppresses the match at insert time for rules that existed then, so
    /// this is what makes a rule added *later* apply to backlog the server stamped before it —
    /// and, just as importantly, what lets the wash come back when the rule is removed, since
    /// the demotion happens per render rather than being written into the store.
    public func unhighlighted() -> Message {
        guard matched else { return self }
        var copy = self
        copy.matched = false
        return copy
    }

    /// This line as spoken by the person a relay bot was quoting (#277): `nick` and `text` become
    /// the embedded speaker and their words, and the bot moves to `relayBot`.
    ///
    /// Everything else is carried over deliberately, `id` included — this is the same log line,
    /// shown differently, so a bookmark, a jump and a mark-read all still address it. `isSelf`
    /// comes along too and is always false, because `RelayBotSet.reattributing` won't touch a line
    /// you sent.
    ///
    /// The one producer of a relayed `Message`, which is why the two fields it sets are writable
    /// from this file alone. It takes a non-optional `speaker` because a parse that produced no
    /// nick isn't a re-attribution at all — see the empty-nick check in `RelayEnvelope.parse`.
    public func relayed(to speaker: String, text relayedText: String, via bot: String, source: String?) -> Message {
        var copy = self
        copy.nick = speaker
        copy.text = relayedText
        copy.relayBot = bot
        copy.relaySource = source
        return copy
    }

    /// The `user@host` half of `userhost` (which arrives as the full `nick!user@host`), or nil
    /// when either piece is missing.
    ///
    /// Both halves are required: the server stores an empty ident or host when it lacks one
    /// (`nick!@host` / `nick!ident@`), and a half-mask like `@host` reads worse than nothing.
    /// Same rule the web applies in `eventHostSuffix()`.
    public var userHostMask: String? {
        guard let userhost, let bang = userhost.firstIndex(of: "!") else { return nil }
        let rest = userhost[userhost.index(after: bang)...]
        guard let at = rest.firstIndex(of: "@") else { return nil }
        let user = rest[..<at]
        let host = rest[rest.index(after: at)...]
        guard !user.isEmpty, !host.isEmpty else { return nil }
        return "\(user)@\(host)"
    }

    /// The post-change mask on a `chghost` line — `ident@host`, or whichever half the server
    /// actually sent. A half-mask like `@host` reads worse than the host alone, so the two
    /// are only joined with an `@` when both are present. Mirrors the web's `chghostMask()`
    /// and the server's own mask construction in the CHGHOST handler.
    public var chghostMask: String {
        let ident = newIdent ?? ""
        let host = newHost ?? ""
        if !ident.isEmpty && !host.isEmpty { return "\(ident)@\(host)" }
        return host.isEmpty ? ident : host
    }

    /// Whether this event has anything to show.
    ///
    /// An activity line (join/part/nick/mode/…) synthesizes its body from structured fields
    /// — a join carries *no* `text` at all, yet renders "alice joined" — so its renderability
    /// is whether the fields its line is built from are present, not whether `text` is. A
    /// `nick` with no `newNick` or a `mode` with neither a change list nor text has nothing
    /// to say: rendering it would produce a placeholder ("…is now someone", "chan set "), and
    /// it would seed consolidation with an empty-nick identity. Those are filtered here rather
    /// than papered over downstream.
    ///
    /// Everything else draws its body from `text`, so an event with no text is a blank row.
    /// The server streams state-only events to a buffer alongside its log lines — a
    /// `usermode` carrying `modes`, an `away-state` carrying an `away` object, `lag`,
    /// `peer-presence` — none of which have a `text` field. The client parses them as
    /// `.other` (it consumes none of them yet) and, left in, each renders as an empty line. The web client either folds them into state or filters them; this is how
    /// the client keeps them off screen without modeling every one.
    public var isRenderable: Bool {
        switch type {
        // Built from the actor nick; a reason/topic is optional.
        case .join, .part, .quit, .topic: hasNick
        // Both ends of the rename are needed to say "alice is now bob".
        case .nick: hasNick && !(newNick ?? "").isEmpty
        case .kick: hasNick && !(kicked ?? "").isEmpty
        case .invite: hasNick && !(invited ?? "").isEmpty
        // Needs somewhere to have changed *to*: with neither half of the new mask the line
        // reads "alice changed host to " and says nothing.
        case .chghost: hasNick && !chghostMask.isEmpty
        // A structured change list, or the raw mode string as a fallback.
        case .mode: !modes.isEmpty || hasText
        // Everything else draws its body from `text`.
        default: hasText
        }
    }

    private var hasNick: Bool { !(nick ?? "").isEmpty }
    private var hasText: Bool { !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
    case chghost
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
    /// bob_afk", "mode by chan: +o"), so — exactly like an `action` — it renders header-less,
    /// since an author header would say the name twice.
    ///
    /// This set also defines what participates in join consolidation (see `Consolidation`):
    /// a run of consecutive activity lines collapses into one net-effect summary.
    public var isActivity: Bool {
        switch self {
        case .join, .part, .quit, .nick, .kick, .mode, .topic, .invite, .chghost: true
        default: false
        }
    }

    /// Whether the line's author is separate from its text — which is what earns it an author
    /// header in the list, and what lets several of them stack under one.
    ///
    /// (Named `isBubble` from when the list drew these as chat bubbles. The distinction outlived
    /// the bubbles: it's still exactly "does this line need to be told who said it".)
    ///
    /// One category rather than a taxonomy sorted by how "conversational" a line was judged to
    /// be — that taxonomy kept drawing plain conversation as log output: your DM to NickServ was
    /// captioned while its reply wasn't, and a `-SaslServ-` notice sat bare under a run of
    /// captioned lines for no reason a reader could see. So message, notice, and the server
    /// buffer's own text (motd/system/error/…) all take a header — a nick, or the network
    /// speaking in its own voice.
    ///
    /// The exceptions are `action` and the `isActivity` events: they put the actor inside the
    /// sentence, so a header would name them twice. They render header-less, flush with where a
    /// nick would be — as they do in IRCCloud, Slack and Telegram.
    public var isBubble: Bool { self != .action && !isActivity }

    public static func from(_ raw: String?) -> EventType {
        guard let raw, let type = EventType(rawValue: raw) else { return .other }
        return type
    }
}

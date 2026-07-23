// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// A conversation surface: a channel, a DM, a per-network server buffer, or the
/// app-scoped system buffer. There is no buffer id on the wire — a buffer is
/// identified by (networkId, target). `networkId` is nil ONLY for the system buffer.
///
/// Per-buffer counts (`unread`/`highlights`/`lastReadId`) are server-authoritative:
/// they ship in `backlog`/`read-state` frames and the client never derives them
/// locally (full read-state handling is #7).
public struct Buffer: Equatable, Sendable {
    public let networkId: Int?
    public let target: String
    public let kind: BufferKind
    public var unread: Int
    public var highlights: Int
    public var lastReadId: Int
    public var joined: Bool
    /// False until the server has actually read this buffer's history. On a fresh
    /// connect channel/DM buffers arrive as SHELLS (`events: []`); their history is
    /// not read until the client sends `open-buffer`.
    public var hydrated: Bool
    /// Whether more history exists above what's loaded — gates the scroll-up pagination
    /// (#6). Defaults true (an unopened buffer has all its history still to fetch).
    public var hasMoreOlder: Bool
    /// Whether the loaded slice sits *below* the live tail — true only after a jump lands an
    /// `around` slice centered on an older message (#42). While set, the buffer is "detached":
    /// live events are held out of the log (they'd splice a hole past the slice), and the
    /// jump-to-latest pill re-attaches by fetching the latest. A normal (latest) buffer is at
    /// the tail, so this defaults false.
    public var hasMoreNewer: Bool
    /// A channel's topic, when it has one. Nil on a channel with no topic set *and* on
    /// every other kind — nothing but a channel has one.
    ///
    /// Fed from three places, because the server has three ways of saying it: the
    /// `snapshot` (on connect), a `channel-topic` ephemeral (RPL_TOPIC on join, silent),
    /// and a `topic` event (someone changed it, which also prints a line).
    public var topic: String?

    public init(
        networkId: Int?,
        target: String,
        kind: BufferKind,
        unread: Int = 0,
        highlights: Int = 0,
        lastReadId: Int = 0,
        joined: Bool = false,
        hydrated: Bool = false,
        hasMoreOlder: Bool = true,
        hasMoreNewer: Bool = false,
        topic: String? = nil
    ) {
        self.networkId = networkId
        self.target = target
        self.kind = kind
        self.unread = unread
        self.highlights = highlights
        self.lastReadId = lastReadId
        self.joined = joined
        self.hydrated = hydrated
        self.hasMoreOlder = hasMoreOlder
        self.hasMoreNewer = hasMoreNewer
        self.topic = topic
    }

    public var key: BufferKey { BufferKey(networkId: networkId, target: target) }

    /// The server's sentinel target for the app-scoped system buffer.
    public static let systemTarget = ":system:"

    /// The system buffer, constructed without the server. It's app-scoped and always
    /// exists, so the app can open it as its landing screen before any frame has arrived;
    /// the real one folds in over this when the backlog lands.
    public static let system = Buffer(networkId: nil, target: systemTarget, kind: .system)

    /// What to call this buffer wherever the user sees it.
    ///
    /// Shared rather than per-screen: the title pill and the buffer switcher name the same
    /// buffer one tap apart, and two copies of this drifted immediately — the switcher
    /// called a server log "Server" while the pill it opened called it "libera".
    ///
    /// `networkName` is the network this buffer belongs to, when it's known; only a server
    /// log uses it, and it falls back rather than requiring the caller to have resolved the
    /// roster yet.
    public func displayName(networkName: String? = nil) -> String {
        switch kind {
        case .system: "Lurker" // the app's own buffer, not a target you'd recognize
        case .server: networkName ?? "Server"
        case .channel, .dm: target
        }
    }
}

/// Stable identity for a buffer, plus its string form for use as a dictionary key.
///
/// IRC targets are case-insensitive and servers send them inconsistently cased
/// (`#Chan` on join vs. `#chan` in a snapshot; DM nick-case drift). So identity
/// folds case while [target] keeps the original casing for display and for echoing
/// back to the server on send. The fold is client-internal, so any deterministic
/// mapping works; house style is lowercase.
public struct BufferKey: Equatable, Hashable, Sendable {
    public let networkId: Int?
    public let target: String

    public init(networkId: Int?, target: String) {
        self.networkId = networkId
        self.target = target
    }

    public var id: String { "\(networkId.map(String.init) ?? "sys")::\(target.lowercased())" }
}

public enum BufferKind: Sendable {
    case channel
    case dm
    case server
    case system

    /// Classify a target the way the server does (isDmTarget / SYSTEM_TARGET).
    public static func of(networkId: Int?, target: String) -> BufferKind {
        if networkId == nil || target == Buffer.systemTarget { return .system }
        if target.hasPrefix(":server:") { return .server }
        if target.hasPrefix("#") || target.hasPrefix("&") { return .channel }
        return .dm
    }

    /// Whether an event of this type is something this buffer kind shows.
    ///
    /// This is per-kind and not a single global predicate because a buffer kind's content
    /// is not the same shape everywhere:
    ///
    ///  - A **channel or DM** shows speech *and* its structural traffic — joins, parts,
    ///    quits, nick changes, modes, kicks, topics, invites, and the odd inline error or
    ///    encryption line. Consecutive membership churn collapses (see `Consolidation`), so
    ///    showing it is signal, not noise. What a channel never carries is the app/server
    ///    scoped `motd`/`system`, or the unmodeled `.other` state events (usermode, lag,
    ///    peer-presence) that have no body — those are excluded here.
    ///  - The **system buffer**'s content is *entirely* `type: "system"` lines, which are
    ///    not speech — filtering it by `isSpeech` renders it permanently empty.
    ///  - A **server log** is a log: it shows everything. What the server actually sends
    ///    there is `motd`, `usermode`, `error`, `notice` and `invite`, and only `notice`
    ///    is speech — so `isSpeech` hid the entire MOTD, every mode line, and every server
    ///    error, leaving a buffer that looked almost empty rather than broken.
    public func renders(_ type: EventType) -> Bool {
        switch self {
        case .system: type == .system
        case .server: true
        case .channel, .dm:
            switch type {
            case .motd, .system, .other: false
            default: true
            }
        }
    }

    /// Whether the server will answer an `open-buffer` for this kind.
    ///
    /// It won't for the system buffer or a `:server:` log — `handleOpenBuffer` discards
    /// both up front (`if (!networkId || requested.startsWith(':server:')) return`) and
    /// sends no reply, because their history ships complete in the connect backlog rather
    /// than on demand. Asking anyway isn't harmless: the caller has no failure to observe,
    /// so it waits forever on a reply the server already threw away.
    public var hydratesOnDemand: Bool {
        switch self {
        case .channel, .dm: true
        case .system, .server: false
        }
    }
}

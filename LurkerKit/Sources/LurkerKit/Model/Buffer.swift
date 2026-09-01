// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A conversation surface: a channel, a DM, a per-network server buffer, or the
/// app-scoped system buffer. Identified on the wire by `bufferId` — the server's
/// stable integer that survives renames (protocol §5.2) — with `(networkId,
/// target)` as the always-present name-shaped address; `bufferId` is nil only
/// until the first id-carrying frame lands (an optimistically-created buffer, or
/// a pre-id server). `networkId` is nil ONLY for the system buffer.
///
/// Per-buffer counts (`unread`/`highlights`/`lastReadId`) are server-authoritative:
/// they ship in `backlog`/`read-state` frames and the client never derives them
/// locally (full read-state handling is #7).
public struct Buffer: Equatable, Sendable {
    /// The server's stable buffer id (never changes, renames included). Var, not
    /// let: a row created before the id was known learns it from a later frame.
    public var bufferId: Int?
    public let networkId: Int?
    public let target: String
    public let kind: BufferKind
    public var unread: Int
    public var highlights: Int
    public var lastReadId: Int
    public var joined: Bool
    /// False until the server has actually read this buffer's history. On a fresh
    /// connect channel/DM buffers arrive as SHELLS (`events: []`); their history is
    /// not read until the client asks for it (`ChatViewModel.hydrate`).
    public var hydrated: Bool
    /// Whether `lastReadId` is something the server SAID, rather than this struct's default.
    ///
    /// Three paths materialize a buffer row without any read state attached — the connect
    /// `snapshot` (a row per joined channel), a live event for an unseen target (a new DM), and
    /// a `history` reply (which flips `hydrated` but carries no read fields at all). Under all
    /// three, `lastReadId` reads 0, which is indistinguishable from "read nothing" and cannot be
    /// told apart by looking at the value. Only `backlog` and `read-state` frames carry the
    /// pointer, so only they set this.
    ///
    /// It exists because a reader whose boundary is latched from a defaulted 0 loses their
    /// unread divider outright, and anything that marks the buffer read before the real pointer
    /// arrives destroys it for good — the pointer is the only record of where they left off.
    /// `hydrated` is NOT a stand-in for this: `history mode:latest` sets it while saying nothing
    /// about read state, which is exactly the case that bug arrived through.
    public var readStateKnown: Bool
    /// Whether more history exists above what's loaded — gates the scroll-up pagination
    /// (#6). Defaults true (an unopened buffer has all its history still to fetch).
    public var hasMoreOlder: Bool
    /// Whether the loaded slice sits *below* the live tail — true only after a jump lands an
    /// `around` slice centered on an older message (#42). While set, the buffer is "detached":
    /// live events are held out of the log (they'd splice a hole past the slice), and the
    /// jump-to-latest pill re-attaches by fetching the latest. A normal (latest) buffer is at
    /// the tail, so this defaults false.
    public var hasMoreNewer: Bool
    /// Whether this buffer is currently showing what its `/clear` marker hides (#121) — set
    /// when a jump lands on a message below the boundary, so the row the reader asked for can
    /// actually render.
    ///
    /// ⚠⚠ Deliberately NOT `hasMoreNewer`, which was the first two attempts at this. That flag
    /// means "the slice sits below the live tail" and drives paging: setting it on a buffer
    /// that already holds the tail makes `scrollViewDidScroll` fire `loadNewer` the moment the
    /// reader is near the bottom — which they are, having just landed near it — and the empty
    /// reply carries `hasMoreNewer: false`, which re-attaches and re-hides everything. That is
    /// the "messages flash then disappear" bug. "I am looking at hidden history" and "there is
    /// more history below me" are two different facts and need two different flags.
    ///
    /// Reset by a `latest` history slice — the return-to-live fetch a reopen makes — so the
    /// clear takes hold again next time the buffer is opened.
    public var showsClearedHistory: Bool
    /// The `/clear` marker's boundary: the highest message id hidden from the live view
    /// (#121). 0 means the buffer has never been cleared, or the user undid it.
    ///
    /// Server-side and per-user, so it is shared with every other device — which is why this
    /// is honoured whether or not this client can *issue* a clear. It survives a close and
    /// reopen: the server keeps it on `buffer_reads`, which closing doesn't touch.
    ///
    /// ⚠⚠ The filter is suppressed while the buffer is **detached**. A jump to a search hit or
    /// a highlight shows context around its anchor regardless of the marker — the user asked
    /// to see that message, and hiding it would answer their tap with an empty screen. Same
    /// rule as the web (`MessageList.vue:1064`), and the reason the filter lives at row-build
    /// time rather than in the store: the messages are still there, they are just not drawn.
    public var clearedBeforeId: Int
    /// When the clear was issued, for the divider's label. Nil exactly when `clearedBeforeId`
    /// is 0.
    ///
    /// An instant rather than a formatted string, like `awayDivider`'s: what the label says is
    /// a render-time decision, so a redraw corrects it when the locale or the day changes.
    public var clearedAt: Date?
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
        readStateKnown: Bool = false,
        hasMoreOlder: Bool = true,
        hasMoreNewer: Bool = false,
        clearedBeforeId: Int = 0,
        clearedAt: Date? = nil,
        showsClearedHistory: Bool = false,
        topic: String? = nil,
        bufferId: Int? = nil
    ) {
        self.bufferId = bufferId
        self.networkId = networkId
        self.target = target
        self.kind = kind
        self.unread = unread
        self.highlights = highlights
        self.lastReadId = lastReadId
        self.joined = joined
        self.hydrated = hydrated
        self.readStateKnown = readStateKnown
        self.hasMoreOlder = hasMoreOlder
        self.hasMoreNewer = hasMoreNewer
        self.clearedBeforeId = clearedBeforeId
        self.clearedAt = clearedAt
        self.showsClearedHistory = showsClearedHistory
        self.topic = topic
    }

    public var key: BufferKey { BufferKey(networkId: networkId, target: target) }

    /// Whether a page of older history could contain a row this buffer would actually draw.
    ///
    /// False when a `/clear` is in force and `oldestHeldId` is already at or below the
    /// boundary: everything older than the oldest held message is older still, so every row a
    /// page could bring is hidden by definition and the fetch cannot add a visible line.
    ///
    /// ⚠⚠ Without this the screen becomes a history vacuum rather than merely over-fetching. A
    /// cleared buffer builds to a single divider, which is unscrollable, which asks for another
    /// page, which is also entirely hidden, which is still unscrollable — walking the whole
    /// buffer into memory an invisible page at a time behind a stuck spinner. The web guards
    /// the same thing at the same point (`MessageList.vue:1564`).
    ///
    /// Detached is exempt because the FILTER is exempt: a jump slice shows its context
    /// regardless of the marker, so those pages are visible and worth fetching.
    func olderPageCouldBeVisible(oldestHeldId: Int) -> Bool {
        guard hidesClearedHistory, clearedBeforeId > 0 else { return true }
        return oldestHeldId > clearedBeforeId
    }

    /// Whether the `/clear` filter is actually in force right now — a marker is set, and this
    /// view is neither detached nor deliberately showing what it hides.
    public var hidesClearedHistory: Bool { !hasMoreNewer && !showsClearedHistory }

    /// Move the `/clear` marker (#121) — a `buffer-cleared` frame, from this device or another.
    ///
    /// The two fields move together or not at all. `beforeId <= 0` is the UNDO and clears
    /// both, which is exactly what the server sends for `/clear off`.
    ///
    /// ⚠⚠ So is a boundary with no instant — the state that would hide every row and draw no
    /// divider, leaving the reader a blank buffer whose only way out is a `/clear off` nobody
    /// told them about. Showing messages the user cleared is the safe direction to fail in.
    mutating func applyCleared(beforeId: Int, at: Date?) {
        guard beforeId > 0, let at else {
            clearedBeforeId = 0
            clearedAt = nil
            return
        }
        clearedBeforeId = beforeId
        clearedAt = at
    }

    /// This buffer under a new name — the rename primitive's client half. Same
    /// id (that's the point), same counts and read state; `kind` re-derives in
    /// case the sigil changed, and paging state carries as-is (the caller wipes
    /// it separately on a merge, where history actually changed).
    func renamed(to newTarget: String) -> Buffer {
        Buffer(
            networkId: networkId,
            target: newTarget,
            kind: BufferKind.of(networkId: networkId, target: newTarget),
            unread: unread,
            highlights: highlights,
            lastReadId: lastReadId,
            joined: joined,
            hydrated: hydrated,
            readStateKnown: readStateKnown,
            hasMoreOlder: hasMoreOlder,
            hasMoreNewer: hasMoreNewer,
            clearedBeforeId: clearedBeforeId,
            clearedAt: clearedAt,
            showsClearedHistory: showsClearedHistory,
            topic: topic,
            bufferId: bufferId
        )
    }

    /// The server's sentinel target for the app-scoped system buffer.
    public static let systemTarget = ":system:"

    /// A network's server-log target. The web's `serverTarget()`, and the same string the
    /// server uses.
    ///
    /// ⚠ This client only ever *recognised* the prefix before, never built one — so a
    /// network's server log appeared in the buffer list solely when a row for it happened to
    /// arrive, and vanished when the connect burst's prune didn't name it. The web has no
    /// such gap: its network header **is** the server buffer, addressed by a target it
    /// constructs itself, so every network always has one visible way in.
    public static func serverTarget(_ networkId: Int) -> String { ":server:\(networkId)" }

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

    /// Classify a target the way the server does (kindForTarget): all FOUR IRC channel
    /// sigils count — `ChannelName.isChannelTarget`, the one owner of the question — or a
    /// favorited `+foo` would masquerade as a person under Friends, presence dot and all.
    public static func of(networkId: Int?, target: String) -> BufferKind {
        if networkId == nil || target == Buffer.systemTarget { return .system }
        if target.hasPrefix(":server:") { return .server }
        if ChannelName.isChannelTarget(target) { return .channel }
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

    /// Whether this kind has a shell that needs filling in.
    ///
    /// It doesn't for the system buffer or a `:server:` log: their history ships complete in
    /// the connect backlog, so there is nothing on demand to fetch.
    ///
    /// This used to carry a sharper warning — hydration went through `open-buffer`, which
    /// discards both kinds up front and sends NO reply, so asking stranded the caller on a
    /// reply the server had already thrown away. Hydration is `{type:'history',
    /// mode:'latest'}` now, which answers for any target it can read, so the hazard is gone
    /// and this is once again just "don't ask for what you already have".
    public var hydratesOnDemand: Bool {
        switch self {
        case .channel, .dm: true
        case .system, .server: false
        }
    }
}

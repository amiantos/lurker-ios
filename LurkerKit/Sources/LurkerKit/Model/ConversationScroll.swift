// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// What the rows are built under that belongs to the SCREEN rather than the store — three
/// values `ChatViewController` used to hand `MessageRows` from its own fields. A value, so a
/// build can carry the options it was made with and the model can tell a stale build from a
/// current one (`ConversationBuild.options` vs `ConversationScroll.options`).
///
/// lurker-android's `RowOptions`, ported back.
public struct RowOptions: Equatable, Sendable {
    /// The read boundary, latched the first time the server states it and held for the visit —
    /// the divider must not move as the screen marks messages read live. Nil is "not told yet",
    /// which is not the same as 0, "nothing read".
    public var dividerAfterId: Int?
    /// The one message id the ignore filter must not drop — the latest jump's target, for the
    /// screen's life. You reach one by naming a specific message, and the rules can have changed
    /// since; filtering it out would land the reader on a row that isn't drawn, which never
    /// resolves. Outlives the landing, so the row doesn't vanish from under the reader the
    /// instant they arrive on it.
    public var keeping: Int?
    /// The reader is deliberately looking past the `/clear` marker — a jump landed on a row
    /// below it (lurker-ios#121). See `ConversationScroll.onRows` for when it arms and retires.
    public var showsClearedHistory: Bool

    public init(dividerAfterId: Int? = nil, keeping: Int? = nil, showsClearedHistory: Bool = false) {
        self.dividerAfterId = dividerAfterId
        self.keeping = keeping
        self.showsClearedHistory = showsClearedHistory
    }
}

/// One build of the rows and everything derived from it: the screen's filtered messages, the
/// rows the table draws, and the frame they came from. lurker-android's `BuiltRows`.
///
/// Made by `make`, which is the whole of the screen's render pipeline — the kind filter, the
/// ignore rules, relay re-attribution, reply presentation, then `MessageRows.build` — so a test
/// builds exactly what the app draws.
public struct ConversationBuild: Sendable {
    public let key: BufferKey
    public let kind: BufferKind
    public let options: RowOptions
    /// The store's raw list for this buffer — nil when the store holds no entry at all.
    public let held: [Message]?
    public let buffer: Buffer?
    /// Compared by identity: the store replaces the set when the rules change.
    public let ignores: IgnoreSet
    public let settings: Settings
    public let speakers: SpeakerMap
    public let ownNick: String?
    public let awayState: AwayState?
    public let rosterSettled: Bool
    /// The filtered messages the rows were built from — what `ChatViewController` calls `messages`.
    public let visible: [Message]
    public let rows: [MessageRow]
    /// The frame this build's state is — see `ReplyWatch.landedIn` for why a jump has to know.
    public let seq: Int
    /// The row the unread divider sits at, cached once per build for the scroll-tick hot path.
    public let dividerRow: Int?

    /// The first unread row — the one just below the divider. The single definition of "where
    /// the unreads begin", for the banner, the jump target and the flash.
    public var firstUnreadRow: Int? {
        dividerRow.flatMap { rows.indices.contains($0 + 1) ? $0 + 1 : nil }
    }

    /// The buffer is showing a slice below the live tail (lurker-ios#42).
    public var detached: Bool { buffer?.hasMoreNewer == true }

    /// Whether what's loaded is the buffer's real history yet, rather than the few live events
    /// that outran its backlog — `BufferPlaceholder.historyLanded`, never a bare `hydrated`.
    public var historyLanded: Bool {
        BufferPlaceholder.historyLanded(
            hydrated: buffer?.hydrated == true,
            hydratesOnDemand: kind.hydratesOnDemand,
            bufferExists: buffer != nil,
            rosterSettled: rosterSettled
        )
    }

    /// The row that now stands for message `id` — its own, or the summary whose span covers it
    /// after a page merged it into a consolidated run. Resolved by MESSAGE ID on every call,
    /// never a cached index: a rebuild between two passes shifts every index.
    public func rowIndex(containing id: Int) -> Int? {
        rows.firstIndex { $0.represents(id) }
    }

    public init(
        key: BufferKey, kind: BufferKind, options: RowOptions, held: [Message]?, buffer: Buffer?,
        ignores: IgnoreSet, settings: Settings, speakers: SpeakerMap, ownNick: String?,
        awayState: AwayState?, rosterSettled: Bool, visible: [Message], rows: [MessageRow], seq: Int
    ) {
        self.key = key
        self.kind = kind
        self.options = options
        self.held = held
        self.buffer = buffer
        self.ignores = ignores
        self.settings = settings
        self.speakers = speakers
        self.ownNick = ownNick
        self.awayState = awayState
        self.rosterSettled = rosterSettled
        self.visible = visible
        self.rows = rows
        self.seq = seq
        self.dividerRow = rows.firstIndex { if case .unreadDivider = $0 { return true }; return false }
    }

    /// Your nick on this buffer's network, or nil where there is none (the system buffer).
    public static func ownNick(for state: ChatState, key: BufferKey) -> String? {
        key.networkId.flatMap { state.networks[$0]?.nick }
    }

    /// Your own away state as it applies to *this* buffer (lurker-ios#68), or nil where it
    /// doesn't. Away is per network (lurker#994). Conversations only: the `:server:` log and the
    /// system buffer are narration about the connection, not a conversation you were absent
    /// from.
    public static func awayState(for state: ChatState, key: BufferKey, kind: BufferKind) -> AwayState? {
        switch kind {
        case .channel, .dm, .dcc:
            return key.networkId.flatMap { state.networks[$0]?.away }
        case .server, .system:
            return nil
        }
    }

    /// The screen's render pipeline over one frame.
    ///
    /// Filter by what this *kind* of buffer renders (the system buffer's content is entirely
    /// `type: "system"`, which isn't speech). The render-time ignore filter (lurker#301) sits on
    /// top: hidden lines drop out, and a NOHIGHLIGHT-covered line loses its mention wash — at
    /// render rather than on the way into the store, which is what makes a rule retroactive both
    /// ways. Relay re-attribution (lurker-ios#277) sits on top of both, and last: it has to see
    /// what the ignore filter left, and the rules above match the bot's real nick. Replies
    /// (lurker-ios#184) read last of all: a reply's quote is judged against the line as it now
    /// displays, a relayed one included.
    public static func make(
        state: ChatState, key: BufferKey, kind: BufferKind, options: RowOptions, seq: Int,
        now: Date = Date()
    ) -> ConversationBuild {
        let held = state.messages[key.id]
        let buffer = state.buffers[key.id]
        let ownNick = ownNick(for: state, key: key)
        let awayState = awayState(for: state, key: key, kind: kind)
        let speakers = state.speakers[key.id] ?? SpeakerMap()
        let visible = Replies.presenting(
            state.relayBots.reattributing(
                state.ignores.visible(
                    (held ?? []).filter { kind.renders($0.type) && $0.isRenderable },
                    networkId: key.networkId,
                    target: key.target,
                    keeping: options.keeping,
                    now: now
                ),
                networkId: key.networkId
            ),
            networkId: key.networkId,
            target: key.target,
            ignores: state.ignores,
            relayBots: state.relayBots,
            ownNick: ownNick,
            now: now
        )
        let rows = MessageRows.build(
            messages: visible,
            dividerAfterId: options.dividerAfterId,
            // True when unknown: "no more history" has to be something the server told us.
            hasMoreOlder: buffer?.hasMoreOlder ?? true,
            hasMoreNewer: buffer?.hasMoreNewer == true,
            clearedBeforeId: buffer?.clearedBeforeId ?? 0,
            clearedAt: buffer?.clearedAt,
            showsClearedHistory: options.showsClearedHistory,
            // The typing line lives in the composer's status row (lurker-ios#61), never in the list.
            typists: [],
            settings: state.settings,
            speakers: speakers,
            ownNick: ownNick,
            away: awayState,
            now: now
        )
        return ConversationBuild(
            key: key, kind: kind, options: options, held: held, buffer: buffer,
            ignores: state.ignores, settings: state.settings, speakers: speakers, ownNick: ownNick,
            awayState: awayState, rosterSettled: state.rosterSettled, visible: visible, rows: rows,
            seq: seq
        )
    }
}

/// A history fetch in flight — `around` for a jump, `latest` for a re-attach — and whether its
/// reply has landed, judged frame by frame.
///
/// The store counts every `history` reply it splices in (`Buffer.historyRevision`), so a reply
/// is the count advancing — exact, where lurker-android's version has to infer one from the
/// held objects and documents the cases it gets wrong. The three older tells are kept beside
/// it: an unhydrated buffer hydrating (an empty reply into a shell), a detached buffer
/// re-attaching, and the anchor itself appearing (a live line can carry it, and the landing
/// may as well go straight there).
///
/// Fed every frame, strictly in order (`ConversationScroll.onFrame`); `arrivedAtSeq` is the
/// frame the reply landed in, so a build of an earlier frame isn't mistaken for rows that show
/// it (`landedIn`).
public final class ReplyWatch {
    /// The burst the request went out in — a new burst voids it.
    public let generation: Int
    private var revision: Int
    private var hydrated: Bool
    private var detached: Bool
    private let anchorId: Int?

    /// The frame the reply landed in, or nil while it hasn't.
    public private(set) var arrivedAtSeq: Int?

    init(generation: Int, revision: Int, hydrated: Bool, detached: Bool, anchorId: Int?) {
        self.generation = generation
        self.revision = revision
        self.hydrated = hydrated
        self.detached = detached
        self.anchorId = anchorId
    }

    /// A watch starting from the frame the request went out after.
    static func from(_ state: ChatState, key: BufferKey, anchorId: Int? = nil) -> ReplyWatch {
        let row = state.buffers[key.id]
        return ReplyWatch(
            generation: state.burstGeneration,
            revision: row?.historyRevision ?? 0,
            hydrated: row?.hydrated == true,
            detached: row?.hasMoreNewer == true,
            anchorId: anchorId
        )
    }

    /// One frame's list and row, in order. True when this frame is the reply landing — the
    /// caller hands that change to no other watch (`rebase` them instead): one reply answers
    /// one request.
    func observe(_ list: [Message]?, row: Buffer?, seq: Int) -> Bool {
        if arrivedAtSeq != nil { return false }
        let nowRevision = row?.historyRevision ?? 0
        let nowHydrated = row?.hydrated == true
        let nowDetached = row?.hasMoreNewer == true
        let landed = nowRevision > revision
            || (!hydrated && nowHydrated)
            || (detached && !nowDetached)
            || (anchorId.map { id in (list ?? []).contains { $0.id == id } } ?? false)
        rebase(list, row: row)
        if landed { arrivedAtSeq = seq }
        return landed
    }

    /// Take this frame as the new starting point without judging it — an older request's reply
    /// landed in it, and the server answers in order, so it isn't this one's.
    func rebase(_ list: [Message]?, row: Buffer?) {
        revision = row?.historyRevision ?? 0
        hydrated = row?.hydrated == true
        detached = row?.hasMoreNewer == true
    }

    /// Whether the reply has landed and `current` is a build of a frame at or after it.
    public func landedIn(_ current: ConversationBuild) -> Bool {
        arrivedAtSeq.map { current.seq >= $0 } == true
    }
}

/// What the layout says about where the reader is, in plain facts the screen measures from the
/// table's LAYOUT MODEL (`rectForRow`, `contentOffset`, `contentSize`) — never from realized
/// cells inside a scroll callback, which describe the previous offset.
public struct LayoutFacts: Equatable, Sendable {
    /// Within ~80pt of the newest row — "following the conversation".
    public var nearBottom: Bool
    /// Within ~300pt of the oldest loaded row: time to page older.
    public var pagesOlder: Bool
    /// Within ~300pt of the newest loaded row: time to page newer, if detached.
    public var pagesNewer: Bool
    /// The unread divider is on screen.
    public var dividerVisible: Bool
    /// The divider is wholly ABOVE the viewport. Off screen isn't enough: the divider is
    /// latched for the visit, so scrolling up past it into older history leaves it off screen
    /// *below*, and a banner promising unread above would then take you down.
    public var dividerAbove: Bool

    public init(
        nearBottom: Bool = true, pagesOlder: Bool = false, pagesNewer: Bool = false,
        dividerVisible: Bool = false, dividerAbove: Bool = false
    ) {
        self.nearBottom = nearBottom
        self.pagesOlder = pagesOlder
        self.pagesNewer = pagesNewer
        self.dividerVisible = dividerVisible
        self.dividerAbove = dividerAbove
    }
}

/// Where the conversation's list is, and where it's going: everything `ChatViewController` used
/// to decide from a dozen one-shot latches (`dividerAfterId`, `dividerSeen`, `needsInitialScroll`,
/// `pendingJumpId`, `aroundRequestedAtGeneration`, `aroundSliceArrived`, `wasDetached`,
/// `newWhileDetached`, …), as one pure machine. The screen feeds it frames, builds and measured
/// layouts and performs the scrolls it asks for; this decides.
///
/// lurker-android's `ConversationScroll`, ported back with its tests. Every rule here is a bug
/// that shipped on iOS and was traced on a device; the comments say which. What stays in the
/// controller is UIKit's mechanics: measuring the layout into `LayoutFacts`, performing a
/// landing (`UITableView` lands at the tail over several passes, so `.atTail` here stays
/// pending until the screen reports `landedAtTail()`), converging on a row, and holding the
/// reader's line across a reload.
public final class ConversationScroll {
    private let kind: BufferKind

    /// What the next build must use. Changes are announced by the steps that make them.
    public private(set) var options = RowOptions()

    /// Latched once the divider has been on screen in the buffer's real history: the reader has
    /// seen where they left off, so the banner is spent for the visit. Needed because the
    /// divider never clears — read forward past it and it's above you again, which would
    /// otherwise put the banner back up over messages you've read.
    public private(set) var dividerSeen = false

    /// The jump-to-latest pill's badge: live messages that landed below while the reader was up
    /// in history. Zeroed the moment they're back at the bottom, however they got there.
    public private(set) var newWhileAway = 0

    /// Lines of the decisions as they're made, for the diagnostics trace (lurker-ios#137).
    /// Nil costs nothing: every line is built behind the check.
    public var trace: ((String) -> Void)?

    private var lastClearedBeforeId = 0

    /// A jump on its way: what it's anchored on and how far its fetch has got. One object,
    /// replaced whole, so a new field can never be left stranded set from a previous jump —
    /// `resetJumpState` existed because one was. Its identity is the token the screen's
    /// convergence carries, so a superseded chain can tell.
    public final class Jump {
        /// What the FETCH centres on — and, except for the unread jump, what it lands on.
        let anchorId: Int
        /// Land on (and flash) the first unread row instead of the anchor (lurker-ios#45). The
        /// unread jump anchors its fetch on the read boundary, which sits ABOVE the divider and
        /// can be a frame this buffer never renders (`lastReadId` is a max over every stored id)
        /// — so the scroll target is decoupled from the anchor: the first rendered row past the
        /// divider, which always resolves.
        let flashesFirstUnread: Bool
        /// The `around` fetch, once it's gone out — nil while it hasn't (or a drop or a new burst
        /// voided it), and for a jump that needs none.
        var fetch: ReplyWatch?
        /// Its scrolls are running — a second landing mustn't start a competing chain.
        var converging = false

        init(anchorId: Int, flashesFirstUnread: Bool) {
            self.anchorId = anchorId
            self.flashesFirstUnread = flashesFirstUnread
        }
    }

    private var jump: Jump?

    /// A re-attach is waiting for its latest slice, to land at the new tail — jump-to-latest
    /// from a detached slice.
    private var landsAtTail = false

    /// The re-attach's `latest` fetch, once it's gone out — re-armed by a drop or a new burst as
    /// the `around` fetch is: a request written to a socket that was silently replaced is lost,
    /// and without the re-arm the pending landing would hold off paging and the follow for good.
    private var tailFetch: ReplyWatch?

    /// A landing at the tail the TABLE still has to perform — the opening landing, a re-attach
    /// whose slice has arrived, a jump that gave up. True from birth: a `UITableView` opens at
    /// the top and parks the tail only once it has rows and a real viewport, over a pass or
    /// two, so unlike lurker-android's reverse list this is a state the screen reports the end
    /// of (`landedAtTail`). While it holds, nothing follows, nothing pages and the screen's own
    /// reloads don't scroll — the landing places.
    private var tailPending = true

    /// Fetches still in the air whose requester is gone — a jump superseded by another, or
    /// cancelled by jump-to-latest, before its reply landed. The reply lands anyway, so it's
    /// kept here to be recognised as ITS reply rather than taken for the next request's:
    /// replies are matched to requests in order (`onFrame`), and a new jump doesn't send its
    /// own fetch until these have landed (`requestAround`). Voided by a drop or a new burst.
    private var strays: [ReplyWatch] = []

    /// Whether the buffer was detached as of the previous build.
    private var wasDetached = false

    /// What the previous build drew, for telling a real append from everything else.
    private var previousVisible: [Message]?

    /// The rule set the previous build was filtered by — identity is the whole comparison.
    private var lastIgnores: IgnoreSet?

    public init(kind: BufferKind) {
        self.kind = kind
    }

    private func log(_ line: @autoclosure () -> String) {
        if let trace { trace(line()) }
    }

    /// Keep `watch`'s reply accounted for if it hasn't landed.
    private func retire(_ watch: ReplyWatch?) {
        if let watch, watch.arrivedAtSeq == nil { strays.append(watch) }
    }

    /// A jump hasn't settled yet.
    public var jumpPending: Bool { jump != nil }

    /// Something asked for a landing that hasn't happened — a jump, a re-attach, or the table's
    /// own landing at the tail.
    public var landingPending: Bool { jump != nil || landsAtTail || tailPending }

    /// ⚠⚠ Whether the screen may mark the buffer read. Only once the boundary is latched: marking
    /// pushes the server's pointer to the newest message, and that pointer is the ONLY record of
    /// where the reader left off — mark first and the value latched afterwards is our own mark,
    /// which drops the divider below everything unread and silently reports the lot as read.
    /// Reachable on a cold launch straight into a buffer (lurker-ios#49): live traffic lands
    /// before the backlog that says where the boundary is. Self-clearing — the frame that
    /// carries the pointer latches it, and the mark goes out on that same pass (`onFrame`
    /// latches before the screen marks).
    public var marksRead: Bool { options.dividerAfterId != nil }

    // MARK: - Jump requests

    /// Land on `messageId`: straight there when it's loaded, through an `around` slice centred
    /// on it when it isn't (lurker-ios#42). Supersedes any jump or re-attach already pending.
    public func jumpTo(_ messageId: Int) {
        begin(anchorId: messageId, flashesFirstUnread: false)
    }

    /// The unread banner's tap (lurker-ios#45) — always through the jump machinery, never a raw
    /// scroll. On a large unread every loaded row is newer than the boundary, so the divider is
    /// pinned to the top of what's loaded (the web's #216) and the seam isn't loaded at all;
    /// the FETCH centres on the boundary to bring it in, and the landing goes to the first
    /// unread row. False when there's no boundary to go to.
    @discardableResult
    public func jumpToFirstUnread() -> Bool {
        guard let boundary = options.dividerAfterId, boundary > 0 else { return false }
        begin(anchorId: boundary, flashesFirstUnread: true)
        return true
    }

    private func begin(anchorId: Int, flashesFirstUnread: Bool) {
        retire(jump?.fetch)
        retire(tailFetch)
        landsAtTail = false
        tailFetch = nil
        // A jump supersedes the table's own landing: the jump places.
        tailPending = false
        jump = Jump(anchorId: anchorId, flashesFirstUnread: flashesFirstUnread)
        options.keeping = anchorId
        log("jump begin anchor=\(anchorId) unread=\(flashesFirstUnread)")
    }

    /// What jump-to-latest does.
    public enum ToLatest: Equatable {
        /// Nothing to go to.
        case nothing
        /// Detached: there's no tail on screen to ride to — fetch the latest slice and land there.
        case reattach
        /// Ride down to the newest row, animated — a distance covered, not a teleport.
        case scrollDown
    }

    /// The pill's tap. Detached, re-attach by fetching the latest slice (`requestLatest`) and
    /// land at its bottom once it arrives (`landing`); otherwise ride down.
    ///
    /// Either way, any pending jump is CANCELLED — the reader has said where they want to be,
    /// and a jump left pending would land them back in old history the moment its slice
    /// arrived. And when that jump's `around` fetch is still in the air, riding down isn't
    /// enough: the reply replaces the slice under the reader whether anyone is waiting for it
    /// or not, so it re-attaches instead, with a `latest` that lands after it.
    ///
    /// Returning to the tail also puts a `/clear` back (lurker-ios#121): the reveal was on loan
    /// to land one jump, and this is the reader saying they're done looking past it.
    public func jumpToLatest(hasRows: Bool, detached: Bool) -> ToLatest {
        guard hasRows else { return .nothing }
        newWhileAway = 0
        let fetching = jump?.fetch.map { $0.arrivedAtSeq == nil } == true
        retire(jump?.fetch)
        jump = nil
        if options.showsClearedHistory { options.showsClearedHistory = false }
        if detached || fetching {
            landsAtTail = true
            tailPending = false
            retire(tailFetch)
            tailFetch = nil
            log("jump to latest: reattach")
            return .reattach
        }
        log("jump to latest: scroll down")
        return .scrollDown
    }

    // MARK: - Frames

    /// What a frame asks of the screen.
    public struct FrameStep: Equatable {
        /// Fetch an `around` slice centred on this message (`ChatViewModel.loadAround`).
        public var loadAround: Int?
        /// Fetch the latest slice, to re-attach (`ChatViewModel.loadLatest`).
        public var loadLatest: Bool
        /// `options` changed — the rows must be rebuilt.
        public var optionsChanged: Bool
    }

    /// Every frame, in the old `apply` order: the watch for an in-flight reply, the `around`
    /// request (re-armed across reconnects), then the read-boundary latch — before the screen
    /// marks read on the same frame — and the re-attach's request.
    ///
    /// Every frame the screen receives, in order: replies are recognised by how this buffer's
    /// row changed from one frame to the next (`ReplyWatch`), which only works on a stream that
    /// skips nothing.
    ///
    /// ⚠⚠ The latch waits for `Buffer.readStateKnown`, never a row merely existing or
    /// `hydrated`. Three paths materialize a row carrying nothing but defaults (the connect
    /// `snapshot`, a live event for an unseen target, a `history` reply), and under all of them
    /// `lastReadId` is 0 — indistinguishable from "read nothing". Latching there pinned the
    /// divider at 0 for the visit: no divider and no banner however many unreads (every launch
    /// that restored into a buffer, lurker-ios#49). `hydrated` was the first fix and was inert:
    /// `history mode:latest` sets it without carrying a pointer. Only `backlog` and `read-state`
    /// set `readStateKnown`.
    public func onFrame(_ state: ChatState, key: BufferKey, seq: Int) -> FrameStep {
        let list = state.messages[key.id]
        let row = state.buffers[key.id]
        // A drop or a new burst voids what was asked over the old socket — no reply is coming.
        if state.connection != .connected {
            strays.removeAll()
        } else {
            strays.removeAll { $0.generation != state.burstGeneration }
        }
        // Replies are handed out in the order the requests went: the oldest outstanding watch
        // gets this frame's change, and the rest take it as their new starting point.
        var answered = false
        for watch in strays + [jump?.fetch, tailFetch].compactMap({ $0 }) {
            if answered {
                watch.rebase(list, row: row)
            } else {
                answered = watch.observe(list, row: row, seq: seq)
                if answered { log("reply landed seq=\(seq) revision=\(row?.historyRevision ?? 0)") }
            }
        }
        strays.removeAll { $0.arrivedAtSeq != nil }
        // After the replies are accounted for, so a request made now watches from this frame on.
        let around = requestAround(state, key: key)
        var changed = false
        if options.dividerAfterId == nil, let row, row.readStateKnown {
            options.dividerAfterId = row.lastReadId
            changed = true
            log("divider latched after=\(row.lastReadId) seq=\(seq)")
        }
        let latest = requestLatest(state, key: key)
        return FrameStep(loadAround: around, loadLatest: latest, optionsChanged: changed)
    }

    /// The `around` fetch a pending jump needs, or nil: skipped when the anchor is already held
    /// (the landing goes straight to it), re-armed when the socket drops or a new burst voids
    /// the request — a burst, not a flag, because a request written to a socket that's
    /// silently replaced is lost with the connection never leaving `.connected`. Only channels
    /// and DMs hydrate on demand; a server log's or the system buffer's jump has nothing to
    /// fetch and lands against what's loaded.
    ///
    /// Not asked of a buffer the server has already said is empty (hydrated, nothing held):
    /// there is nothing for the slice to find, and an empty reply into an empty buffer changes
    /// nothing anyone could see it by — `landing` lets go instead.
    ///
    /// `state` must be the last frame the screen processed — never a newer read of the store —
    /// so the reply watch starts from exactly the row the next frame will be compared with.
    @discardableResult
    public func requestAround(_ state: ChatState, key: BufferKey) -> Int? {
        guard let pending = jump, kind.hydratesOnDemand else { return nil }
        guard state.connection == .connected else {
            pending.fetch = nil
            return nil
        }
        if let fetch = pending.fetch, fetch.generation != state.burstGeneration { pending.fetch = nil }
        if pending.fetch != nil { return nil }
        // A superseded fetch is still in the air: wait for its reply before sending ours, or its
        // reply would be taken for ours.
        if !strays.isEmpty { return nil }
        let held = state.messages[key.id] ?? []
        // A row the `/clear` marker hides is held but not drawn — `onRows`' reveal resolves that.
        if held.contains(where: { $0.id == pending.anchorId }) { return nil }
        let row = state.buffers[key.id]
        if held.isEmpty, row?.hydrated == true { return nil }
        pending.fetch = ReplyWatch.from(state, key: key, anchorId: pending.anchorId)
        log("around requested anchor=\(pending.anchorId) generation=\(state.burstGeneration)")
        return pending.anchorId
    }

    /// Whether to send the re-attach's `latest` fetch now: once when it's asked for, and again
    /// when a drop or a new burst voids it (as `requestAround`). `state` is the last processed
    /// frame, as there.
    @discardableResult
    public func requestLatest(_ state: ChatState, key: BufferKey) -> Bool {
        guard landsAtTail else { return false }
        guard state.connection == .connected else {
            tailFetch = nil
            return false
        }
        if let fetch = tailFetch, fetch.generation != state.burstGeneration { tailFetch = nil }
        if tailFetch != nil { return false }
        tailFetch = ReplyWatch.from(state, key: key)
        log("latest requested generation=\(state.burstGeneration)")
        return true
    }

    // MARK: - Builds

    /// What a new build asks of the screen before it's drawn.
    public struct RowsStep: Equatable {
        /// Keep the newest row in view as these rows land.
        public var follow: Bool
        /// `options` changed — another build is needed (and this one is stale).
        public var optionsChanged: Bool
    }

    /// A new build, before it's drawn. `wasNearBottom` is read from the layout of the PREVIOUS
    /// rows — where the reader was when these arrived.
    ///
    /// In order:
    ///
    /// 1. **The `/clear` reveal** (lurker-ios#121). A new clear retires it — or `/clear` looks
    ///    broken until the buffer is reopened. And a pending jump onto a row the marker hides
    ///    arms it: the row sits in the store but is filtered out of the rows, so the landing
    ///    would wait for a row that never exists. Run on every build while a jump is pending,
    ///    because the anchor becomes held-and-hidden at two moments — already loaded at the
    ///    tap, or arriving in the fetched slice (the common path). NOT gated on the buffer
    ///    being attached: the reveal must survive the re-attach that reading forward ends in.
    /// 2. **The badge** — live appends only, while up in history.
    /// 3. **Follow the tail** — ⚠⚠ only `wasNearBottom && !wasDetached && !nowDetached`. At the
    ///    bottom of a DETACHED slice what lands is a newer page the reader pulled by scrolling
    ///    into it; following it down re-triggers the near-bottom `loadNewer`, which pages
    ///    again, and walks the buffer to its end with the reader pinned to the bottom, never
    ///    seeing a line of it. `wasDetached` covers the re-attach build (the last `after` page
    ///    appends and clears the flag at once). And nothing follows while a landing is pending
    ///    — the landing places.
    public func onRows(_ built: ConversationBuild, wasNearBottom: Bool) -> RowsStep {
        let changed = revealIfJumpTargetHidden(built)

        let nowDetached = built.detached
        // Sat out on the build the rules changed: an `/unignore` restores rows throughout the
        // loaded window, a count increase nothing arrived to cause — "12 new" for a
        // conversation that hadn't moved. Nil before the first build, which is right.
        let rulesChanged = lastIgnores !== built.ignores
        lastIgnores = built.ignores
        // Appends only — the first id moving means older pages were pulled — and not while
        // detached (or just re-attached): a detached buffer holds live traffic out, so anything
        // appended there is a page the reader asked for, not a surprise from below.
        if let previous = previousVisible, !wasNearBottom, !wasDetached, !nowDetached, !rulesChanged,
           built.visible.first?.id == previous.first?.id {
            // By id, not by how much longer the list got: a restored row lands in the middle.
            // And not ephemerals (id 0) — a local echo isn't something the reader is missing.
            let tail = previous.last(where: { $0.id != 0 })?.id ?? 0
            let appended = built.visible.filter { $0.id > tail }
            // What the reader will actually SEE arrive — the tier the list applies, so the two
            // can't disagree. At `none` a netsplit rejoin appends dozens of rows that build to
            // nothing.
            newWhileAway += EventFilter.visible(
                appended, settings: built.settings, speakers: built.speakers, ownNick: built.ownNick
            ).count
        }
        previousVisible = built.visible

        let follow = !landingPending && wasNearBottom && !wasDetached && !nowDetached
        log("rows seq=\(built.seq) rows=\(built.rows.count) nearBottom=\(wasNearBottom) detached=\(wasDetached)->\(nowDetached) landing=\(landingPending) follow=\(follow) badge=\(newWhileAway)")
        wasDetached = nowDetached
        return RowsStep(follow: follow, optionsChanged: changed)
    }

    private func revealIfJumpTargetHidden(_ built: ConversationBuild) -> Bool {
        let cleared = built.buffer?.clearedBeforeId ?? 0
        var changed = false
        if cleared > 0, cleared != lastClearedBeforeId, options.showsClearedHistory {
            options.showsClearedHistory = false
            changed = true
        }
        lastClearedBeforeId = cleared
        if let pending = jump, !pending.flashesFirstUnread, built.buffer != nil,
           !options.showsClearedHistory, cleared > 0, pending.anchorId <= cleared,
           (built.held ?? []).contains(where: { $0.id == pending.anchorId }) {
            options.showsClearedHistory = true
            changed = true
        }
        return changed
    }

    // MARK: - Landing

    /// What the screen should do about a pending landing, now.
    public enum Landing {
        /// Nothing is pending.
        case idle
        /// Something is pending and can't be placed yet.
        case wait
        /// Park the newest row at the bottom — the opening, a re-attach's new tail, or a jump
        /// that gave up. Stays pending until the screen reports `landedAtTail()`.
        case atTail
        /// Start converging on the jump's target — `jumpTargetRow`, re-resolved every pass —
        /// and call `finishJump` when done. The token identifies the jump, so a superseded
        /// chain stops.
        case converge(Jump)
    }

    /// The landing against `current` — the build on screen.
    ///
    /// A jump waits while its build is stale (its options aren't the current ones — a reveal or
    /// the jump's own exemption hasn't been built yet), while its target isn't there yet, and
    /// while its fetch is in flight. It gives up — landing at the bottom, or letting go on an
    /// empty buffer — only once nothing more is coming: the `around` reply came back without
    /// the target (`anchorMissing`), or the anchor is held but doesn't render here and there's
    /// nothing to fetch, or this kind can't fetch at all and its history has landed. A jump that
    /// waited on a reply that had already arrived without its target would hold the screen
    /// "landing" forever, and a pending jump gates the hydrate, the follow and the banner.
    ///
    /// A tail landing waits for rows: a table with nothing in it has nothing to park.
    public func landing(_ current: ConversationBuild) -> Landing {
        if let pending = jump {
            if pending.converging { return .wait }
            if current.options != options { return .wait }
            if jumpTargetRow(current) == nil {
                guard abandons(pending, current) else { return .wait }
                jump = nil
                log("jump abandoned anchor=\(pending.anchorId)")
                guard !current.rows.isEmpty else { return .idle }
                tailPending = true
                return .atTail
            }
            pending.converging = true
            log("jump converging anchor=\(pending.anchorId)")
            return .converge(pending)
        }
        if landsAtTail {
            // Not until the latest slice has landed AND these rows are of it: a stray `around`
            // reply landing first leaves the buffer detached, and the `latest` behind it is
            // still to come.
            guard let fetch = tailFetch, fetch.landedIn(current), !current.detached else { return .wait }
            landsAtTail = false
            tailFetch = nil
            tailPending = true
            log("reattach slice landed seq=\(current.seq)")
        }
        if tailPending {
            return current.rows.isEmpty ? .wait : .atTail
        }
        return .idle
    }

    /// The screen parked the newest row at the bottom and a fresh pass found it still there —
    /// or gave up trying. The tail landing is spent.
    public func landedAtTail() {
        if tailPending { log("landed at tail") }
        tailPending = false
    }

    private func abandons(_ pending: Jump, _ current: ConversationBuild) -> Bool {
        // The reply landed — in these rows — without the target: `anchorMissing`, or a message
        // pruned since it was quoted.
        if let fetch = pending.fetch { return fetch.landedIn(current) }
        // Nothing was fetched. Held but not drawn here, with nothing to fetch; a kind that can't
        // fetch, whose history has landed; or a buffer the server says is empty.
        let held = current.held ?? []
        if held.contains(where: { $0.id == pending.anchorId }) { return true }
        if !kind.hydratesOnDemand { return current.historyLanded }
        return held.isEmpty && current.buffer?.hydrated == true
    }

    /// The row a converging jump scrolls to and flashes: the first unread for the unread jump,
    /// else the anchor's own row. Nil until it both exists and can be trusted — for the unread
    /// jump, not while its fetch is in flight, when the divider is top-pinned to the stale
    /// window.
    public func jumpTargetRow(_ current: ConversationBuild) -> Int? {
        guard let pending = jump else { return nil }
        if pending.flashesFirstUnread {
            if let fetch = pending.fetch { return fetch.landedIn(current) ? current.firstUnreadRow : nil }
            // No fetch: trustworthy only when none is needed — the seam (the boundary) is
            // already held, or this kind can't fetch. Otherwise the fetch hasn't gone out
            // (offline, or a superseded one is still in the air) or a drop voided it, and the
            // divider is still pinned to the top of the stale window; the reconnect asks again.
            let held = (current.held ?? []).contains { $0.id == pending.anchorId }
            return (held || !kind.hydratesOnDemand) ? current.firstUnreadRow : nil
        }
        return current.rowIndex(containing: pending.anchorId)
    }

    /// Whether `token` is still the pending jump — false once it's finished or superseded.
    public func isCurrent(_ token: Jump) -> Bool { jump === token }

    /// How a jump ends.
    public enum Finish: Equatable {
        /// Flash this row — the one it landed on.
        case flash(row: Int)
        /// The target vanished: land at the bottom (a tail landing is now pending).
        case atTail
        /// Stopped by the reader's own scroll, or superseded: leave them where they are.
        case release
    }

    /// Release the jump `token` and say how it ends, re-resolving its target against `current`
    /// one last time before the state is cleared. `interrupted`: the reader took hold of the
    /// list mid-convergence — their scroll wins, and the jump lets go without pulling them
    /// anywhere or flashing anything.
    public func finishJump(_ token: Jump, current: ConversationBuild, interrupted: Bool) -> Finish {
        guard jump === token else { return .release }
        let target = interrupted ? nil : jumpTargetRow(current)
        jump = nil
        if interrupted || (target == nil && current.rows.isEmpty) {
            log("jump released interrupted=\(interrupted)")
            return .release
        }
        if let target {
            log("jump landed row=\(target)")
            return .flash(row: target)
        }
        tailPending = true
        log("jump target gone, landing at tail")
        return .atTail
    }

    /// The reader started dragging. The table's own opening landing is spent — a buffer whose
    /// rows arrive late can still be waiting for one when a finger arrives first, and the next
    /// pass (a keyboard, a rotation) would otherwise answer a deliberate scroll by pulling the
    /// reader back to the bottom. Returns whether a converging jump should be finished
    /// interrupted (the screen stops its passes and calls `finishJump`).
    ///
    /// ⚠⚠ Only the opening landing, never one that was ASKED for. A jump still waiting on its
    /// fetch, and a re-attach waiting on its latest slice, are the reader's own request, and a
    /// drag while the slice is in flight must not quietly drop them: `landing` is the only way
    /// a pending jump clears, and it gates the hydrate, the follow and the banner for the rest
    /// of the screen's life.
    public func onUserDrag() -> Bool {
        if jump == nil, !landsAtTail, tailPending {
            tailPending = false
            log("drag released the opening landing")
        }
        return jump?.converging == true
    }

    // MARK: - Layout

    /// The floating controls.
    public struct Pills: Equatable {
        /// The jump-to-latest pill.
        public var showsLatest = false
        /// Its badge.
        public var newCount = 0
        /// The unread banner.
        public var showsUnread = false
        public init(showsLatest: Bool = false, newCount: Int = 0, showsUnread: Bool = false) {
            self.showsLatest = showsLatest
            self.newCount = newCount
            self.showsUnread = showsUnread
        }
    }

    /// What a measured layout asks of the screen.
    public struct LayoutStep: Equatable {
        public var pills: Pills
        public var loadOlder: Bool
        public var loadNewer: Bool
    }

    /// A measured layout of `current` — the old `scrollViewDidScroll` and `updateFloatingPills`,
    /// which ran on every apply and scroll tick.
    ///
    /// - Back at the bottom, however you got there, means caught up: the badge clears.
    /// - **`dividerSeen`** latches when the divider is on screen — ⚠ not while a jump is pending
    ///   (a divider swept past on the way to a search hit wasn't seen by anyone; the pass after
    ///   the jump releases latches it if it really landed on screen), and ⚠⚠ not before the
    ///   buffer's HISTORY HAS LANDED. Opening a buffer before its backlog shows the few live
    ///   events that outran it, all newer than the boundary, so the divider pins to the top of a
    ///   four-row stub that fits on screen: visible by arithmetic, seen by nobody, and the latch
    ///   spent before the real backlog parks the reader thousands of points below their first
    ///   unread with no banner (lurker-ios#105).
    /// - **The jump-to-latest pill**: up in history, or anywhere on a detached slice — even its
    ///   bottom, where `nearBottom` is true; there's no live tail on screen.
    /// - **The unread banner**: a first unread exists, it hasn't been seen, it's ABOVE the
    ///   viewport, no jump is pending (the tap hides it, and the convergence's scrolls would
    ///   otherwise flap it back on), and the connection banner doesn't want the slot. Gated on
    ///   the LATCHED divider, never the live unread count, which marking read zeroes on frame 1.
    /// - **Paging**: near the top, older; near the bottom of a detached slice, newer — the kit
    ///   guards both against re-entry and against there being nothing more. Not while a landing
    ///   is pending (a page could splice onto the slice a jump is replacing), not before the
    ///   history has landed (an unhydrated stub belongs to the hydrate), and ⚠ never while
    ///   `online` is false: the kit marks a page in flight before the client drops the request,
    ///   and nothing clears that on reconnect — paging would stay blocked.
    public func onLayout(
        _ facts: LayoutFacts, current: ConversationBuild, detached: Bool,
        connectionBannerShown: Bool, online: Bool
    ) -> LayoutStep {
        if facts.nearBottom { newWhileAway = 0 }
        if !jumpPending, current.historyLanded, facts.dividerVisible, !dividerSeen {
            dividerSeen = true
            log("dividerSeen latched seq=\(current.seq)")
        }
        let hasRows = !current.rows.isEmpty
        let pills = Pills(
            showsLatest: (detached || !facts.nearBottom) && hasRows,
            newCount: newWhileAway,
            showsUnread: current.firstUnreadRow != nil && !dividerSeen && facts.dividerAbove
                && !jumpPending && !connectionBannerShown
        )
        let pages = online && !landingPending && current.historyLanded && !(current.held ?? []).isEmpty
        return LayoutStep(
            pills: pills,
            loadOlder: pages && facts.pagesOlder,
            loadNewer: pages && detached && facts.pagesNewer
        )
    }

    /// Whether to pull older history because the filters thinned what's loaded down to too
    /// little to scroll while more exists — the pure half of the old `topUpIfUnscrollable`.
    /// The screen measures whether the table can scroll; this says whether a page is worth
    /// asking for: hydrated (with nothing loaded this is an unhydrated buffer, which the hydrate
    /// owns), more older, something held, no jump in flight, and `online` for the paging reason
    /// in `onLayout`. An ignored sender who dominates a channel gets here, and so do the `none`
    /// and `smart` tiers.
    public func wantsTopUp(_ current: ConversationBuild, online: Bool) -> Bool {
        guard online, !jumpPending, let buffer = current.buffer else { return false }
        return buffer.hydrated && buffer.hasMoreOlder && !(current.held ?? []).isEmpty
    }

    /// Whether a request sent now can reach the server: the socket is up AND the device has a
    /// path. ⚠ Asked BEFORE anything the kit bookkeeps per request — `loadOlder`/`loadNewer`
    /// set their in-flight flags before the client drops a write onto a dead socket, and
    /// nothing resets them on reconnect.
    public static func mayWrite(_ state: ChatState) -> Bool { state.socketWritable }
}

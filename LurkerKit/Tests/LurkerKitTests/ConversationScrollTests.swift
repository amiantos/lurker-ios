// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// The conversation's position machine — the landing, jump, divider, banner, paging and
/// mark-read rules that used to live in `ChatViewController`'s latches, one test per rule, each
/// named after it. Ported from lurker-android's `ConversationScrollTest` (75 tests), whose
/// machine is the port of the same rules; every one is a bug iOS shipped and traced on a device.
///
/// Three of Android's tests measure its lazy list's `LayoutFacts.of` and have no counterpart
/// here: the table's geometry is measured by the controller. One (the machine's saved `Memory`)
/// has nothing to survive on iOS, where the screen isn't recreated. Added at the end: what
/// `UITableView` makes different — a tail landing the screen reports the end of — and the
/// kit's reply count, which replaces Android's held-object inference.
@Suite("Conversation scroll")
@MainActor
struct ConversationScrollTests {

    private let channel = BufferKey(networkId: 1, target: "#lurker")
    private let libera = Network(id: 1, name: "Libera", state: .connected, nick: "me")
    private let clearedAt = Date(timeIntervalSince1970: 1_784_552_400)

    private func row(
        _ key: BufferKey? = nil,
        hydrated: Bool = true,
        readStateKnown: Bool = false,
        lastReadId: Int = 0,
        hasMoreOlder: Bool = true,
        hasMoreNewer: Bool = false,
        clearedBeforeId: Int = 0,
        clearedAt: Date? = nil,
        historyRevision: Int = 0
    ) -> Buffer {
        let key = key ?? channel
        return Buffer(
            networkId: key.networkId,
            target: key.target,
            kind: BufferKind.of(networkId: key.networkId, target: key.target),
            lastReadId: lastReadId,
            joined: true,
            hydrated: hydrated,
            readStateKnown: readStateKnown,
            hasMoreOlder: hasMoreOlder,
            hasMoreNewer: hasMoreNewer,
            clearedBeforeId: clearedBeforeId,
            clearedAt: clearedAt,
            historyRevision: historyRevision
        )
    }

    private func msg(_ id: Int, nick: String? = "alice", type: EventType = .message, text: String? = nil) -> Message {
        Message(
            id: id, type: type, nick: nick, text: text ?? "line \(id)",
            date: Date(timeIntervalSince1970: 1_784_556_000 + TimeInterval(id))
        )
    }

    private func msgs(_ range: ClosedRange<Int>) -> [Message] { range.map { msg($0) } }

    private func state(
        _ buffer: Buffer? = nil,
        _ messages: [Message] = [],
        key: BufferKey? = nil,
        connection: SocketStatus = .connected,
        burstGeneration: Int = 1,
        ignores: IgnoreSet = .empty,
        settings: Settings = Settings(),
        reachable: Bool = true,
        noBuffer: Bool = false
    ) -> ChatState {
        let key = key ?? channel
        var s = ChatState()
        s.connection = connection
        s.reachable = reachable
        s.snapshotSinceOpen = true
        s.backlogComplete = true
        s.networks = [1: libera]
        if !noBuffer {
            let b = buffer ?? row(key)
            s.buffers[b.key.id] = b
        }
        s.messages[key.id] = messages
        s.ignores = ignores
        s.settings = settings
        s.burstGeneration = burstGeneration
        return s
    }

    private func kindOf(_ key: BufferKey) -> BufferKind { BufferKind.of(networkId: key.networkId, target: key.target) }

    private func machine(_ key: BufferKey? = nil) -> ConversationScroll { ConversationScroll(kind: kindOf(key ?? channel)) }

    /// A build of `state` under the machine's current options, as the screen's pipeline makes one.
    private func build(_ scroll: ConversationScroll, _ state: ChatState, seq: Int = 0, key: BufferKey? = nil) -> ConversationBuild {
        let key = key ?? channel
        return ConversationBuild.make(state: state, key: key, kind: kindOf(key), options: scroll.options, seq: seq)
    }

    private func facts(
        nearBottom: Bool = true, pagesOlder: Bool = false, pagesNewer: Bool = false,
        dividerVisible: Bool = false, dividerAbove: Bool = false
    ) -> LayoutFacts {
        LayoutFacts(nearBottom: nearBottom, pagesOlder: pagesOlder, pagesNewer: pagesNewer, dividerVisible: dividerVisible, dividerAbove: dividerAbove)
    }

    private func isConverge(_ landing: ConversationScroll.Landing) -> Bool {
        if case .converge = landing { return true }
        return false
    }

    private func isWait(_ landing: ConversationScroll.Landing) -> Bool {
        if case .wait = landing { return true }
        return false
    }

    private func isAtTail(_ landing: ConversationScroll.Landing) -> Bool {
        if case .atTail = landing { return true }
        return false
    }

    private func isIdle(_ landing: ConversationScroll.Landing) -> Bool {
        if case .idle = landing { return true }
        return false
    }

    private func token(_ landing: ConversationScroll.Landing) -> ConversationScroll.Jump? {
        if case .converge(let jump) = landing { return jump }
        return nil
    }

    /// A machine whose opening landing has been performed, so the table's own tail landing isn't
    /// what a test about something else is measuring.
    private func opened(_ key: BufferKey? = nil) -> ConversationScroll {
        let scroll = machine(key)
        scroll.landedAtTail()
        return scroll
    }

    // MARK: - The read boundary and mark-read

    @Test("the divider latches only once the server has stated read state, never on a row or a hydrate")
    func dividerLatchesOnReadStateKnown() {
        let scroll = machine()
        // A snapshot shell, then a `history mode:latest` reply: a row, hydrated, `lastReadId` 0 by
        // default — none of it is the server saying where the reader left off.
        _ = scroll.onFrame(state(row(hydrated: false)), key: channel, seq: 1)
        _ = scroll.onFrame(state(row(hydrated: true)), key: channel, seq: 2)
        #expect(scroll.options.dividerAfterId == nil)
        let step = scroll.onFrame(state(row(readStateKnown: true, lastReadId: 5)), key: channel, seq: 3)
        #expect(step.optionsChanged)
        #expect(scroll.options.dividerAfterId == 5)
    }

    @Test("the divider is held for the visit, however the pointer moves after")
    func dividerHeldForTheVisit() {
        let scroll = machine()
        _ = scroll.onFrame(state(row(readStateKnown: true, lastReadId: 5)), key: channel, seq: 1)
        let step = scroll.onFrame(state(row(readStateKnown: true, lastReadId: 9)), key: channel, seq: 2)
        #expect(!step.optionsChanged)
        #expect(scroll.options.dividerAfterId == 5)
    }

    @Test("mark-read is gated on the latched divider")
    func markReadGated() {
        let scroll = machine()
        _ = scroll.onFrame(state(row(hydrated: true)), key: channel, seq: 1)
        #expect(!scroll.marksRead)
        _ = scroll.onFrame(state(row(readStateKnown: true, lastReadId: 5)), key: channel, seq: 2)
        #expect(scroll.marksRead)
    }

    @Test("the latch is taken on the same frame before the mark, so it never latches our own mark")
    func latchBeforeMark() {
        let scroll = machine()
        _ = scroll.onFrame(state(row(readStateKnown: true, lastReadId: 5), msgs(1...10)), key: channel, seq: 1)
        #expect(scroll.marksRead)
        // Our mark comes back as a `read-state` at 10; the divider doesn't move.
        _ = scroll.onFrame(state(row(readStateKnown: true, lastReadId: 10), msgs(1...10)), key: channel, seq: 2)
        #expect(scroll.options.dividerAfterId == 5)
    }

    // MARK: - The unread banner and dividerSeen

    /// A latched machine over a hydrated buffer whose divider sits after message 5 of 1…10.
    private func withDivider(hydrated: Bool = true, key: BufferKey? = nil) -> (ConversationScroll, ConversationBuild) {
        let key = key ?? channel
        let scroll = opened(key)
        let s = state(row(key, hydrated: hydrated, readStateKnown: true, lastReadId: 5), msgs(1...10), key: key)
        _ = scroll.onFrame(s, key: key, seq: 1)
        let built = build(scroll, s, seq: 1, key: key)
        _ = scroll.onRows(built, wasNearBottom: true)
        return (scroll, built)
    }

    @Test("the unread banner shows when a first unread exists above the viewport and hasn't been seen")
    func bannerShows() {
        let (scroll, built) = withDivider()
        #expect(built.firstUnreadRow != nil)
        let step = scroll.onLayout(facts(dividerAbove: true), current: built, detached: false, connectionBannerShown: false, online: true)
        #expect(step.pills.showsUnread)
    }

    @Test("off screen is not above - a divider below the viewport raises no banner")
    func offScreenIsNotAbove() {
        let (scroll, built) = withDivider()
        let step = scroll.onLayout(facts(nearBottom: false, dividerAbove: false), current: built, detached: false, connectionBannerShown: false, online: true)
        #expect(!step.pills.showsUnread)
    }

    @Test("the unread banner yields its slot to the connection banner")
    func bannerYieldsToConnection() {
        let (scroll, built) = withDivider()
        let step = scroll.onLayout(facts(dividerAbove: true), current: built, detached: false, connectionBannerShown: true, online: true)
        #expect(!step.pills.showsUnread)
    }

    @Test("the unread banner stays down while a jump is pending")
    func bannerDownDuringJump() {
        let (scroll, built) = withDivider()
        #expect(scroll.jumpToFirstUnread())
        let step = scroll.onLayout(facts(dividerAbove: true), current: built, detached: false, connectionBannerShown: false, online: true)
        #expect(!step.pills.showsUnread)
    }

    @Test("seeing the divider retires the banner for good")
    func seeingRetires() {
        let (scroll, built) = withDivider()
        _ = scroll.onLayout(facts(dividerVisible: true), current: built, detached: false, connectionBannerShown: false, online: true)
        #expect(scroll.dividerSeen)
        // Read forward past it: it's above again, and the banner stays retired.
        let step = scroll.onLayout(facts(dividerAbove: true), current: built, detached: false, connectionBannerShown: false, online: true)
        #expect(!step.pills.showsUnread)
    }

    @Test("dividerSeen does not latch against the pre-backlog stub")
    func noLatchOnStub() {
        // Unhydrated: the live events that outran the backlog, all past the boundary, the divider
        // top-pinned to a stub that fits on screen — visible by arithmetic, seen by nobody.
        let (scroll, built) = withDivider(hydrated: false)
        _ = scroll.onLayout(facts(dividerVisible: true), current: built, detached: false, connectionBannerShown: false, online: true)
        #expect(!scroll.dividerSeen)
    }

    @Test("dividerSeen keys off history having landed, not hydrated - a server log latches once its row exists")
    func serverLogLatches() {
        let log = BufferKey(networkId: 1, target: Buffer.serverTarget(1))
        let (scroll, built) = withDivider(hydrated: false, key: log)
        _ = scroll.onLayout(facts(dividerVisible: true), current: built, detached: false, connectionBannerShown: false, online: true)
        #expect(scroll.dividerSeen)
    }

    @Test("dividerSeen does not latch while a jump is pending - a divider swept past wasn't seen")
    func noLatchDuringJump() {
        let (scroll, built) = withDivider()
        scroll.jumpTo(9)
        _ = scroll.onLayout(facts(dividerVisible: true), current: built, detached: false, connectionBannerShown: false, online: true)
        #expect(!scroll.dividerSeen)
    }

    @Test("no divider, no banner")
    func noDividerNoBanner() {
        let scroll = opened()
        let built = build(scroll, state(nil, msgs(1...10)))
        _ = scroll.onRows(built, wasNearBottom: true)
        #expect(built.firstUnreadRow == nil)
        #expect(!scroll.onLayout(facts(dividerAbove: true), current: built, detached: false, connectionBannerShown: false, online: true).pills.showsUnread)
    }

    // MARK: - Following the tail, and the badge

    @Test("the tail is followed from the bottom of an attached buffer")
    func followsFromBottom() {
        let scroll = opened()
        _ = scroll.onRows(build(scroll, state(nil, msgs(1...10))), wasNearBottom: true)
        #expect(scroll.onRows(build(scroll, state(nil, msgs(1...11))), wasNearBottom: true).follow)
        #expect(!scroll.onRows(build(scroll, state(nil, msgs(1...12))), wasNearBottom: false).follow)
    }

    @Test("after-paging must not cascade - a detached slice's newer page is never followed")
    func afterPagingNeverFollowed() {
        let scroll = opened()
        let detached = row(hasMoreNewer: true)
        _ = scroll.onRows(build(scroll, state(detached, msgs(1...10))), wasNearBottom: true)
        // A `loadNewer` page appends below a reader parked at the slice's bottom.
        #expect(!scroll.onRows(build(scroll, state(detached, msgs(1...20))), wasNearBottom: true).follow)
        // The last page appends AND re-attaches in one build — still a page, still not followed.
        #expect(!scroll.onRows(build(scroll, state(row(), msgs(1...30))), wasNearBottom: true).follow)
        // From here on the buffer is attached, and live traffic is followed again.
        #expect(scroll.onRows(build(scroll, state(row(), msgs(1...31))), wasNearBottom: true).follow)
    }

    @Test("nothing follows while a landing is pending - the landing places")
    func nothingFollowsDuringLanding() {
        let scroll = opened()
        _ = scroll.onRows(build(scroll, state(nil, msgs(1...10))), wasNearBottom: true)
        scroll.jumpTo(3)
        #expect(!scroll.onRows(build(scroll, state(nil, msgs(1...11))), wasNearBottom: true).follow)
    }

    @Test("the badge counts live appends while up in history, and nothing else")
    func badgeCountsAppends() {
        let scroll = opened()
        _ = scroll.onRows(build(scroll, state(nil, msgs(5...10))), wasNearBottom: false)
        _ = scroll.onRows(build(scroll, state(nil, msgs(5...12))), wasNearBottom: false)
        #expect(scroll.newWhileAway == 2)
        // An older page moves the first id: pulled history, not arrivals.
        _ = scroll.onRows(build(scroll, state(nil, msgs(1...12))), wasNearBottom: false)
        #expect(scroll.newWhileAway == 2)
        // An ephemeral (id 0) is a local echo, not something missed below.
        _ = scroll.onRows(build(scroll, state(nil, msgs(1...12) + [msg(0, nick: nil, type: .notice, text: "echo")])), wasNearBottom: false)
        #expect(scroll.newWhileAway == 2)
        // Back at the bottom, however they got there: caught up.
        let built = build(scroll, state(nil, msgs(1...12)))
        _ = scroll.onLayout(facts(nearBottom: true), current: built, detached: false, connectionBannerShown: false, online: true)
        #expect(scroll.newWhileAway == 0)
    }

    @Test("the badge sits out a frame where the ignore rules changed")
    func badgeSitsOutRuleChange() {
        let scroll = opened()
        let ignores = IgnoreSet(byNetwork: [1: [IgnoreRule(id: 1, mask: "spammer")]])
        let lines = msgs(1...5) + [msg(6, nick: "spammer"), msg(7, nick: "spammer")]
        _ = scroll.onRows(build(scroll, state(nil, lines, ignores: ignores)), wasNearBottom: false)
        // `/unignore` restores 6 and 7 — a count increase nothing arrived to cause.
        _ = scroll.onRows(build(scroll, state(nil, lines, ignores: .empty)), wasNearBottom: false)
        #expect(scroll.newWhileAway == 0)
    }

    @Test("the badge counts what the event tier will draw")
    func badgeCountsTheTier() {
        let scroll = opened()
        let none = Settings(registry: [:], values: [EventFilter.modeKey: .string("none")])
        _ = scroll.onRows(build(scroll, state(nil, msgs(1...5), settings: none)), wasNearBottom: false)
        let rejoins = (6...9).map { msg($0, nick: "user\($0)", type: .join, text: "") }
        _ = scroll.onRows(build(scroll, state(nil, msgs(1...5) + rejoins, settings: none)), wasNearBottom: false)
        #expect(scroll.newWhileAway == 0)
    }

    @Test("the badge doesn't count a detached buffer's pages")
    func badgeIgnoresPages() {
        let scroll = opened()
        let detached = row(hasMoreNewer: true)
        _ = scroll.onRows(build(scroll, state(detached, msgs(1...5))), wasNearBottom: false)
        _ = scroll.onRows(build(scroll, state(detached, msgs(1...9))), wasNearBottom: false)
        #expect(scroll.newWhileAway == 0)
    }

    @Test("the jump-to-latest pill shows anywhere on a detached slice, even its bottom")
    func pillOnDetachedSlice() {
        let scroll = opened()
        let built = build(scroll, state(row(hasMoreNewer: true), msgs(1...5)))
        _ = scroll.onRows(built, wasNearBottom: true)
        #expect(scroll.onLayout(facts(nearBottom: true), current: built, detached: true, connectionBannerShown: false, online: true).pills.showsLatest)
        #expect(!scroll.onLayout(facts(nearBottom: true), current: built, detached: false, connectionBannerShown: false, online: true).pills.showsLatest)
        #expect(scroll.onLayout(facts(nearBottom: false), current: built, detached: false, connectionBannerShown: false, online: true).pills.showsLatest)
    }

    // MARK: - Jumps

    /// Drives the machine the way the screen does: every frame through `onFrame`, strictly in
    /// order, and builds stamped with the frame they're of. A live append is the held list with
    /// more behind it; a reply is a frame whose row's `historyRevision` has advanced.
    @MainActor
    private final class Drive {
        let scroll: ConversationScroll
        let key: BufferKey
        let tests: ConversationScrollTests
        private(set) var seq = 0
        private(set) var last = ChatState()

        init(_ tests: ConversationScrollTests, scroll: ConversationScroll? = nil, key: BufferKey? = nil) {
            self.tests = tests
            self.key = key ?? tests.channel
            self.scroll = scroll ?? tests.opened(self.key)
        }

        @discardableResult
        func frame(_ s: ChatState) -> ConversationScroll.FrameStep {
            seq += 1
            last = s
            return scroll.onFrame(s, key: key, seq: seq)
        }

        /// A build of the last frame, taken onto the screen.
        func built() -> ConversationBuild {
            let b = tests.build(scroll, last, seq: seq, key: key)
            _ = scroll.onRows(b, wasNearBottom: true)
            return b
        }

        func land() -> ConversationScroll.Landing { scroll.landing(built()) }
    }

    @Test("a jump to a held message lands without a fetch, on the message's row")
    func jumpToHeld() {
        let d = Drive(self)
        d.frame(state(nil, msgs(1...10)))
        d.scroll.jumpTo(4)
        #expect(d.scroll.requestAround(d.last, key: channel) == nil)
        let built = d.built()
        #expect(isConverge(d.scroll.landing(built)))
        #expect(d.scroll.jumpTargetRow(built) == built.rowIndex(containing: 4))
    }

    @Test("a jump to a message outside the slice fetches an around slice and waits for it")
    func jumpOutsideFetches() {
        let d = Drive(self)
        d.frame(state(nil, msgs(100...110)))
        d.scroll.jumpTo(4)
        #expect(d.scroll.requestAround(d.last, key: channel) == 4)
        // Asked: not again for the same burst.
        #expect(d.frame(d.last).loadAround == nil)
        #expect(isWait(d.land()))
    }

    @Test("a pending jump is what keeps the hydrate from asking for the latest slice")
    func pendingJumpGatesHydrate() {
        let scroll = machine()
        scroll.jumpTo(4)
        #expect(scroll.jumpPending)
    }

    @Test("the around request is re-armed by a drop and by a new burst")
    func aroundRearmed() {
        let d = Drive(self)
        let held = msgs(100...110)
        d.scroll.jumpTo(4)
        #expect(d.frame(state(nil, held)).loadAround == 4)
        #expect(d.frame(state(nil, held, connection: .reconnecting)).loadAround == nil)
        #expect(d.frame(state(nil, held)).loadAround == 4)
        // The socket replaced under a steady Connected: the burst is the signal.
        #expect(d.frame(state(nil, held, burstGeneration: 2)).loadAround == 4)
    }

    @Test("the around reply is recognised by the kit's reply count, not by the buffer having messages")
    func aroundReplyByRevision() {
        let d = Drive(self)
        // A small connect backlog is already held when the jump asks.
        let backlog = msgs(100...104)
        d.frame(state(nil, backlog))
        d.scroll.jumpTo(4)
        #expect(d.frame(state(nil, backlog)).loadAround == 4)
        // A live append: not the reply.
        d.frame(state(nil, backlog + [msg(105)]))
        #expect(isWait(d.land()))
        // The reply (anchor missing on the server, say): it has landed, and the jump gives up —
        // at the bottom, since there's something to land on.
        d.frame(state(row(hasMoreNewer: true, historyRevision: 1), msgs(20...30)))
        #expect(isAtTail(d.land()))
        #expect(!d.scroll.jumpPending)
    }

    @Test("an around reply that lacks the anchor but holds every id already held is still recognised")
    func aroundReplySuperset() {
        let d = Drive(self)
        // A small, fully loaded buffer; the quoted line has been pruned since.
        let all = msgs(1...10)
        let small = row(hasMoreOlder: false)
        d.frame(state(small, all))
        d.scroll.jumpTo(99)
        #expect(d.frame(state(small, all)).loadAround == 99)
        // The reply is the whole buffer again — every id already held, nothing replaced.
        d.frame(state(row(hasMoreOlder: false, historyRevision: 1), msgs(1...10)))
        #expect(isAtTail(d.land()))
        #expect(!d.scroll.jumpPending)
    }

    @Test("a build of a frame before the reply is not taken for the reply's rows")
    func staleBuildNotTheReply() {
        let d = Drive(self)
        let backlog = msgs(100...104)
        d.frame(state(nil, backlog))
        d.scroll.jumpTo(4)
        d.frame(state(nil, backlog))
        let stale = build(d.scroll, d.last, seq: d.seq)
        d.frame(state(row(hasMoreNewer: true, historyRevision: 1), msgs(20...30)))
        // The reply has landed, but these rows are of the frame before it.
        #expect(isWait(d.scroll.landing(stale)))
        #expect(isAtTail(d.land()))
    }

    @Test("an anchorMissing reply into an unhydrated buffer is recognised by the reply count, and the hydrate then asks")
    func anchorMissingIntoShell() {
        let d = Drive(self)
        d.frame(state(row(hydrated: false)))
        d.scroll.jumpTo(4)
        #expect(d.frame(state(row(hydrated: false))).loadAround == 4)
        // The store leaves the shell a shell and moves only the count: nothing to land on, so
        // the jump lets go, and with no jump pending the hydrate is free to ask for the latest.
        d.frame(state(row(hydrated: false, historyRevision: 1)))
        #expect(isIdle(d.land()))
        #expect(!d.scroll.jumpPending)
    }

    @Test("a jump after a pruned one still fetches - an anchorMissing reply doesn't empty the buffer")
    func jumpAfterPrunedOneFetches() {
        let d = Drive(self)
        let held = msgs(100...110)
        d.frame(state(nil, held))
        d.scroll.jumpTo(4)
        #expect(d.frame(state(nil, held)).loadAround == 4)
        // Pruned: the reply moves the count and nothing else. The jump gives up at the tail.
        d.frame(state(row(historyRevision: 1), held))
        #expect(isAtTail(d.land()))
        d.scroll.landedAtTail()
        // A valid bookmark next: the buffer still holds its lines, so the fetch goes out.
        d.scroll.jumpTo(60)
        #expect(d.scroll.requestAround(d.last, key: channel) == 60)
    }

    @Test("a jump before the buffer has a row waits for the row, then fetches")
    func jumpBeforeRowWaits() {
        let d = Drive(self)
        // No row yet (a key opened by a notification tap before its burst): an anchor-missing
        // reply into it would leave no trace, so no fetch goes out. The burst is still running,
        // so the roster hasn't settled and the row may yet come.
        var opening = state(noBuffer: true)
        opening.backlogComplete = false
        d.frame(opening)
        d.scroll.jumpTo(4)
        #expect(d.scroll.requestAround(d.last, key: channel) == nil)
        #expect(isWait(d.land()))
        // The row arrives: the fetch goes out on this frame.
        #expect(d.frame(state(row(hydrated: false))).loadAround == 4)
    }

    @Test("a jump into a buffer the roster settled without lets go")
    func jumpIntoRowlessSettledBufferLetsGo() {
        let d = Drive(self)
        // A stray slice holds lines but no row, and the burst has listed everything: nothing is
        // coming for this key, so the jump gives up — at the tail of what's drawn.
        var s = state(nil, msgs(100...110), noBuffer: true)
        s.backlogComplete = true
        d.frame(s)
        d.scroll.jumpTo(4)
        #expect(d.scroll.requestAround(d.last, key: channel) == nil)
        #expect(isAtTail(d.land()))
        #expect(!d.scroll.jumpPending)
    }

    @Test("a re-attach before the buffer has a row waits for the row too")
    func reattachBeforeRowWaits() {
        let d = Drive(self)
        d.frame(state(row(hasMoreNewer: true), msgs(1...10)))
        _ = d.built()
        #expect(d.scroll.jumpToLatest(hasRows: true, detached: true) == .reattach)
        // The row drops out under a reconciliation burst: no fetch until it's back.
        #expect(!d.frame(state(nil, msgs(1...10), noBuffer: true)).loadLatest)
        #expect(d.frame(state(row(hasMoreNewer: true), msgs(1...10))).loadLatest)
    }

    @Test("a jump into a buffer the server says is empty lets go without a fetch")
    func jumpIntoEmptyLetsGo() {
        let d = Drive(self)
        d.frame(state(row(hydrated: true)))
        d.scroll.jumpTo(4)
        #expect(d.scroll.requestAround(d.last, key: channel) == nil)
        #expect(isIdle(d.land()))
        #expect(!d.scroll.jumpPending)
    }

    @Test("the reply with the anchor in it is landed on")
    func replyWithAnchor() {
        let d = Drive(self)
        d.frame(state(nil, msgs(100...110)))
        d.scroll.jumpTo(4)
        d.frame(d.last)
        d.frame(state(row(hasMoreNewer: true, historyRevision: 1), msgs(1...8)))
        let reply = d.built()
        #expect(isConverge(d.scroll.landing(reply)))
        #expect(d.scroll.jumpTargetRow(reply) == reply.rowIndex(containing: 4))
    }

    @Test("a live append and a reply are told apart by the buffer's reply count")
    func appendVsReply() {
        let held = msgs(1...5)
        let watch = ReplyWatch.from(.init(state(row(historyRevision: 3), held), key: channel))
        // The same list with more behind it, the same count: an append.
        #expect(!watch.observe(held + [msg(6)], row: row(historyRevision: 3), seq: 2))
        // The list rebuilt from the same ids, the count advanced: a reply.
        #expect(watch.observe(msgs(1...5), row: row(historyRevision: 4), seq: 3))
        #expect(watch.arrivedAtSeq == 3)
        // Once landed, nothing more is judged.
        #expect(!watch.observe(msgs(1...5), row: row(historyRevision: 5), seq: 4))
    }

    @Test("the jump stays pending until it has settled, so nothing else steals the scroll")
    func jumpStaysPending() {
        let scroll = opened()
        scroll.jumpTo(4)
        let built = build(scroll, state(nil, msgs(1...10)))
        let landing = scroll.landing(built)
        let jump = try! #require(token(landing))
        // An intervening build: no second chain, no follow, still pending.
        #expect(isWait(scroll.landing(built)))
        #expect(!scroll.onRows(build(scroll, state(nil, msgs(1...11))), wasNearBottom: true).follow)
        #expect(scroll.jumpPending)
        let end = scroll.finishJump(jump, current: built, interrupted: false)
        #expect(end == .flash(row: built.rowIndex(containing: 4)!))
        #expect(!scroll.jumpPending)
    }

    @Test("the target is re-resolved by message id on every pass, never a cached index")
    func targetReresolved() {
        let scroll = opened()
        let first = build(scroll, state(nil, msgs(5...10)))
        scroll.jumpTo(7)
        _ = scroll.landing(first)
        let before = scroll.jumpTargetRow(first)!
        // An older page lands between passes: every index shifts, the message doesn't.
        let second = build(scroll, state(nil, msgs(1...10)))
        let after = scroll.jumpTargetRow(second)!
        #expect(second.rows[after].message?.id == 7)
        #expect(after > before)
    }

    @Test("a target folded into a consolidated run resolves to the summary")
    func targetInConsolidatedRun() {
        let scroll = opened()
        let joins = (3...6).map { msg($0, nick: "user\($0)", type: .join, text: "") }
        let built = build(scroll, state(nil, msgs(1...2) + joins + msgs(7...8)))
        scroll.jumpTo(4)
        let row = scroll.jumpTargetRow(built)!
        if case .consolidated = built.rows[row] {} else {
            Issue.record("expected a consolidated row, got \(built.rows[row])")
        }
    }

    @Test("a superseded or finished jump's chain is told so")
    func supersededChain() {
        let scroll = opened()
        scroll.jumpTo(4)
        let built = build(scroll, state(nil, msgs(1...10)))
        let first = try! #require(token(scroll.landing(built)))
        scroll.jumpTo(6)
        #expect(!scroll.isCurrent(first))
        #expect(scroll.finishJump(first, current: built, interrupted: false) == .release)
        #expect(scroll.jumpPending)
    }

    @Test("a jump whose target vanished lands at the bottom")
    func targetVanished() {
        let scroll = opened()
        scroll.jumpTo(4)
        let built = build(scroll, state(nil, msgs(1...10)))
        let jump = try! #require(token(scroll.landing(built)))
        let gone = build(scroll, state(nil, msgs(6...10)))
        #expect(scroll.finishJump(jump, current: gone, interrupted: false) == .atTail)
        // …and that landing is now the table's to perform.
        #expect(scroll.landingPending)
        #expect(isAtTail(scroll.landing(gone)))
    }

    @Test("a jump the reader interrupted stays put and never flashes")
    func interruptedJump() {
        let scroll = opened()
        scroll.jumpTo(4)
        let built = build(scroll, state(nil, msgs(1...10)))
        let jump = try! #require(token(scroll.landing(built)))
        // The target is right there — still no pulse on a row they're dragging away from.
        #expect(scroll.finishJump(jump, current: built, interrupted: true) == .release)
        #expect(!scroll.jumpPending)
        #expect(!scroll.landingPending)
    }

    @Test("a jump waits for a build made under its own options")
    func jumpWaitsForItsOptions() {
        let scroll = opened()
        let stale = build(scroll, state(nil, msgs(1...10)))
        scroll.jumpTo(4)
        // Built before the jump's exemption existed: not trusted, even though 4 is in it.
        #expect(isWait(scroll.landing(stale)))
        #expect(isConverge(scroll.landing(build(scroll, state(nil, msgs(1...10))))))
    }

    @Test("a jump target an ignore rule now covers still renders")
    func ignoredTargetRenders() {
        let scroll = opened()
        let ignores = IgnoreSet(byNetwork: [1: [IgnoreRule(id: 1, mask: "spammer")]])
        let lines = msgs(1...3) + [msg(4, nick: "spammer")] + msgs(5...6)
        scroll.jumpTo(4)
        let built = build(scroll, state(nil, lines, ignores: ignores))
        #expect(built.rowIndex(containing: 4) != nil)
        #expect(isConverge(scroll.landing(built)))
    }

    @Test("a held message that doesn't render here gives up rather than waiting forever")
    func unrenderedTargetGivesUp() {
        let scroll = opened()
        // A system line in a channel: held, never drawn, nothing to fetch.
        let lines = msgs(1...3) + [msg(4, nick: nil, type: .system, text: "sys")] + msgs(5...6)
        let s = state(nil, lines)
        scroll.jumpTo(4)
        #expect(scroll.requestAround(s, key: channel) == nil)
        #expect(isAtTail(scroll.landing(build(scroll, s))))
    }

    @Test("a server log's jump to an unloaded message gives up once its history has landed")
    func serverLogJumpGivesUp() {
        let log = BufferKey(networkId: 1, target: Buffer.serverTarget(1))
        let scroll = opened(log)
        let s = state(row(log, hydrated: false), msgs(10...20), key: log)
        scroll.jumpTo(4)
        // A server log can't fetch an `around` slice.
        #expect(scroll.requestAround(s, key: log) == nil)
        #expect(isAtTail(scroll.landing(build(scroll, s, key: log))))
    }

    // MARK: - Jump to first unread

    @Test("the unread jump fetches on the boundary but lands on the first unread rendered row")
    func unreadJumpFetchesOnBoundary() {
        let d = Drive(self)
        // A large unread: the boundary (5) is older than everything loaded, so the divider is
        // pinned to the top of the window — the seam isn't loaded.
        let pointer = row(readStateKnown: true, lastReadId: 5)
        d.frame(state(pointer, msgs(100...110)))
        let pinned = d.built()
        // Every loaded row is unread: nothing but dividers above the marker.
        let dividerRow = try! #require(pinned.dividerRow)
        #expect(pinned.rows[..<dividerRow].allSatisfy { $0.message == nil })
        #expect(d.scroll.jumpToFirstUnread())
        // The FETCH anchors on the boundary…
        #expect(d.scroll.requestAround(d.last, key: channel) == 5)
        // …and while it's in flight the top-pinned divider is no target.
        d.frame(d.last)
        let waiting = d.built()
        #expect(d.scroll.jumpTargetRow(waiting) == nil)
        #expect(isWait(d.scroll.landing(waiting)))
        // The slice arrives around the boundary, whose own id is a frame this channel never renders.
        let seam = msgs(1...4) + [msg(5, nick: nil, type: .other, text: "")] + msgs(6...9)
        d.frame(state(row(readStateKnown: true, lastReadId: 5, hasMoreNewer: true, historyRevision: 1), seam))
        let reply = d.built()
        #expect(isConverge(d.scroll.landing(reply)))
        let target = d.scroll.jumpTargetRow(reply)!
        #expect(target == reply.firstUnreadRow)
        #expect(reply.rows[target].message?.id == 6)
    }

    @Test("the unread jump with the seam already loaded lands without a fetch")
    func unreadJumpSeamLoaded() {
        let (scroll, built) = withDivider()
        #expect(scroll.jumpToFirstUnread())
        #expect(scroll.requestAround(state(row(readStateKnown: true, lastReadId: 5), msgs(1...10)), key: channel) == nil)
        let current = build(scroll, state(row(readStateKnown: true, lastReadId: 5), msgs(1...10)), seq: 2)
        #expect(isConverge(scroll.landing(current)))
        #expect(scroll.jumpTargetRow(current) == built.firstUnreadRow)
    }

    @Test("the unread jump never peels back a clear - its target is a rendered row")
    func unreadJumpNeverPeelsClear() {
        let d = Drive(self)
        // Read up to 3; cleared up to 5. The fetch anchor (3) is behind the marker, the target isn't.
        let s = state(row(readStateKnown: true, lastReadId: 3, clearedBeforeId: 5, clearedAt: clearedAt), msgs(1...10))
        d.frame(s)
        #expect(d.scroll.jumpToFirstUnread())
        d.frame(s)
        let built = d.built()
        #expect(!d.scroll.options.showsClearedHistory)
        #expect(isConverge(d.scroll.landing(built)))
        #expect(built.rows[d.scroll.jumpTargetRow(built)!].message?.id == 6)
    }

    @Test("there is no unread jump without a boundary")
    func noUnreadJumpWithoutBoundary() {
        let scroll = opened()
        #expect(!scroll.jumpToFirstUnread())
        _ = scroll.onFrame(state(row(readStateKnown: true, lastReadId: 0)), key: channel, seq: 1)
        #expect(!scroll.jumpToFirstUnread())
        #expect(!scroll.jumpPending)
    }

    @Test("two jumps out of the slice before either reply - each reply is its own request's")
    func twoJumpsTwoReplies() {
        let d = Drive(self)
        let live = msgs(100...110)
        d.frame(state(nil, live))
        d.scroll.jumpTo(4)
        #expect(d.frame(state(nil, live)).loadAround == 4)
        // B supersedes A before A's reply: B's fetch waits for A's reply, or it'd take it for its own.
        d.scroll.jumpTo(60)
        #expect(d.scroll.requestAround(d.last, key: channel) == nil)
        #expect(d.frame(state(nil, live)).loadAround == nil)
        #expect(isWait(d.land()))
        // A's reply lands — without B's message. It's A's: B isn't abandoned, it asks now.
        let aReply = d.frame(state(row(hasMoreNewer: true, historyRevision: 1), msgs(1...8)))
        #expect(aReply.loadAround == 60)
        #expect(isWait(d.land()))
        #expect(d.scroll.jumpPending)
        // B's reply lands with B's message in it, and that's where it goes.
        d.frame(state(row(hasMoreNewer: true, historyRevision: 2), msgs(55...65)))
        let built = d.built()
        #expect(isConverge(d.scroll.landing(built)))
        #expect(built.rows[d.scroll.jumpTargetRow(built)!].message?.id == 60)
    }

    @Test("an unread jump whose fetch a drop voided waits for the reconnect, not the stale divider")
    func unreadJumpVoidedByDrop() {
        let d = Drive(self)
        let pointer = row(readStateKnown: true, lastReadId: 5)
        let window = msgs(100...110)
        d.frame(state(pointer, window))
        #expect(d.scroll.jumpToFirstUnread())
        #expect(d.frame(state(pointer, window)).loadAround == 5)
        // The socket drops while the slice is in the air.
        d.frame(state(pointer, window, connection: .reconnecting))
        let stale = d.built()
        #expect(d.scroll.jumpTargetRow(stale) == nil)
        #expect(isWait(d.scroll.landing(stale)))
        // Back up: asked again.
        #expect(d.frame(state(pointer, window, burstGeneration: 2)).loadAround == 5)
    }

    @Test("the unread banner tapped offline waits rather than landing on the top-pinned divider")
    func unreadJumpOffline() {
        let d = Drive(self)
        let pointer = row(readStateKnown: true, lastReadId: 5)
        d.frame(state(pointer, msgs(100...110), connection: .reconnecting))
        #expect(d.scroll.jumpToFirstUnread())
        #expect(d.scroll.requestAround(d.last, key: channel) == nil)
        #expect(isWait(d.land()))
        #expect(d.scroll.jumpPending)
    }

    // MARK: - The /clear reveal

    @Test("a jump onto a row the clear marker hides peels it back")
    func jumpPeelsBackClear() {
        let scroll = opened()
        let s = state(row(clearedBeforeId: 5, clearedAt: clearedAt), msgs(1...10))
        scroll.jumpTo(3)
        let hidden = build(scroll, s)
        #expect(hidden.rowIndex(containing: 3) == nil)
        let step = scroll.onRows(hidden, wasNearBottom: true)
        #expect(step.optionsChanged)
        #expect(scroll.options.showsClearedHistory)
        // The build that drew it hidden is stale now; the next one draws it.
        #expect(isWait(scroll.landing(hidden)))
        let shown = build(scroll, s)
        #expect(shown.rowIndex(containing: 3) != nil)
        #expect(isConverge(scroll.landing(shown)))
    }

    @Test("a new clear retires the reveal")
    func newClearRetiresReveal() {
        let scroll = opened()
        scroll.jumpTo(3)
        let cleared = state(row(clearedBeforeId: 5, clearedAt: clearedAt), msgs(1...10))
        _ = scroll.onRows(build(scroll, cleared), wasNearBottom: true)
        #expect(scroll.options.showsClearedHistory)
        // The jump lands on the revealed row and settles.
        let shown = build(scroll, cleared)
        let jump = try! #require(token(scroll.landing(shown)))
        _ = scroll.finishJump(jump, current: shown, interrupted: false)
        // A clear issued since — here or on another device — puts the marker back.
        let step = scroll.onRows(build(scroll, state(row(clearedBeforeId: 10, clearedAt: clearedAt), msgs(1...12))), wasNearBottom: true)
        #expect(step.optionsChanged)
        #expect(!scroll.options.showsClearedHistory)
    }

    // MARK: - Jump to latest

    @Test("jump to latest from a detached slice re-attaches and lands at the new tail once it arrives")
    func reattachLandsAtNewTail() {
        let d = Drive(self)
        d.frame(state(row(hasMoreNewer: true), msgs(1...10)))
        _ = d.built()
        #expect(d.scroll.jumpToLatest(hasRows: true, detached: true) == .reattach)
        #expect(d.scroll.landingPending)
        #expect(d.scroll.requestLatest(d.last, key: channel))
        // Asked: not again for the same burst.
        #expect(!d.frame(d.last).loadLatest)
        // Still the old slice: wait.
        #expect(isWait(d.land()))
        // A drag while the latest slice is in flight must not drop the asked-for landing.
        #expect(!d.scroll.onUserDrag())
        #expect(d.scroll.landingPending)
        d.frame(state(row(historyRevision: 1), msgs(500...520)))
        #expect(isAtTail(d.land()))
        // The table parks the tail and says so.
        d.scroll.landedAtTail()
        #expect(!d.scroll.landingPending)
    }

    @Test("a re-attach lost with its socket is asked for again")
    func reattachRearmed() {
        let d = Drive(self)
        let slice = msgs(1...10)
        d.frame(state(row(hasMoreNewer: true), slice))
        _ = d.scroll.jumpToLatest(hasRows: true, detached: true)
        #expect(d.scroll.requestLatest(d.last, key: channel))
        #expect(!d.frame(state(row(hasMoreNewer: true), slice, connection: .reconnecting)).loadLatest)
        #expect(d.frame(state(row(hasMoreNewer: true), slice)).loadLatest)
        // Replaced under a steady Connected: the new burst asks again.
        #expect(d.frame(state(row(hasMoreNewer: true), slice, burstGeneration: 2)).loadLatest)
        #expect(!d.frame(state(row(hasMoreNewer: true), slice, burstGeneration: 2)).loadLatest)
    }

    @Test("jump to latest cancels a pending jump when it rides down")
    func rideDownCancelsJump() {
        let d = Drive(self)
        d.frame(state(nil, msgs(1...10)))
        d.scroll.jumpTo(4)
        #expect(d.scroll.jumpToLatest(hasRows: true, detached: false) == .scrollDown)
        #expect(!d.scroll.jumpPending)
        #expect(isIdle(d.land()))
    }

    @Test("jump to latest with a jump's slice still in the air re-attaches past it")
    func reattachPastStrayReply() {
        let d = Drive(self)
        let live = msgs(100...110)
        d.frame(state(nil, live))
        d.scroll.jumpTo(4)
        #expect(d.frame(state(nil, live)).loadAround == 4)
        // The reader gives up on it and asks for the bottom.
        #expect(d.scroll.jumpToLatest(hasRows: true, detached: false) == .reattach)
        #expect(!d.scroll.jumpPending)
        #expect(d.scroll.requestLatest(d.last, key: channel))
        // The stray `around` reply lands anyway, detaching the buffer: nothing converges on it.
        d.frame(state(row(hasMoreNewer: true, historyRevision: 1), msgs(1...8)))
        #expect(isWait(d.land()))
        // The `latest` behind it re-attaches, and that's where the reader lands.
        d.frame(state(row(historyRevision: 2), msgs(100...112)))
        #expect(isAtTail(d.land()))
    }

    @Test("re-attaching puts a clear back too")
    func reattachPutsClearBack() {
        let scroll = opened()
        scroll.jumpTo(3)
        _ = scroll.onRows(build(scroll, state(row(clearedBeforeId: 5, clearedAt: clearedAt), msgs(1...10))), wasNearBottom: false)
        #expect(scroll.options.showsClearedHistory)
        #expect(scroll.jumpToLatest(hasRows: true, detached: true) == .reattach)
        #expect(!scroll.options.showsClearedHistory)
    }

    @Test("jump to latest on an attached buffer rides down, clears the badge, and puts a clear back")
    func rideDownClearsBadge() {
        let scroll = opened()
        scroll.jumpTo(3)
        _ = scroll.onRows(build(scroll, state(row(clearedBeforeId: 5, clearedAt: clearedAt), msgs(1...10))), wasNearBottom: false)
        #expect(scroll.options.showsClearedHistory)
        #expect(scroll.jumpToLatest(hasRows: true, detached: false) == .scrollDown)
        #expect(!scroll.options.showsClearedHistory)
        #expect(scroll.newWhileAway == 0)
        #expect(scroll.jumpToLatest(hasRows: false, detached: false) == .nothing)
    }

    @Test("a drag releases a converging jump, never one waiting on its fetch")
    func dragReleasesConvergingOnly() {
        let scroll = opened()
        scroll.jumpTo(4)
        scroll.requestAround(state(nil, msgs(100...110)), key: channel)
        #expect(!scroll.onUserDrag())
        let held = opened()
        held.jumpTo(4)
        #expect(isConverge(held.landing(build(held, state(nil, msgs(1...10))))))
        #expect(held.onUserDrag())
    }

    // MARK: - Paging

    @Test("paging asks older near the top, and newer only near the bottom of a detached slice")
    func pagingRules() {
        let scroll = opened()
        let attached = build(scroll, state(nil, msgs(1...10)))
        _ = scroll.onRows(attached, wasNearBottom: true)
        let near = facts(pagesOlder: true, pagesNewer: true)
        let step = scroll.onLayout(near, current: attached, detached: false, connectionBannerShown: false, online: true)
        #expect(step.loadOlder)
        #expect(!step.loadNewer)
        #expect(scroll.onLayout(near, current: attached, detached: true, connectionBannerShown: false, online: true).loadNewer)
        #expect(!scroll.onLayout(facts(), current: attached, detached: true, connectionBannerShown: false, online: true).loadOlder)
    }

    @Test("paging waits out a pending landing and an unlanded history")
    func pagingWaits() {
        let scroll = opened()
        let near = facts(pagesOlder: true, pagesNewer: true)
        let stub = build(scroll, state(row(hydrated: false), msgs(100...103)))
        #expect(!scroll.onLayout(near, current: stub, detached: false, connectionBannerShown: false, online: true).loadOlder)
        let built = build(scroll, state(nil, msgs(1...10)))
        scroll.jumpTo(200)
        let step = scroll.onLayout(near, current: built, detached: true, connectionBannerShown: false, online: true)
        #expect(!step.loadOlder)
        #expect(!step.loadNewer)
    }

    @Test("a window the filters thinned to nothing tops itself up")
    func thinnedWindowTopsUp() {
        let scroll = opened()
        let ignores = IgnoreSet(byNetwork: [1: [IgnoreRule(id: 1, mask: "spammer")]])
        let all = (1...5).map { msg($0, nick: "spammer") }
        let empty = build(scroll, state(nil, all, ignores: ignores))
        #expect(empty.rows.isEmpty)
        #expect(scroll.wantsTopUp(empty, online: true))
        // Not with history exhausted, not for an unhydrated buffer (the hydrate's), not mid-jump.
        #expect(!scroll.wantsTopUp(build(scroll, state(row(hasMoreOlder: false), all, ignores: ignores)), online: true))
        #expect(!scroll.wantsTopUp(build(scroll, state(row(hydrated: false), all, ignores: ignores)), online: true))
        scroll.jumpTo(3)
        #expect(!scroll.wantsTopUp(empty, online: true))
    }

    @Test("nothing is paged or topped up offline - the kit would mark it in flight for good")
    func nothingOffline() {
        let scroll = opened()
        let attached = build(scroll, state(nil, msgs(1...10)))
        _ = scroll.onRows(attached, wasNearBottom: true)
        let near = facts(pagesOlder: true, pagesNewer: true)
        let offline = scroll.onLayout(near, current: attached, detached: true, connectionBannerShown: false, online: false)
        #expect(!offline.loadOlder)
        #expect(!offline.loadNewer)
        let ignores = IgnoreSet(byNetwork: [1: [IgnoreRule(id: 1, mask: "spammer")]])
        let empty = build(scroll, state(nil, (1...5).map { msg($0, nick: "spammer") }, ignores: ignores))
        #expect(scroll.wantsTopUp(empty, online: true))
        #expect(!scroll.wantsTopUp(empty, online: false))
    }

    @Test("a request may go out only with the socket up and a path to the server")
    func mayWrite() {
        #expect(ConversationScroll.mayWrite(state()))
        #expect(!ConversationScroll.mayWrite(state(connection: .reconnecting)))
        // Airplane mode: the socket still reads Connected for a while.
        #expect(!ConversationScroll.mayWrite(state(reachable: false)))
    }

    // MARK: - What UITableView makes different

    @Test("the opening landing is pending until the table has rows and reports it parked")
    func openingLanding() {
        let scroll = machine()
        #expect(scroll.landingPending)
        // No rows yet: nothing to park.
        let empty = build(scroll, state(row(hydrated: false)))
        #expect(isWait(scroll.landing(empty)))
        // Rows: the table is asked to park them, and asked again on every pass until it says so.
        let built = build(scroll, state(nil, msgs(1...10)))
        #expect(isAtTail(scroll.landing(built)))
        #expect(isAtTail(scroll.landing(built)))
        #expect(!scroll.onRows(built, wasNearBottom: true).follow)
        scroll.landedAtTail()
        #expect(!scroll.landingPending)
        #expect(isIdle(scroll.landing(built)))
        #expect(scroll.onRows(build(scroll, state(nil, msgs(1...11))), wasNearBottom: true).follow)
    }

    @Test("a drag releases the opening landing, never a jump or a re-attach")
    func dragReleasesOpening() {
        let scroll = machine()
        #expect(!scroll.onUserDrag())
        #expect(!scroll.landingPending)
        // A jump taken before the opening landed: the jump places, and a drag leaves it alone.
        let jumped = machine()
        jumped.jumpTo(4)
        #expect(!jumped.onUserDrag())
        #expect(jumped.jumpPending)
    }

    @Test("a jump supersedes the opening landing, and its end hands the tail back to the table")
    func jumpSupersedesOpening() {
        let scroll = machine()
        scroll.jumpTo(4)
        let built = build(scroll, state(nil, msgs(1...10)))
        let jump = try! #require(token(scroll.landing(built)))
        #expect(scroll.finishJump(jump, current: built, interrupted: false) == .flash(row: built.rowIndex(containing: 4)!))
        // Landed on the row: no tail landing follows.
        #expect(!scroll.landingPending)
        #expect(isIdle(scroll.landing(built)))
    }

    @Test("the trace hears every decision")
    func traceHearsDecisions() {
        let scroll = machine()
        var lines: [String] = []
        scroll.trace = { lines.append($0()) }
        _ = scroll.onFrame(state(row(readStateKnown: true, lastReadId: 5), msgs(1...10)), key: channel, seq: 1)
        #expect(lines.contains { $0.hasPrefix("divider latched") })
        let built = build(scroll, state(row(readStateKnown: true, lastReadId: 5), msgs(1...10)), seq: 1)
        _ = scroll.onRows(built, wasNearBottom: true)
        #expect(lines.contains { $0.hasPrefix("rows seq=1") })
        scroll.landedAtTail()
        #expect(lines.contains("landed at tail"))
    }
}

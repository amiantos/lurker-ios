// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// The `/clear` marker (#121): what the wire says, what the store keeps, and what the row
/// builder draws.
///
/// `/clear` is not a local wipe. It is a per-user, per-buffer boundary the SERVER holds, so
/// the marker is shared with every other device and nothing is ever deleted — which is why
/// most of what matters here is that the hidden messages are still present and reachable.
@Suite("Clear marker")
@MainActor
struct ClearMarkerTests {

    private let clearedAt = Date(timeIntervalSince1970: 1_784_548_800)

    private func msg(_ id: Int) -> Message {
        Message(id: id, type: .message, nick: "alice", text: "hi")
    }

    // MARK: - The wire

    @Test("a backlog frame carries the marker onto the buffer")
    func backlogCarriesTheMarker() {
        let frame = FrameParser.parseWs(
            ##"""
            {"kind":"backlog","networkId":1,"target":"#lurker","events":[],
             "hasMoreOlder":false,"clearedBeforeId":42,"clearedAt":"2026-07-20T12:00:00.000Z"}
            """##
        )
        guard case let .backlog(buffer, _, _, _, _) = frame else {
            Issue.record("expected a backlog, got \(frame)")
            return
        }
        #expect(buffer.clearedBeforeId == 42)
        #expect(buffer.clearedAt == clearedAt)
    }

    @Test("a backlog for a buffer that was never cleared says so")
    func backlogWithoutAMarker() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","events":[],"hasMoreOlder":false}"##
        )
        guard case let .backlog(buffer, _, _, _, _) = frame else {
            Issue.record("expected a backlog, got \(frame)")
            return
        }
        #expect(buffer.clearedBeforeId == 0)
        #expect(buffer.clearedAt == nil)
    }

    @Test("the buffer-cleared fan-out parses")
    func bufferClearedParses() {
        let frame = FrameParser.parseWs(
            ##"""
            {"kind":"buffer-cleared","networkId":1,"target":"#lurker","bufferId":7,
             "clearedBeforeId":42,"clearedAt":"2026-07-20T12:00:00.000Z"}
            """##
        )
        #expect(
            frame
                == .bufferCleared(
                    networkId: 1, target: "#lurker", clearedBeforeId: 42, clearedAt: clearedAt))
    }

    @Test("an undo arrives as a zero boundary, not as a missing frame")
    func undoParses() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"buffer-cleared","networkId":1,"target":"#lurker","clearedBeforeId":0,"clearedAt":null}"##
        )
        #expect(
            frame
                == .bufferCleared(
                    networkId: 1, target: "#lurker", clearedBeforeId: 0, clearedAt: nil))
    }

    // MARK: - The store

    private func clearedBuffer() -> ChatState {
        let buffer = Buffer(networkId: 1, target: "#lurker", kind: .channel)
        var state = LurkerStore.reduce(
            ChatState(), .backlog(buffer: buffer, messages: [], hydrated: true, append: false, speakers: nil))
        state = LurkerStore.reduce(
            state,
            .bufferCleared(networkId: 1, target: "#lurker", clearedBeforeId: 42, clearedAt: clearedAt))
        return state
    }

    @Test("the fan-out moves the marker on a buffer we hold")
    func fanOutMovesTheMarker() {
        let buffer = clearedBuffer().buffers["1::#lurker"]
        #expect(buffer?.clearedBeforeId == 42)
        #expect(buffer?.clearedAt == clearedAt)
    }

    @Test("an undo drops both halves together")
    func undoDropsBothHalves() {
        // A boundary with no instant would hide rows and draw no divider — the one state that
        // leaves the user with no way back — so the two always move together.
        let state = LurkerStore.reduce(
            clearedBuffer(),
            .bufferCleared(networkId: 1, target: "#lurker", clearedBeforeId: 0, clearedAt: nil))
        #expect(state.buffers["1::#lurker"]?.clearedBeforeId == 0)
        #expect(state.buffers["1::#lurker"]?.clearedAt == nil)
    }

    @Test("a clear for a buffer we don't hold conjures nothing")
    func aClearForAnUnknownBufferIsIgnored() {
        let state = LurkerStore.reduce(
            ChatState(),
            .bufferCleared(networkId: 1, target: "#nope", clearedBeforeId: 42, clearedAt: clearedAt))
        #expect(state.buffers["1::#nope"] == nil)
    }

    @Test("⚠ a later backlog is authoritative and can retract the marker")
    func aBacklogRetractsTheMarker() {
        // Every backlog frame states the marker — the server's `bufferStateFields` is shared by
        // the shell builder and the snapshot loop too — so rescuing a prior value the way
        // `topic` is rescued would keep a marker an unclear elsewhere had already dropped.
        let state = LurkerStore.reduce(
            clearedBuffer(),
            .backlog(
                buffer: Buffer(networkId: 1, target: "#lurker", kind: .channel),
                messages: [], hydrated: true, append: false, speakers: nil))
        #expect(state.buffers["1::#lurker"]?.clearedBeforeId == 0)
    }

    // MARK: - The rows

    private func rows(
        _ messages: [Message], clearedBeforeId: Int, clearedAt: Date?, hasMoreOlder: Bool = true,
        hasMoreNewer: Bool = false, showsClearedHistory: Bool = false
    ) -> [MessageRow] {
        MessageRows.build(
            messages: messages, dividerAfterId: nil, hasMoreOlder: hasMoreOlder,
            hasMoreNewer: hasMoreNewer, clearedBeforeId: clearedBeforeId, clearedAt: clearedAt,
            showsClearedHistory: showsClearedHistory)
    }

    @Test("everything at or below the boundary is hidden, and the rest stays")
    func theBoundaryHides() {
        let built = rows([msg(1), msg(2), msg(3)], clearedBeforeId: 2, clearedAt: clearedAt)
        #expect(built.compactMap(\.message?.id) == [3], "the boundary itself is hidden, not kept")
    }

    @Test("the divider tops the visible region")
    func theDividerIsFirst() {
        let built = rows([msg(1), msg(2)], clearedBeforeId: 1, clearedAt: clearedAt)
        #expect(built.first == .clearedDivider(at: clearedAt))
    }

    @Test("⚠⚠ a clear that hid everything still draws the divider")
    func anEmptyVisibleRegionKeepsTheUndo() {
        // The one outcome this feature must not have: a buffer that goes blank with no way
        // back but typing `/clear off` blind. The divider IS the undo affordance.
        let built = rows([msg(1), msg(2)], clearedBeforeId: 2, clearedAt: clearedAt)
        #expect(built == [.clearedDivider(at: clearedAt)])
    }

    @Test("no marker, no divider and no filtering")
    func anUnclearedBufferIsUntouched() {
        let built = rows([msg(1), msg(2)], clearedBeforeId: 0, clearedAt: nil)
        #expect(built.compactMap(\.message?.id) == [1, 2])
        #expect(!built.contains { if case .clearedDivider = $0 { true } else { false } })
    }

    @Test("⚠⚠ a detached buffer ignores the marker entirely")
    func detachedIgnoresTheMarker() {
        // A jump to a search hit or a highlight shows context around its anchor whether or not
        // it predates a clear. Answering that tap with an empty screen would obey the wrong
        // instruction — the user asked to see THAT message.
        let built = rows(
            [msg(1), msg(2)], clearedBeforeId: 2, clearedAt: clearedAt, hasMoreNewer: true)
        #expect(built.compactMap(\.message?.id) == [1, 2])
        #expect(
            !built.contains { if case .clearedDivider = $0 { true } else { false } },
            "and no divider either — half-applying the marker would be worse than both")
    }

    @Test("⚠ start-of-history is suppressed while a clear is in force")
    func startOfHistoryIsSuppressed() {
        // `hasMoreOlder` answers "is there more to FETCH", but the row SAYS "there is nothing
        // above this" — and above it sits a buffer's worth of hidden conversation.
        let built = rows(
            [msg(1), msg(2)], clearedBeforeId: 1, clearedAt: clearedAt, hasMoreOlder: false)
        #expect(!built.contains { if case .startOfHistory = $0 { true } else { false } })
        // Still drawn when nothing is cleared, so this suppression is the marker's doing.
        let uncleared = rows([msg(1), msg(2)], clearedBeforeId: 0, clearedAt: nil, hasMoreOlder: false)
        #expect(uncleared.first == .startOfHistory)
    }

    @Test("a locally synthesized line survives a clear")
    func localLinesAreNeverHidden() {
        // `LurkerStore.appendLocal` synthesizes id-less system lines (an unrecognized command,
        // a refusal). They have no place in the server's ordering to be above or below a
        // boundary, and they postdate the clear by construction.
        let local = Message(id: 0, type: .system, nick: nil, text: "unknown command")
        let built = rows([msg(1), local], clearedBeforeId: 5, clearedAt: clearedAt)
        #expect(built.compactMap(\.message?.text) == ["unknown command"])
    }

    @Test("⚠⚠ a boundary with no instant is discarded whole, at the parser")
    func aHalfStatedMarkerIsDiscarded() {
        // `cleared_at` is nullable server-side and the rename / case-fold merges carry the two
        // columns independently, so this reaches us from the wire rather than only from a bug
        // here. Taken at face value it hides every row and draws no divider — a blank buffer
        // whose only way out is a `/clear off` the reader was never told about.
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","events":[],"hasMoreOlder":false,"clearedBeforeId":42,"clearedAt":null}"##
        )
        guard case let .backlog(buffer, _, _, _, _) = frame else {
            Issue.record("expected a backlog, got \(frame)")
            return
        }
        #expect(buffer.clearedBeforeId == 0, "showing cleared messages is the safe failure")
        #expect(buffer.clearedAt == nil)
    }

    @Test("⚠⚠ and the row builder refuses to half-apply one either, in both directions")
    func theRowBuilderRefusesAHalfMarker() {
        // Boundary with no instant: would hide every row and draw nothing to undo with.
        let noInstant = rows([msg(1), msg(2)], clearedBeforeId: 2, clearedAt: nil)
        #expect(noInstant.compactMap(\.message?.id) == [1, 2], "no instant, no filtering")
        #expect(!noInstant.contains { if case .clearedDivider = $0 { true } else { false } })

        // Instant with no boundary: hides nothing, but would tell the reader their buffer is
        // cleared and offer a `/clear off` that does nothing at all.
        let noBoundary = rows([msg(1), msg(2)], clearedBeforeId: 0, clearedAt: clearedAt)
        #expect(noBoundary.compactMap(\.message?.id) == [1, 2])
        #expect(!noBoundary.contains { if case .clearedDivider = $0 { true } else { false } })
    }

    @Test("⚠ a clear drops the local lines it predates")
    func aClearDropsLocalLines() {
        // `appendLocal` rows carry neither an id nor a date, so the row filter has nothing to
        // judge them by; left alone they outlive a clear and render UNDER the divider as though
        // they had arrived after it. They are ephemeral anyway, so the marker takes them.
        let store = LurkerStore()
        let key = BufferKey(networkId: 1, target: "#lurker")
        store.apply(
            .backlog(
                buffer: Buffer(networkId: 1, target: "#lurker", kind: .channel, hydrated: true),
                messages: [msg(10)], hydrated: true, append: false, speakers: nil))
        store.appendLocal(key, text: "unknown command")
        #expect(store.state.messages[key.id]?.count == 2)

        store.apply(
            .bufferCleared(
                networkId: 1, target: "#lurker", clearedBeforeId: 10, clearedAt: clearedAt))
        #expect(store.state.messages[key.id]?.map(\.id) == [10], "the local line went with it")
    }

    @Test("an undo leaves local lines alone")
    func anUndoKeepsLocalLines() {
        let store = LurkerStore()
        let key = BufferKey(networkId: 1, target: "#lurker")
        store.apply(
            .backlog(
                buffer: Buffer(networkId: 1, target: "#lurker", kind: .channel, hydrated: true),
                messages: [msg(10)], hydrated: true, append: false, speakers: nil))
        store.appendLocal(key, text: "unknown command")
        store.apply(
            .bufferCleared(networkId: 1, target: "#lurker", clearedBeforeId: 0, clearedAt: nil))
        #expect(store.state.messages[key.id]?.count == 2, "nothing was hidden, so nothing goes")
    }

    // MARK: - Paging past the boundary

    private func cleared(_ beforeId: Int, detached: Bool = false) -> Buffer {
        var buffer = Buffer(networkId: 1, target: "#lurker", kind: .channel, hydrated: true)
        buffer.hasMoreNewer = detached
        buffer.applyCleared(beforeId: beforeId, at: clearedAt)
        return buffer
    }

    @Test("⚠⚠ paging older stops once the cursor reaches the clear boundary")
    func pagingStopsAtTheBoundary() {
        // The ~5s "Loading messages…" QA saw after /clear. A cleared buffer builds to one
        // divider, which is unscrollable, which asks for another page, which is also entirely
        // hidden, which is still unscrollable — walking the whole buffer into memory behind a
        // stuck spinner.
        #expect(!cleared(50).olderPageCouldBeVisible(oldestHeldId: 10))
        #expect(!cleared(50).olderPageCouldBeVisible(oldestHeldId: 50), "the boundary is hidden too")
    }

    @Test("but it still pages while there is visible history between the two")
    func pagingContinuesAboveTheBoundary() {
        // A clear anchors at the tail, so new messages accumulate above it; once the held slice
        // starts above the boundary there is a visible gap worth fetching.
        #expect(cleared(50).olderPageCouldBeVisible(oldestHeldId: 51))
    }

    @Test("an uncleared buffer pages normally")
    func anUnclearedBufferPages() {
        #expect(cleared(0).olderPageCouldBeVisible(oldestHeldId: 1))
    }

    @Test("and a detached buffer pages, because it ignores the marker")
    func aDetachedBufferPages() {
        #expect(cleared(50, detached: true).olderPageCouldBeVisible(oldestHeldId: 10))
    }

    @Test("so does a revealed one — the reader can scroll up through what was hidden")
    func aRevealedBufferPages() {
        #expect(
            cleared(50).olderPageCouldBeVisible(oldestHeldId: 10, showingClearedHistory: true))
    }

    // MARK: - Jumping to a hidden message

    @Test("revealing is what makes a hidden anchor renderable")
    func revealingShowsAHiddenAnchor() {
        // A bookmark or search hit from before a clear. The row is loaded and filtered out, so
        // there is nothing to fetch — only the filter to suppress.
        let hidden = rows([msg(10), msg(20)], clearedBeforeId: 50, clearedAt: clearedAt)
        #expect(hidden.compactMap(\.message?.id) == [], "hidden while the filter is in force")

        let revealed = rows(
            [msg(10), msg(20)], clearedBeforeId: 50, clearedAt: clearedAt,
            showsClearedHistory: true)
        #expect(revealed.compactMap(\.message?.id) == [10, 20], "and visible once revealed")
        #expect(
            !revealed.contains { if case .clearedDivider = $0 { true } else { false } },
            "no marker either — a revealed buffer is not a half-cleared one")
    }

    @Test("⚠⚠ the marker itself is untouched by a reveal, so a reopen is cleared again")
    func aRevealNeverTouchesTheMarker() {
        // The reveal is SCREEN state (`ChatViewController.showsClearedHistory`), which is why
        // nothing here can express it: `BufferNavigation` builds a fresh screen per open, so it
        // retires itself. A flag on the buffer had no natural retirement — one jump peeled the
        // buffer open for good and reopening never restored the clear, which is the bug that
        // moved it out of the store.
        let state = clearedBuffer()
        #expect(state.buffers["1::#lurker"]?.clearedBeforeId == 42)
        #expect(state.buffers["1::#lurker"]?.hasMoreNewer == false, "and paging state is its own")
    }

    // MARK: - The command

    private func parse(_ line: String) -> [CommandEffect] {
        guard case let .command(effects) = CommandParser.parse(line, networkId: 1, target: "#lurker")
        else { return [] }
        return effects
    }

    @Test("/clear hides, /clear off and /clear undo bring it back")
    func theCommandParses() {
        #expect(parse("/clear") == [.clear(target: "#lurker", undo: false)])
        #expect(parse("/clear off") == [.clear(target: "#lurker", undo: true)])
        #expect(parse("/clear undo") == [.clear(target: "#lurker", undo: true)])
        #expect(parse("/clear OFF") == [.clear(target: "#lurker", undo: true)], "case-insensitive")
        #expect(parse("/clear  off  ") == [.clear(target: "#lurker", undo: true)], "spacing")
    }

    @Test("an unrecognised argument clears rather than refusing")
    func anUnknownArgumentStillClears() {
        // `/clear all` is what someone reaching for "clear everything" types; refusing it
        // would decline the thing they asked for on the grounds that they were too specific.
        #expect(parse("/clear all") == [.clear(target: "#lurker", undo: false)])
    }
}

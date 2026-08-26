// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// Giving back a line the server refused (#128).
///
/// ⚠⚠ The failure this guards is SILENCE, which is the hardest kind to notice: before this, iOS
/// never put a `clientId` on a send, so `wsHub` never emitted `send-result`, so the composer
/// cleared and the message was simply gone. Every assertion here is about a line surviving a
/// round trip it used to disappear into.
@Suite("Unsent sends")
struct UnsentCorrelatorTests {

    private let chat = BufferKey(networkId: 1, target: "#chat")
    private let dm = BufferKey(networkId: 1, target: "bob")

    @Test("a refused line comes back, addressed to where it was typed")
    func refusalReturnsTheOrigin() {
        var c = UnsentCorrelator()
        let id = c.track(chat, line: "hey there")
        #expect(c.resolve(clientId: id, ok: false) == .init(key: chat, line: "hey there"))
    }

    @Test("a `/msg` comes back to the buffer it was typed in, as typed")
    func slashMsgRestoresTheWholeLineToTheOrigin() {
        // ⚠⚠ The case that decides the whole design. `/msg bob hi` typed in #chat puts `hi` on
        // the wire addressed to `bob`, and ACTIVATES the DM before the ack lands. Restoring the
        // wire payload, or restoring to whatever buffer is in front of the user, both stranded a
        // fragment in the wrong conversation. The origin is not on the wire; it is only here.
        var c = UnsentCorrelator()
        let id = c.track(chat, line: "/msg bob hi")
        let origin = c.resolve(clientId: id, ok: false)
        #expect(origin?.key == chat, "the composer that lost the text was #chat's, not the DM's")
        #expect(origin?.line == "/msg bob hi", "give back what was typed, not what went out")
    }

    @Test("a success gives nothing back, and is forgotten")
    func successRestoresNothing() {
        var c = UnsentCorrelator()
        let id = c.track(chat, line: "hey")
        #expect(c.resolve(clientId: id, ok: true) == nil)
        // ⚠ Forgetting on success is what keeps this from growing for the life of the socket —
        // every send is acked, and only the refusals are interesting.
        #expect(c.pendingCount == 0)
    }

    @Test("one line put on the wire several times comes back once")
    func oneLineRestoresOnce() {
        // ⚠⚠ A command can produce several sends sharing the line's id. There is ONE line in the
        // composer to give back, so a second refusal must find nothing — otherwise the restore
        // races itself and the no-clobber rule in the store decides the outcome by accident.
        var c = UnsentCorrelator()
        let id = c.track(chat, line: "/me waves")
        #expect(c.resolve(clientId: id, ok: false) != nil)
        #expect(c.resolve(clientId: id, ok: false) == nil)
    }

    @Test("an ack this client never asked for is ignored")
    func unknownIdsAreIgnored() {
        var c = UnsentCorrelator()
        _ = c.track(chat, line: "hey")
        #expect(c.resolve(clientId: "ios-999", ok: false) == nil)
        #expect(c.resolve(clientId: nil, ok: false) == nil)
        #expect(c.pendingCount == 1, "an unknown id must not disturb what IS outstanding")
    }

    @Test("ids do not collide across lines or buffers")
    func idsAreDistinct() {
        var c = UnsentCorrelator()
        let a = c.track(chat, line: "one")
        let b = c.track(dm, line: "two")
        #expect(a != b)
        #expect(c.resolve(clientId: b, ok: false)?.line == "two")
        #expect(c.resolve(clientId: a, ok: false)?.line == "one")
    }

    @Test("a dead socket abandons outstanding sends without restoring them")
    func abandonDoesNotRestore() {
        // ⚠⚠ Deliberate, and the reasoning is in `abandonAll`: a send the socket died under may
        // have reached IRC. Restoring risks the same line going to a channel twice with no way to
        // take it back, which is worse than losing one.
        var c = UnsentCorrelator()
        let id = c.track(chat, line: "hey")
        c.abandonAll()
        #expect(c.pendingCount == 0)
        #expect(c.resolve(clientId: id, ok: false) == nil)
    }
}

/// Where a refused line waits until there is a composer to put it in.
@Suite("Unsent holds")
@MainActor
struct UnsentHoldTests {

    private let chat = BufferKey(networkId: 1, target: "#chat")

    @Test("a held line is handed over once, then gone")
    func takeIsReadAndClear() {
        let store = LurkerStore()
        store.holdUnsent(chat, text: "hey there")
        #expect(store.takeUnsent(chat) == "hey there")
        // ⚠ A mirror rather than a handoff would re-fill the field every time the buffer was
        // reopened, long after the user dealt with it.
        #expect(store.takeUnsent(chat) == nil)
    }

    @Test("a hold never clobbers one already waiting")
    func holdDoesNotClobber() {
        let store = LurkerStore()
        store.holdUnsent(chat, text: "first")
        store.holdUnsent(chat, text: "second")
        #expect(store.takeUnsent(chat) == "first", "overwriting loses a line to save a line")
    }

    @Test("a rename carries the hold to the surviving buffer")
    func renameMovesTheHold() {
        // ⚠⚠ Left under the dead key this is unreachable forever — nothing reads that id again —
        // and the user's line is gone with no way to notice. Same class as the in-flight page
        // flags the view model rekeys beside it.
        let store = LurkerStore()
        store.apply(
            .backlog(
                buffer: Buffer(networkId: 1, target: "#chat", kind: .channel, hydrated: true),
                messages: [], hydrated: true, append: false, speakers: nil))
        store.holdUnsent(chat, text: "hey there")
        store.apply(
            .bufferRenamed(
                networkId: 1, from: "#chat", to: "#lounge", bufferId: nil, merged: false,
                mergedFromBufferId: nil))
        #expect(store.takeUnsent(chat) == nil)
        #expect(store.takeUnsent(BufferKey(networkId: 1, target: "#lounge")) == "hey there")
    }

    @Test("a refusal no longer raises a modal alert")
    func sendResultIsSilent() {
        // ⚠⚠ It used to set `state.error`, which presents an ALERT. That was written when this
        // frame never arrived, so the cost was invisible; since lurker#809's writable-connection
        // gate `ok:false` is the ordinary outcome of any reconnect, and the ConnectionBanner is
        // already saying "Reconnecting…". The failures that DO warrant words arrive as bare
        // `error` frames alongside, which this must not have disturbed.
        let store = LurkerStore()
        store.apply(.sendResult(clientId: "ios-1", ok: false, error: "not-connected"))
        #expect(store.state.error == nil)

        store.apply(.serverError("account paused"))
        #expect(store.state.error == "account paused")
        store.apply(.sendResult(clientId: "ios-2", ok: false, error: "account-paused"))
        #expect(
            store.state.error == "account paused",
            "the bare error frame's prose must not be overwritten by the ack's error code")
    }
}

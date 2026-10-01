// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Composer drafts that follow you across devices, their pending reply included (iOS #188).
@MainActor
final class DraftsTests: XCTestCase {

    private let chat = BufferKey(networkId: 1, target: "#chat")
    private let alice = ReplyParent(id: 7, nick: "alice", type: .message, text: "lunch?", userhost: "alice!a@host")

    private func entry(
        _ key: BufferKey? = nil, body: String = "half a thought", reply: DraftReply? = nil, carriesReply: Bool = true
    ) -> DraftEntry {
        let key = key ?? chat
        return DraftEntry(
            networkId: key.networkId!, target: key.target, body: body, reply: reply, carriesReply: carriesReply
        )
    }

    // MARK: - Wire

    func testParsesTheSnapshotWithItsReplies() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"draft-snapshot","drafts":[
          {"networkId":1,"target":"#chat","bufferId":4,"body":"alice: sure","updatedAt":"2026-10-01 10:00:00",
           "reply":{"messageId":7,"addressed":true,"parent":{"id":7,"nick":"alice","type":"message","text":"lunch?","userhost":"alice!a@host","self":false}}},
          {"networkId":1,"target":"bob","body":"","reply":{"messageId":9,"addressed":false,"parent":null}},
          {"networkId":2,"target":"#x","body":"plain","reply":null},
          {"target":"#nowhere","body":"no network"}
        ]}
        """##)
        guard case let .draftSnapshot(entries) = frame else { return XCTFail("\(frame)") }
        XCTAssertEqual(entries, [
            DraftEntry(networkId: 1, target: "#chat", body: "alice: sure",
                       reply: DraftReply(messageId: 7, addressed: true, parent: alice)),
            DraftEntry(networkId: 1, target: "bob", body: "",
                       reply: DraftReply(messageId: 9, addressed: false, parent: nil)),
            DraftEntry(networkId: 2, target: "#x", body: "plain", reply: nil),
        ], "an entry with no network is a draft for nowhere")
    }

    func testAnUpdateWithoutAReplyKeyIsNotOneThatClearsIt() {
        // ⚠⚠ `has` reads a null as absent; this is the one place the two mean different things.
        let cleared = FrameParser.parseWs(##"{"kind":"draft-updated","networkId":1,"target":"#chat","body":"x","reply":null}"##)
        let silent = FrameParser.parseWs(##"{"kind":"draft-updated","networkId":1,"target":"#chat","body":"x"}"##)
        XCTAssertEqual(cleared, .draftUpdated(entry(body: "x", reply: nil, carriesReply: true)))
        XCTAssertEqual(silent, .draftUpdated(entry(body: "x", reply: nil, carriesReply: false)))
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"draft-updated","networkId":1,"body":"x"}"##), .ignored)
    }

    // MARK: - The store

    func testTheSnapshotResolvesRepliesAndSkipsEmptyDrafts() {
        var state = ChatState()
        state.seedDrafts([
            entry(body: "alice: sure", reply: DraftReply(messageId: 7, addressed: true, parent: alice)),
            entry(BufferKey(networkId: 1, target: "#empty"), body: ""),
            entry(BufferKey(networkId: 1, target: "#gone"), body: "", reply: DraftReply(messageId: 3, addressed: false, parent: nil)),
        ])
        XCTAssertEqual(state.drafts[chat.id], ComposerDraft(
            body: "alice: sure",
            reply: PendingReply(messageId: 7, nick: "alice", type: .message, text: "lunch?", isSelf: false, addressed: true)
        ))
        XCTAssertFalse(state.hasDraft(BufferKey(networkId: 1, target: "#empty")))
        XCTAssertFalse(state.hasDraft(BufferKey(networkId: 1, target: "#gone")),
                       "a reply to a line that's gone is no reply, and with no text there's nothing left")
        XCTAssertTrue(state.hasDraft(BufferKey(networkId: 1, target: "#CHAT")), "keys fold case")
    }

    func testAReplyWithNothingTypedIsADraft() {
        var state = ChatState()
        state.seedDrafts([entry(body: "", reply: DraftReply(messageId: 7, addressed: false, parent: alice))])
        XCTAssertTrue(state.hasDraft(chat))
    }

    func testTheSnapshotLeavesWhatThisDeviceIsHolding() {
        var state = ChatState()
        let mine = ComposerDraft(body: "mine, newer")
        state.drafts[chat.id] = mine
        let other = BufferKey(networkId: 1, target: "#other")
        state.drafts[other.id] = ComposerDraft(body: "stale")
        let unlisted = BufferKey(networkId: 1, target: "#unlisted")
        state.drafts[unlisted.id] = ComposerDraft(body: "typed before the server ever heard")
        state.seedDrafts([entry(body: "older"), entry(other, body: "fresh")], keeping: [chat.id, unlisted.id])
        XCTAssertEqual(state.drafts[chat.id], mine)
        XCTAssertEqual(state.drafts[other.id], ComposerDraft(body: "fresh"))
        XCTAssertEqual(state.drafts[unlisted.id]?.body, "typed before the server ever heard")
    }

    func testTheSnapshotIsAuthoritativeForWhatItLeavesOut() {
        var state = ChatState()
        state.drafts[chat.id] = ComposerDraft(body: "sent from the browser since")
        state.seedDrafts([])
        XCTAssertNil(state.drafts[chat.id])
    }

    func testAnUpdateFromAnOlderServerKeepsTheReply() {
        var state = ChatState()
        state.seedDrafts([entry(body: "alice: ", reply: DraftReply(messageId: 7, addressed: true, parent: alice))])
        state.applyDraftUpdate(entry(body: "alice: on my way", carriesReply: false))
        XCTAssertEqual(state.drafts[chat.id]?.body, "alice: on my way")
        XCTAssertEqual(state.drafts[chat.id]?.reply?.messageId, 7)

        state.applyDraftUpdate(entry(body: "alice: on my way", reply: nil, carriesReply: true))
        XCTAssertNil(state.drafts[chat.id]?.reply, "reply: null clears it")
        state.applyDraftUpdate(entry(body: ""))
        XCTAssertNil(state.drafts[chat.id], "emptied on another device")
    }

    func testARelayedLineIsRepliedToAsThePersonInside() {
        // The strip and a cancel's `nick: ` both name who the Reply addressed — carol, not the bot.
        var state = ChatState()
        state.relayBots = RelayBotSet.empty.applying(networkId: 1, nick: "bridge", marked: true, pattern: "")
        let relayed = ReplyParent(id: 8, nick: "bridge", type: .message, text: "<carol> hello there")
        state.seedDrafts([entry(body: "carol: hi", reply: DraftReply(messageId: 8, addressed: true, parent: relayed))])
        XCTAssertEqual(state.drafts[chat.id]?.reply?.nick, "carol")
        XCTAssertEqual(state.drafts[chat.id]?.reply?.text, "hello there")
    }

    func testALineFromSomeoneIgnoredSinceIsStillTheReplyWithoutTheirWords() {
        var state = ChatState()
        state.ignores = IgnoreSet(global: [IgnoreRule(id: 1, mask: "alice!*@*")], byNetwork: [:])
        state.seedDrafts([entry(body: "", reply: DraftReply(messageId: 7, addressed: false, parent: alice))])
        XCTAssertEqual(state.drafts[chat.id]?.reply?.messageId, 7)
        XCTAssertEqual(state.drafts[chat.id]?.reply?.nick, "alice")
        XCTAssertEqual(state.drafts[chat.id]?.reply?.text, "")
    }

    func testAClosedBufferTakesItsDraft() {
        var state = ChatState()
        state.drafts[chat.id] = ComposerDraft(body: "x")
        state = LurkerStore.reduce(state, .bufferClosed(networkId: 1, target: "#chat"))
        XCTAssertNil(state.drafts[chat.id])
    }

    func testADeletedNetworkTakesItsDraftsAndOnlyItsDrafts() {
        var state = ChatState()
        state.drafts[chat.id] = ComposerDraft(body: "x")
        let eleven = BufferKey(networkId: 11, target: "#chat")
        state.drafts[eleven.id] = ComposerDraft(body: "y")
        state.dropNetwork(1)
        XCTAssertNil(state.drafts[chat.id])
        XCTAssertNotNil(state.drafts[eleven.id], "network 11 is not network 1")
    }

    func testARenameCarriesTheDraft() {
        var state = ChatState()
        let old = BufferKey(networkId: 1, target: "bob")
        state.buffers[old.id] = Buffer(networkId: 1, target: "bob", kind: .dm)
        state.drafts[old.id] = ComposerDraft(body: "you there?")
        state = LurkerStore.reduce(state, .bufferRenamed(
            networkId: 1, from: "bob", to: "bobby", bufferId: nil, merged: false, mergedFromBufferId: nil
        ))
        XCTAssertNil(state.drafts[old.id])
        XCTAssertEqual(state.drafts[BufferKey(networkId: 1, target: "bobby").id]?.body, "you there?")
    }

    func testARenameCarriesADraftWhoseRowHasntArrived() {
        var state = ChatState()
        let old = BufferKey(networkId: 1, target: "bob")
        state.drafts[old.id] = ComposerDraft(body: "seeded before the backlog")
        state = LurkerStore.reduce(state, .bufferRenamed(
            networkId: 1, from: "bob", to: "bob_", bufferId: 5, merged: false, mergedFromBufferId: nil
        ))
        XCTAssertNil(state.drafts[old.id])
        XCTAssertEqual(state.drafts[BufferKey(networkId: 1, target: "bob_").id]?.body, "seeded before the backlog")
    }

    func testAMergeKeepsTheSurvivorsDraft() {
        // The renamed buffer survives; the one that already held the name is absorbed. The server
        // keeps the survivor's draft and sends a draft-updated if that changed anything.
        var state = ChatState()
        let survivor = BufferKey(networkId: 1, target: "bob")
        let absorbed = BufferKey(networkId: 1, target: "bobby")
        state.buffers[survivor.id] = Buffer(networkId: 1, target: "bob", kind: .dm)
        state.buffers[absorbed.id] = Buffer(networkId: 1, target: "bobby", kind: .dm)
        state.drafts[survivor.id] = ComposerDraft(body: "survivor's")
        state.drafts[absorbed.id] = ComposerDraft(body: "absorbed")
        state = LurkerStore.reduce(state, .bufferRenamed(
            networkId: 1, from: "bob", to: "bobby", bufferId: 5, merged: true, mergedFromBufferId: 6
        ))
        XCTAssertEqual(state.drafts[absorbed.id]?.body, "survivor's")
    }

    // MARK: - DraftSync

    func testAnEditIsProtectedUntilItIsTaken() {
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "a"), composing: false)
        XCTAssertTrue(sync.isProtected(chat.id))
        XCTAssertEqual(sync.take(chat.id)?.draft.body, "a")
        XCTAssertFalse(sync.isProtected(chat.id))
    }

    func testACompositionHoldsTheFlushAndStaysProtectedAfterIt() {
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "nihao"), composing: true)
        XCTAssertTrue(sync.defersFlush(chat.id), "raw preedit never becomes the draft everyone sees")
        XCTAssertEqual(sync.flushableIds, [])
        XCTAssertEqual(sync.endComposition(), chat, "the deferred flush is due now")
        XCTAssertFalse(sync.defersFlush(chat.id))
        XCTAssertTrue(sync.isProtected(chat.id), "and its edit still waits")
    }

    func testCommittingInAnotherBufferLeavesTheCompositionAlone() {
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "ni"), composing: true)
        sync.edit(BufferKey(networkId: 1, target: "#other"), ComposerDraft(body: "x"), composing: false)
        XCTAssertTrue(sync.defersFlush(chat.id))
    }

    func testAnEditThatFoundNoSocketWaitsUnlessANewerOneReplacedIt() {
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "first"), composing: false)
        let first = sync.take(chat.id)!
        sync.restore(first)
        XCTAssertEqual(sync.local(chat.id)?.body, "first")

        let again = sync.take(chat.id)!
        sync.edit(chat, ComposerDraft(body: "second"), composing: false)
        sync.restore(again)
        XCTAssertEqual(sync.local(chat.id)?.body, "second", "the older write never wins")
        sync.settle(again)
        XCTAssertEqual(sync.local(chat.id)?.body, "second", "nor does settling it take the newer one away")
    }

    func testARenameMovesTheEditAndTheRenamedBufferWins() {
        var sync = DraftSync()
        let from = BufferKey(networkId: 1, target: "bob")
        let to = BufferKey(networkId: 1, target: "bobby")
        sync.edit(from, ComposerDraft(body: "moving"), composing: true)
        sync.rekey(from: from, to: to)
        XCTAssertNil(sync.local(from.id))
        XCTAssertEqual(sync.take(to.id)?.key, to, "the flush names the buffer as it's called now")
        XCTAssertTrue(sync.defersFlush(to.id), "the composition followed")

        // On a merge the renamed buffer survives and the server keeps its draft (lurker
        // renameBuffer.ts) — the absorbed buffer's is adopted only when it has none.
        var merge = DraftSync()
        merge.edit(from, ComposerDraft(body: "the live conversation"), composing: false)
        merge.edit(to, ComposerDraft(body: "absorbed"), composing: false)
        merge.rekey(from: from, to: to)
        XCTAssertEqual(merge.local(to.id)?.body, "the live conversation")

        var adopt = DraftSync()
        adopt.edit(to, ComposerDraft(body: "absorbed"), composing: false)
        adopt.rekey(from: from, to: to)
        XCTAssertEqual(adopt.local(to.id)?.body, "absorbed")
    }

    func testALateFailureNeverPutsBackAnOlderEdit() {
        // ⚠⚠ Edit A goes to a dying socket; B goes out on the next one; A's write then fails.
        // Put back, A would go out after B on the next snapshot and overwrite it.
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "A"), composing: false)
        let a = sync.take(chat.id)!
        sync.edit(chat, ComposerDraft(body: "B"), composing: false)
        _ = sync.take(chat.id)!
        sync.restore(a)
        XCTAssertNil(sync.local(chat.id))
        XCTAssertFalse(sync.isProtected(chat.id))
    }

    func testAnEditSentBeforeTheSnapshotOutranksIt() {
        // ⚠⚠ A socket still connecting takes the write, but the server builds the snapshot first.
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "hello"), composing: false)
        sync.sentBeforeSnapshot(sync.take(chat.id)!)
        XCTAssertFalse(sync.isProtected(chat.id), "nothing is waiting until the snapshot")
        sync.requeueAwaitingSnapshot()
        XCTAssertEqual(sync.local(chat.id)?.body, "hello", "kept over the snapshot, and sent again")
        sync.requeueAwaitingSnapshot()
        _ = sync.take(chat.id)
        sync.requeueAwaitingSnapshot()
        XCTAssertNil(sync.local(chat.id), "only the snapshot it raced")
    }

    func testAnEditSentBeforeTheSnapshotYieldsToNewerWords() {
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "old"), composing: false)
        sync.sentBeforeSnapshot(sync.take(chat.id)!)
        sync.superseded(chat.id)
        sync.requeueAwaitingSnapshot()
        XCTAssertNil(sync.local(chat.id), "another device wrote after it")

        sync.edit(chat, ComposerDraft(body: "old"), composing: false)
        sync.sentBeforeSnapshot(sync.take(chat.id)!)
        sync.edit(chat, ComposerDraft(body: "new"), composing: false)
        _ = sync.take(chat.id)
        sync.requeueAwaitingSnapshot()
        XCTAssertNil(sync.local(chat.id), "nor over this device's own newer edit")
    }

    func testTakingEverythingIncludesWhatTheConnectingSocketTook() {
        // Backgrounding or signing out before the snapshot: the connecting socket's write may
        // never have been read, so the HTTP flush has to carry it.
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "sent while connecting"), composing: false)
        sync.sentBeforeSnapshot(sync.take(chat.id)!)
        let other = BufferKey(networkId: 1, target: "#other")
        sync.edit(other, ComposerDraft(body: "waiting"), composing: true)
        let taken = sync.takeAll()
        XCTAssertEqual(Set(taken.map(\.draft.body)), ["sent while connecting", "waiting"])
        sync.requeueAwaitingSnapshot()
        XCTAssertNil(sync.local(chat.id), "taken, not left behind to go out twice")

        // A rename can leave one buffer in both; the newer edit is the one that goes.
        var both = DraftSync()
        let from = BufferKey(networkId: 1, target: "bob")
        let to = BufferKey(networkId: 1, target: "bobby")
        both.edit(to, ComposerDraft(body: "older"), composing: false)
        both.sentBeforeSnapshot(both.take(to.id)!)
        both.edit(from, ComposerDraft(body: "newer"), composing: false)
        both.rekey(from: from, to: to)
        XCTAssertEqual(both.takeAll().map(\.draft.body), ["newer"])
    }

    func testAWriteStillInFlightIsCarriedByTheBackgroundFlush() {
        // ⚠⚠ Queued on the socket, not yet out: suspension or sign-out's close() can cancel it,
        // so the HTTP flush has to carry it.
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "on the wire"), composing: false)
        let edit = sync.take(chat.id)!
        sync.sending(edit)
        XCTAssertEqual(sync.takeAll().map(\.draft.body), ["on the wire"])
        sync.completed(seq: edit.seq, ok: false)
        XCTAssertNil(sync.local(chat.id), "the flush took it; a late failure finds nothing to put back")
    }

    func testAFailedWriteComesBackUnderTheBuffersNewName() {
        var sync = DraftSync()
        let from = BufferKey(networkId: 1, target: "bob")
        let to = BufferKey(networkId: 1, target: "bobby")
        sync.edit(from, ComposerDraft(body: "x"), composing: false)
        let edit = sync.take(from.id)!
        sync.sending(edit)
        sync.rekey(from: from, to: to)
        sync.completed(seq: edit.seq, ok: false)
        XCTAssertEqual(sync.take(to.id)?.key, to)
        XCTAssertNil(sync.local(from.id))
    }

    func testACompletedWriteIsDone() {
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "x"), composing: false)
        let edit = sync.take(chat.id)!
        sync.sending(edit)
        sync.completed(seq: edit.seq, ok: true)
        XCTAssertTrue(sync.takeAll().isEmpty)
    }

    func testAWriteOnItsWayOutOutranksTheServer() {
        // Anything the server sends before our write leaves was built before it read it.
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "x"), composing: false)
        let edit = sync.take(chat.id)!
        sync.sending(edit)
        XCTAssertTrue(sync.isProtected(chat.id))
        XCTAssertTrue(sync.protectedIds.contains(chat.id))
        sync.completed(seq: edit.seq, ok: true)
        XCTAssertFalse(sync.isProtected(chat.id))
    }

    func testAMergeDecidesOnceAcrossEveryMap() {
        // ⚠⚠ The survivor's edit is in flight, the absorbed one's waits: resolved per map, both
        // stayed, and the absorbed one could win a takeAll.
        let from = BufferKey(networkId: 1, target: "bob")
        let to = BufferKey(networkId: 1, target: "bobby")
        var sync = DraftSync()
        sync.edit(from, ComposerDraft(body: "survivor"), composing: false)
        sync.sending(sync.take(from.id)!)
        sync.edit(to, ComposerDraft(body: "absorbed"), composing: false)
        sync.rekey(from: from, to: to)
        XCTAssertNil(sync.local(to.id), "the absorbed edit is gone")
        XCTAssertEqual(sync.takeAll().map(\.draft.body), ["survivor"])
    }

    func testAnAdoptedEditCanStillBePutBack() {
        // The source has nothing pending: the absorbed buffer's in-flight edit stays, and its
        // failure still restores — the source's stale `latest` must not replace its own.
        let from = BufferKey(networkId: 1, target: "bob")
        let to = BufferKey(networkId: 1, target: "bobby")
        var sync = DraftSync()
        sync.edit(to, ComposerDraft(body: "absorbed"), composing: false)
        let absorbed = sync.take(to.id)!
        sync.sending(absorbed)
        sync.edit(from, ComposerDraft(body: "sent long ago"), composing: false)
        let old = sync.take(from.id)!
        sync.sending(old)
        sync.completed(seq: old.seq, ok: true)
        sync.rekey(from: from, to: to)
        sync.completed(seq: absorbed.seq, ok: false)
        XCTAssertEqual(sync.local(to.id)?.body, "absorbed")
    }

    func testADeletedNetworksEditsGo() {
        var sync = DraftSync()
        sync.edit(chat, ComposerDraft(body: "x"), composing: false)
        let eleven = BufferKey(networkId: 11, target: "#chat")
        sync.edit(eleven, ComposerDraft(body: "y"), composing: false)
        sync.dropNetworks(keeping: [11])
        XCTAssertNil(sync.local(chat.id))
        XCTAssertNotNil(sync.local(eleven.id))
    }

    func testACaseOnlyRenameRenamesTheFlush() {
        var sync = DraftSync()
        sync.edit(BufferKey(networkId: 1, target: "bob"), ComposerDraft(body: "x"), composing: false)
        let to = BufferKey(networkId: 1, target: "Bob")
        sync.rekey(from: BufferKey(networkId: 1, target: "bob"), to: to)
        XCTAssertEqual(sync.take(to.id)?.key.target, "Bob")
    }

    // MARK: - The view model

    /// Its own Keychain service and its own defaults suite, so nothing here touches the app's.
    private func viewModel() -> ChatViewModel {
        ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.drafts"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.drafts")!)
        )
    }

    func testAnEditOutranksTheServerUntilItGoesOut() {
        let model = viewModel()
        model.editDraft(chat, ComposerDraft(body: "typing"))
        model.handle(.draftUpdated(entry(body: "from the browser")))
        model.handle(.draftSnapshot([entry(body: "from the snapshot")]))
        XCTAssertEqual(model.draft(for: chat)?.body, "typing")
        XCTAssertTrue(model.isDraftProtected(chat))
    }

    func testAFlushWithNoSocketKeepsTheEditForTheNextConnect() {
        // ⚠⚠ Without the hold, the reconnect's snapshot would put the server's older copy back
        // over what was typed while offline.
        let model = viewModel()
        model.editDraft(chat, ComposerDraft(body: "written offline"))
        model.flushDraft(chat)
        XCTAssertEqual(model.state.drafts[chat.id]?.body, "written offline", "the pencil shows it at once")
        XCTAssertTrue(model.isDraftProtected(chat))
        model.handle(.draftSnapshot([entry(body: "older")]))
        XCTAssertEqual(model.draft(for: chat)?.body, "written offline")
        XCTAssertEqual(model.state.drafts[chat.id]?.body, "written offline")
    }

    func testAnotherDevicesWriteLandsWhenNothingHereIsNewer() {
        let model = viewModel()
        model.handle(.draftUpdated(entry(body: "from the browser")))
        XCTAssertEqual(model.draft(for: chat)?.body, "from the browser")
        XCTAssertFalse(model.isDraftProtected(chat))
    }

    func testTheSystemBufferAndServerLogsKeepNoDraft() {
        let model = viewModel()
        model.editDraft(BufferKey(networkId: nil, target: ":system:"), ComposerDraft(body: "/help"))
        model.editDraft(BufferKey(networkId: 1, target: ":server:1"), ComposerDraft(body: "/quote x"))
        XCTAssertNil(model.draft(for: BufferKey(networkId: nil, target: ":system:")))
        XCTAssertNil(model.draft(for: BufferKey(networkId: 1, target: ":server:1")))
    }

    func testClosingABufferDropsItsWaitingEdit() {
        let model = viewModel()
        model.editDraft(chat, ComposerDraft(body: "x"))
        model.handle(.bufferClosed(networkId: 1, target: "#chat"))
        XCTAssertNil(model.draft(for: chat))
        XCTAssertFalse(model.isDraftProtected(chat))
    }

    func testARenameCarriesTheWaitingEdit() {
        let model = viewModel()
        let from = BufferKey(networkId: 1, target: "bob")
        let to = BufferKey(networkId: 1, target: "bobby")
        model.editDraft(from, ComposerDraft(body: "x"))
        model.handle(.bufferRenamed(networkId: 1, from: "bob", to: "bobby", bufferId: nil, merged: false, mergedFromBufferId: nil))
        XCTAssertEqual(model.draft(for: to)?.body, "x")
        XCTAssertNil(model.draft(for: from))
    }
}

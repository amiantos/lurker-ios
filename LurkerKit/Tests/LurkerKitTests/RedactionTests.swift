// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// Message redaction (lurker#1013 / #1277): the wire, the side map, the placeholder, and what a
/// deleted line stops offering.
@MainActor
final class RedactionTests: XCTestCase {

    private let key = BufferKey(networkId: 1, target: "#lurker")
    private let mark = Redaction(by: "alice", reason: nil, time: "2026-11-05T00:00:00Z")

    private func line(
        _ id: Int, nick: String = "alice", text: String? = "hi", isSelf: Bool = false, msgid: String? = "m",
        redaction: Redaction? = nil, reactions: [MessageReaction]? = nil, replyTo: ReplyContext? = nil
    ) -> Message {
        Message(
            id: id, type: .message, nick: nick, text: text, isSelf: isSelf, msgid: msgid,
            reactions: reactions, replyTo: replyTo, redaction: redaction
        )
    }

    private func backlog(_ messages: [Message], networkId: Int? = 1, target: String = "#lurker") -> ServerFrame {
        .backlog(
            buffer: Buffer(networkId: networkId, target: target, kind: .channel, hydrated: true),
            messages: messages, hydrated: true, append: false, speakers: nil
        )
    }

    private func redacted(_ id: Int, by: String = "alice", reason: String? = nil, target: String = "#lurker") -> ServerFrame {
        .messageRedacted(MessageRedacted(
            networkId: 1, target: target, messageId: id, by: by, reason: reason, time: "2026-11-05T00:00:00Z"
        ))
    }

    // MARK: - Wire

    func testADeletedRowParsesItsMarkBesideANullText() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","hasMoreOlder":false,"events":[{"id":1,"type":"message","nick":"alice","text":null,"msgid":"m","redaction":{"by":"Bob","reason":"spam","time":"2026-11-05T00:00:00Z"}},{"id":2,"type":"message","nick":"alice","text":"hi"}]}"##
        )
        guard case let .backlog(_, messages, _, _, _) = frame else { return XCTFail("\(frame)") }
        XCTAssertNil(messages[0].text)
        XCTAssertEqual(messages[0].redaction, Redaction(by: "Bob", reason: "spam", time: "2026-11-05T00:00:00Z"))
        XCTAssertTrue(messages[0].isRenderable, "no words, still a row to show")
        XCTAssertNil(messages[1].redaction, "absent on every line that wasn't deleted")
    }

    func testTheFrameParsesAndNeedsALineAndANetwork() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"message-redacted","networkId":1,"bufferId":9,"target":"#lurker","messageId":42,"by":"bob","reason":"oops","self":true,"time":"2026-11-05T00:00:00Z"}"##
        )
        XCTAssertEqual(frame, .messageRedacted(MessageRedacted(
            networkId: 1, target: "#lurker", messageId: 42, by: "bob", reason: "oops", time: "2026-11-05T00:00:00Z"
        )))
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"message-redacted","networkId":1,"by":"bob"}"##), .ignored)
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"message-redacted","messageId":4,"by":"bob"}"##), .ignored)
    }

    func testAReplyParentCarriesItsDeletion() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","hasMoreOlder":false,"events":[{"id":2,"type":"message","nick":"bob","text":"alice: why","msgid":"r","replyTo":{"msgid":"m","parent":{"id":1,"nick":"alice","type":"message","text":"","redacted":true}}}]}"##
        )
        guard case let .backlog(_, messages, _, _, _) = frame else { return XCTFail("\(frame)") }
        XCTAssertEqual(messages[0].replyTo?.parent?.redacted, true)
    }

    func testTheSyncAnswerNamesDeletions() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"reactions-sync","messageIds":[1,2],"reactions":{},"redactions":{"2":{"by":"op","time":"2026-11-05T00:00:00Z"}}}"##
        )
        XCTAssertEqual(frame, .reactionsSync(
            messageIds: [1, 2], reactions: [:], redactions: [2: Redaction(by: "op", time: "2026-11-05T00:00:00Z")]
        ))
    }

    /// `canRedact` is newer than the split, so an old server's `canReact` never stands for it.
    func testCanRedactHasNoLegacyFallback() {
        func support(_ fields: String) -> TagSupport? {
            let frame = FrameParser.parseWs(
                #"{"kind":"irc","type":"react-support","networkId":3,"target":":server:3""# + fields + "}")
            guard case let .reactSupport(_, support) = frame else { XCTFail("\(frame)"); return nil }
            return support
        }
        XCTAssertEqual(support(#","canReact":true"#)?.canRedact, false)
        XCTAssertEqual(support(#","canReact":true,"canRedact":true"#)?.canRedact, true)
        XCTAssertEqual(support(#","canRedact":true"#)?.canAddReaction, false, "and it stands alone")
    }

    // MARK: - The placeholder

    func testTheLabelNamesTheDeleterOnlyWhenItIsntTheAuthor() {
        XCTAssertEqual(Redaction(by: "alice").label(authorNick: "alice"), "message deleted")
        XCTAssertEqual(Redaction(by: "ALICE").label(authorNick: "alice"), "message deleted", "case-insensitive on the nick")
        XCTAssertEqual(Redaction(by: "op").label(authorNick: "alice"), "message deleted by op")
        XCTAssertEqual(Redaction(by: "op", reason: "spam").label(authorNick: "alice"), "message deleted by op: spam")
        XCTAssertEqual(Redaction(by: "alice", reason: "typo").label(authorNick: "alice"), "message deleted: typo")
        XCTAssertEqual(Redaction(by: "").label(authorNick: "alice"), "message deleted", "a mark with no deleter names nobody")
    }

    func testDeletedTakesTheWordsAndWhatCopyWouldRead() {
        let reply = line(2, nick: "bob", text: "alice: why").showingReply(quote: nil, text: "why")
        let gone = reply.deleted(mark)
        XCTAssertNil(gone.text)
        XCTAssertNil(gone.copyText)
        XCTAssertEqual(gone.redaction, mark)
        XCTAssertEqual(gone.id, 2)
        XCTAssertEqual(gone.nick, "bob")
        XCTAssertTrue(gone.isRenderable)
    }

    // MARK: - Side map

    func testARowSeedsTheMapAndIsAuthoritativeForItself() {
        let store = LurkerStore()
        store.apply(backlog([line(1, text: nil, redaction: mark), line(2)]))
        XCTAssertEqual(store.state.redaction(for: line(1), networkId: 1), mark)
        XCTAssertNil(store.state.redaction(for: line(2), networkId: 1))
        // Shown: the mark rides the line, the words don't.
        let shown = Redactions.presenting(store.state.messages[key.id] ?? [], redactions: store.state.redactions)
        XCTAssertEqual(shown.map(\.redaction), [mark, nil])
    }

    func testTheFrameMarksAHeldLineAndTakesItsReactionsDown() {
        let store = LurkerStore()
        let thumbs = MessageReaction(nick: "bob", value: "👍", isSelf: false)
        store.apply(backlog([line(1, reactions: [thumbs]), line(2)]))
        let before = store.state.reactionsRevision(for: key)
        store.apply(redacted(1, by: "op", reason: "spam"))

        let shown = Redactions.presenting(store.state.messages[key.id] ?? [], redactions: store.state.redactions)
        XCTAssertNil(shown[0].text, "the words are gone at render")
        XCTAssertEqual(shown[0].redaction?.label(authorNick: "alice"), "message deleted by op: spam")
        XCTAssertEqual(shown[1].text, "hi", "its neighbour is untouched")
        XCTAssertTrue(store.state.reactionGroups(for: 1).isEmpty, "the server tombstoned them; so does the view")
        XCTAssertNotEqual(store.state.reactionsRevision(for: key), before, "the screen's gate lets it through")
        XCTAssertEqual(store.state.messages[key.id]?[0].text, "hi", "the stored row is never patched")
    }

    /// The feeds show lines outside any buffer, so a mark for one is kept — but only a buffer that
    /// holds the line is told to redraw.
    func testAFrameForALineNobodyHoldsIsKeptWithoutARedraw() {
        let store = LurkerStore()
        store.apply(backlog([line(1)]))
        let before = store.state.reactionsRevision(for: key)
        store.apply(redacted(7))
        XCTAssertEqual(store.state.redactions[7], mark, "a bookmark or a search hit can show it")
        XCTAssertEqual(store.state.reactionsRevision(for: key), before, "nothing on this screen changed")
        store.apply(redacted(1, target: "#other"))
        XCTAssertEqual(store.state.redactions[1], mark)
        XCTAssertEqual(store.state.reactionsRevision(for: key), before, "the frame named another buffer")
    }

    /// A page read before the REDACT landed can arrive after the frame that applied it.
    func testAStalePageNeverUndeletesALine() {
        let store = LurkerStore()
        store.apply(backlog([line(1)]))
        store.apply(redacted(1))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [line(1)], mode: .around,
            hasMoreOlder: false, hasMoreNewer: false, speakers: nil
        ))
        XCTAssertEqual(store.state.redaction(for: line(1), networkId: 1), mark, "a deletion is for good")
    }

    func testTheSyncAnswerDeletesWhatItNames() {
        let store = LurkerStore()
        store.apply(backlog([line(1), line(2)]))
        let before = store.state.reactionsRevision(for: key)
        store.apply(.reactionsSync(messageIds: [1, 2], reactions: [1: [MessageReaction(nick: "bob", value: "👍", isSelf: false)]], redactions: [2: mark]))
        XCTAssertNil(store.state.redaction(for: line(1), networkId: 1))
        XCTAssertEqual(store.state.redaction(for: line(2), networkId: 1), mark)
        XCTAssertTrue(store.state.reactionGroups(for: 2).isEmpty)
        XCTAssertEqual(store.state.reactionGroups(for: 1).count, 1, "its neighbour keeps its chips")
        XCTAssertNotEqual(store.state.reactionsRevision(for: key), before)
    }

    func testPresentingReturnsTheSameListWhenNothingInItIsDeleted() {
        let lines = [line(1), line(2)]
        let shown = Redactions.presenting(lines, redactions: [9: mark])
        XCTAssertTrue(shown.withUnsafeBufferPointer { a in lines.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } }
            || shown == lines)
        XCTAssertEqual(Redactions.presenting([line(1, text: nil, redaction: mark)], redactions: [:]).first?.text, nil)
    }

    /// A bookmark or a search hit can still be showing the line after its buffer closes.
    func testClosingABufferKeepsItsMarks() {
        let store = LurkerStore()
        store.apply(backlog([line(1)]))
        store.apply(redacted(1))
        store.apply(.bufferClosed(networkId: 1, target: "#lurker"))
        XCTAssertEqual(store.state.redactions[1], mark)
    }

    /// A page read before the REDACT landed can put the line's reactions back in the map; none
    /// are drawn for a line known to be deleted.
    func testAStalePageNeverRestoresADeletedLinesChips() {
        let store = LurkerStore()
        let thumbs = MessageReaction(nick: "bob", value: "👍", isSelf: false)
        store.apply(backlog([line(1, reactions: [thumbs])]))
        store.apply(redacted(1))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [line(1, reactions: [thumbs])], mode: .around,
            hasMoreOlder: false, hasMoreNewer: false, speakers: nil
        ))
        XCTAssertTrue(store.state.reactionGroups(for: 1).isEmpty)
    }

    /// The feeds read rows over REST; a deleted one they carry marks the line everywhere.
    func testAFeedRowSeedsTheMark() {
        let store = LurkerStore()
        store.apply(backlog([line(1)]))
        store.noteRedactions(from: [line(1, text: nil, redaction: mark), line(2)])
        XCTAssertEqual(store.state.redaction(for: line(1), networkId: 1), mark)
        XCTAssertNil(store.state.redactions[2])
    }

    func testSystemRowsNeverTouchTheMap() {
        let store = LurkerStore()
        store.apply(.backlog(
            buffer: Buffer(networkId: nil, target: ":system:", kind: .system, hydrated: true),
            messages: [line(1, text: nil, redaction: mark)], hydrated: true, append: false, speakers: nil
        ))
        XCTAssertTrue(store.state.redactions.isEmpty)
    }

    // MARK: - Replies

    private func shown(_ reply: Message, redactions: [Int: Redaction] = [:]) -> ReplyQuote? {
        Replies.shown(
            reply.replyTo!, line: reply, networkId: 1, target: "#lurker",
            ignores: IgnoreSet(global: [], byNetwork: [:]), relayBots: RelayBotSet(), ownNick: "me",
            redactions: redactions
        ).quote
    }

    func testTheQuoteOfADeletedLineReadsAsDeletedNotUnavailable() {
        let parent = ReplyParent(id: 1, nick: "alice", type: .message, text: "", redacted: true)
        let reply = line(2, nick: "bob", text: "alice: why", replyTo: ReplyContext(msgid: "m", parent: parent))
        let quote = shown(reply)
        XCTAssertEqual(quote?.redacted, true)
        XCTAssertEqual(quote?.id, 1, "still jumps")
        XCTAssertEqual(quote?.nick, "alice")
    }

    /// The answered line deleted while this reply was on screen: the quote copied its words; the
    /// store knows they're gone.
    func testTheStoreOverridesAQuoteThatStillHoldsTheWords() {
        let parent = ReplyParent(id: 1, nick: "alice", type: .message, text: "secret")
        let reply = line(2, nick: "bob", text: "alice: why", replyTo: ReplyContext(msgid: "m", parent: parent))
        XCTAssertEqual(shown(reply)?.redacted, false)
        let quote = shown(reply, redactions: [1: mark])
        XCTAssertEqual(quote?.redacted, true)
        XCTAssertEqual(quote?.text, "", "the words don't leak through the quote")
    }

    /// A bridged line deleted while on screen still quotes the person inside its envelope, as its
    /// own row does.
    func testADeletedRelayedParentKeepsItsSpeaker() {
        let parent = ReplyParent(id: 1, nick: "bridge", type: .message, text: "<alice> secret")
        let reply = line(2, nick: "bob", text: "alice: why", replyTo: ReplyContext(msgid: "m", parent: parent))
        let quote = Replies.shown(
            reply.replyTo!, line: reply, networkId: 1, target: "#lurker",
            ignores: IgnoreSet(global: [], byNetwork: [:]), relayBots: RelayBotSet(byNetwork: [1: [RelayBot(nick: "bridge")]]),
            ownNick: "me", redactions: [1: mark]
        ).quote
        XCTAssertEqual(quote?.nick, "alice")
        XCTAssertEqual(quote?.relayBot, "bridge")
        XCTAssertEqual(quote?.redacted, true)
        XCTAssertEqual(quote?.text, "")
    }

    // MARK: - Actions

    private func scope(
        target: String = "#lurker", canRedact: Bool = true, moderating: Bool = false
    ) -> MessageActionScope {
        MessageActionScope(
            networkId: 1, isBookmarked: false, target: target,
            support: TagSupport(canAddReaction: true, canRemoveReaction: true, canReply: true, canRedact: canRedact),
            moderating: moderating
        )
    }

    private func keys(_ message: Message, _ scope: MessageActionScope) -> [MessageActionKey] {
        MessageActions.build(for: message, scope: scope).map(\.key)
    }

    func testADeletedLineOffersOnlyWhatNeedsNoWords() {
        let gone = line(1).deleted(mark)
        XCTAssertEqual(keys(gone, scope()), [.bookmark, .profile], "no reply, react, copy — or a second delete")
        XCTAssertNil(MessageActions.replyAction(for: gone, target: "#lurker", canReply: true), "so the swipe doesn't move either")
        XCTAssertFalse(Reactions.lineTakes(gone, target: "#lurker"))
    }

    func testDeleteIsOfferedOnYourOwnLineWhereTheNetworkTakesIt() {
        let mine = line(1, isSelf: true)
        XCTAssertEqual(keys(mine, scope()), [.reply, .react, .copy, .bookmark, .delete, .profile])
        XCTAssertFalse(keys(mine, scope(canRedact: false)).contains(.delete), "not without the cap")
        XCTAssertFalse(keys(line(1, isSelf: true, msgid: nil), scope()).contains(.delete), "a REDACT names a msgid")
        XCTAssertFalse(keys(line(0, isSelf: true), scope()).contains(.delete), "an ephemeral line has no row")
        XCTAssertTrue(keys(mine, scope(target: "bob")).contains(.delete), "your own line in a DM too")
        XCTAssertFalse(keys(mine, scope(target: ":server:")).contains(.delete), "not the console")
    }

    func testDeleteOnSomeoneElsesLineNeedsAPrefixModeInAChannel() {
        let theirs = line(1)
        XCTAssertFalse(keys(theirs, scope()).contains(.delete))
        XCTAssertTrue(keys(theirs, scope(moderating: true)).contains(.delete))
        XCTAssertFalse(keys(theirs, scope(target: "alice", moderating: true)).contains(.delete), "no modes in a DM")
    }

    func testRunDeleteHandsTheLineToTheScreenAndNothingElse() {
        var deleted: [Int] = []
        var copied: [String] = []
        let context = MessageActionContext(
            reply: { _ in XCTFail("not a reply") }, copy: { copied.append($0) },
            setBookmark: { _, _ in XCTFail("not a bookmark") }, showProfile: { _ in XCTFail("not a profile") },
            delete: { deleted.append($0.id) }
        )
        MessageActions.run(.delete, on: line(1, isSelf: true), scope: scope(), context: context)
        XCTAssertEqual(deleted, [1])
        // Not offered on their line here, so a stale menu's Delete is a no-op.
        MessageActions.run(.delete, on: line(2), scope: scope(), context: context)
        XCTAssertEqual(deleted, [1])
        // And Copy on a deleted line copies nothing.
        MessageActions.run(.copy, on: line(3).deleted(mark), scope: scope(), context: context)
        XCTAssertTrue(copied.isEmpty)
    }

    func testModeratingReadsYourOwnModesInTheChannel() {
        let store = LurkerStore()
        store.apply(.snapshot([NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [])],
                              globalIgnores: [], uploadLimits: .unstated))
        store.apply(.channelMembers(networkId: 1, target: "#lurker", members: [Member(nick: "Me", modes: ["o"]), Member(nick: "alice")]))
        XCTAssertTrue(store.state.moderates(in: key), "case-folded against your nick")
        store.apply(.channelMembers(networkId: 1, target: "#lurker", members: [Member(nick: "me"), Member(nick: "alice", modes: ["o"])]))
        XCTAssertFalse(store.state.moderates(in: key), "someone else's op isn't yours")
        XCTAssertFalse(store.state.moderates(in: BufferKey(networkId: 1, target: "alice")), "never in a DM")
    }

    /// `/react` lands on the last line someone else said; when that one was deleted, it says why.
    func testReactCommandRefusesADeletedLine() {
        let result = Reactions.commandTarget(in: [line(1), line(2).deleted(mark)])
        XCTAssertEqual(result, .failure(Reactions.CommandRefusal("can't react to a deleted message")))
    }

    // MARK: - Through the view model

    private func model() -> ChatViewModel {
        let model = ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.redaction"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.redaction")!)
        )
        model.handle(.socketOpen)
        model.handle(.snapshot(
            [NetworkSnapshot(id: 1, state: .connected, nick: "me",
                             channels: [ChannelSnapshot(name: "#lurker", topic: nil, members: [])],
                             tagSupport: TagSupport(canAddReaction: true, canRemoveReaction: true, canReply: true, canRedact: true))],
            globalIgnores: [], uploadLimits: .unstated
        ))
        return model
    }

    private func lastLocal(_ model: ChatViewModel) -> String? {
        model.state.messages[key.id]?.last(where: { $0.id == 0 })?.text
    }

    /// The stored rows carry no mark, so the command has to look at the lines as shown.
    func testReactCommandSkipsALineDeletedWhileHeld() {
        let model = model()
        var sent: [String] = []
        model.reactSeam = { id, value, _ in sent.append("\(id) \(value)"); return true }
        model.handle(backlog([line(1, nick: "bob"), line(2, nick: "bob")]))
        model.handle(redacted(2, by: "bob"))
        model.send(key, text: "/react 👍")
        XCTAssertEqual(sent, [])
        XCTAssertEqual(lastLocal(model), "can't react to a deleted message")
    }

    func testReactAndDeleteTakeTheLastLineShownNotTheNewestId() {
        // A filled gap (lurker#1290): ids 3 and 4 were said before 1 and 2, and show above them.
        func said(_ id: Int, _ minute: Int, isSelf: Bool) -> Message {
            Message(
                id: id, type: .message, nick: isSelf ? "me" : "bob", text: "hi", isSelf: isSelf,
                date: Date(timeIntervalSince1970: 1_793_955_600 + TimeInterval(minute * 60)), msgid: "m\(id)"
            )
        }
        let model = model()
        var sent: [String] = []
        model.reactSeam = { id, value, _ in sent.append("react \(id) \(value)"); return true }
        model.redactSeam = { id, _ in sent.append("delete \(id)"); return true }
        model.handle(backlog([
            said(1, 22, isSelf: false), said(2, 23, isSelf: true),
            said(3, 19, isSelf: false), said(4, 20, isSelf: true),
        ]))
        model.send(key, text: "/react 👍")
        model.send(key, text: "/delete")
        XCTAssertEqual(sent, ["react 1 👍", "delete 2"])
    }

    func testDeleteCommandTakesYourNewestStandingLineWithItsReason() {
        let model = model()
        var sent: [String] = []
        model.redactSeam = { id, reason in sent.append("\(id) \(reason ?? "-")"); return true }
        model.handle(backlog([line(1, isSelf: true), line(2, nick: "bob"), line(3, isSelf: true)]))
        model.send(key, text: "/delete")
        model.send(key, text: "/delete  typo  ")
        XCTAssertEqual(sent, ["3 -", "3 typo"])
        // Deleted while held: the next /delete reaches past it.
        model.handle(redacted(3, by: "me"))
        model.send(key, text: "/delete")
        XCTAssertEqual(sent.last, "1 -")
        XCTAssertNil(lastLocal(model), "nothing prints on success")
    }

    func testDeleteCommandSaysWhyWhenItCant() {
        let model = model()
        model.redactSeam = { _, _ in XCTFail("nothing should go out"); return true }
        model.handle(backlog([line(1, nick: "bob")]))
        model.send(key, text: "/delete")
        XCTAssertEqual(lastLocal(model), "nothing of yours here to delete")
        model.handle(backlog([line(1, nick: "bob"), line(2, isSelf: true, msgid: nil)]))
        model.send(key, text: "/delete")
        XCTAssertEqual(lastLocal(model), "can't delete that line (no message id)")
        model.handle(.reactSupport(networkId: 1, support: .all))
        model.send(key, text: "/delete")
        XCTAssertEqual(lastLocal(model), "this network can't delete messages")
    }

    func testDeleteParsesItsOptionalReason() {
        guard case .command(let bare) = CommandParser.parse("/delete", networkId: 1, target: "#lurker"),
              case .command(let reasoned) = CommandParser.parse("/delete  oops ", networkId: 1, target: "#lurker")
        else { return XCTFail("a command") }
        XCTAssertEqual(bare, [.delete(reason: nil)])
        XCTAssertEqual(reasoned, [.delete(reason: "oops")])
    }
}

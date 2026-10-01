// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// IRCv3 reactions (iOS #183): the wire, the side map, and the gates.
@MainActor
final class ReactionsTests: XCTestCase {

    private let chanKey = "1::#lurker"

    private func line(
        _ id: Int, msgid: String? = "m", type: EventType = .message, isSelf: Bool = false,
        isE2E: Bool = false, reactions: [MessageReaction]? = nil
    ) -> Message {
        Message(
            id: id, type: type, nick: "alice", text: "hi", isSelf: isSelf,
            msgid: msgid, isE2E: isE2E, reactions: reactions
        )
    }

    private func backlog(_ messages: [Message], networkId: Int? = 1, target: String = "#lurker") -> ServerFrame {
        .backlog(
            buffer: Buffer(networkId: networkId, target: target, kind: .channel, hydrated: true),
            messages: messages, hydrated: true, append: false, speakers: nil
        )
    }

    private func change(
        _ messageId: Int, _ nick: String, _ value: String, isSelf: Bool = false, remove: Bool = false
    ) -> ServerFrame {
        .reaction(ReactionChange(
            networkId: 1, target: "#lurker", messageId: messageId, nick: nick, value: value,
            isSelf: isSelf, remove: remove, toSelf: false
        ))
    }

    private let thumbs = MessageReaction(nick: "bob", value: "👍", isSelf: false)

    // MARK: - Wire

    func testRowsCarryMsgidE2eAndReactions() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","hasMoreOlder":false,"events":[{"id":1,"type":"message","nick":"a","text":"plain"},{"id":2,"type":"message","nick":"a","text":"x","msgid":"abc","e2e":true,"reactions":[{"nick":"bob","value":"👍","self":false},{"nick":"me","value":"lol","self":true},{"nick":"","value":"?"}]}]}"##
        )
        guard case let .backlog(_, messages, _, _, _) = frame else { return XCTFail("\(frame)") }
        XCTAssertNil(messages[0].msgid)
        XCTAssertNil(messages[0].reactions, "absent means none, not an empty list")
        XCTAssertFalse(messages[0].isE2E)
        XCTAssertEqual(messages[1].msgid, "abc")
        XCTAssertTrue(messages[1].isE2E)
        XCTAssertEqual(messages[1].reactions, [
            MessageReaction(nick: "bob", value: "👍", isSelf: false),
            MessageReaction(nick: "me", value: "lol", isSelf: true),
        ], "an entry with no nick names nobody")
    }

    func testReactionFrameParses() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"reaction","networkId":1,"bufferId":9,"target":"#lurker","messageId":42,"nick":"bob","value":"🎉","self":false,"remove":true,"toSelf":true,"time":"2026-09-30T00:00:00Z"}"##
        )
        XCTAssertEqual(frame, .reaction(ReactionChange(
            networkId: 1, target: "#lurker", messageId: 42, nick: "bob", value: "🎉",
            isSelf: false, remove: true, toSelf: true
        )))
    }

    func testReactionFrameThatAddressesNothingIsIgnored() {
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"reaction","networkId":1,"value":"x"}"##), .ignored)
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"reaction","messageId":4,"value":"x"}"##), .ignored)
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"reaction","networkId":1,"messageId":4,"value":""}"##), .ignored)
    }

    func testReactionsSyncParses() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"reactions-sync","messageIds":[1,2],"reactions":{"1":[{"nick":"bob","value":"👍","self":false}]}}"##
        )
        XCTAssertEqual(frame, .reactionsSync(messageIds: [1, 2], reactions: [1: [thumbs]]))
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"reactions-sync","reactions":{}}"##), .ignored,
                       "with no id list it can't be authoritative about anything")
    }

    func testReactSupportAndSnapshotCanReactParse() {
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"irc","type":"react-support","networkId":3,"target":":server:3","canReact":true}"##),
            .reactSupport(networkId: 3, canReact: true)
        )
        let snapshot = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":3,"state":"connected","nick":"me","channels":[],"canReact":true}]}"##
        )
        guard case let .snapshot(networks, _, _) = snapshot else { return XCTFail("\(snapshot)") }
        XCTAssertTrue(networks[0].canReact)
    }

    // MARK: - Side map

    func testARowIsAuthoritativeForItselfInBothDirections() {
        let store = LurkerStore()
        store.apply(backlog([line(1, reactions: [thumbs]), line(2)]))
        XCTAssertEqual(store.state.reactionGroups(for: 1).map(\.value), ["👍"])
        let key = BufferKey(networkId: 1, target: "#lurker")
        let before = store.state.reactionsRevision(for: key)

        // The same line again with nothing on it: taken back while we weren't listening.
        store.apply(backlog([line(1)]))
        XCTAssertTrue(store.state.reactionGroups(for: 1).isEmpty)
        XCTAssertNotEqual(store.state.reactionsRevision(for: key), before)
    }

    func testSilenceAboutALineIsNotARemoval() {
        let store = LurkerStore()
        store.apply(backlog([line(1, reactions: [thumbs])]))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [line(5)], mode: .before,
            hasMoreOlder: true, hasMoreNewer: false, speakers: nil
        ))
        XCTAssertEqual(store.state.reactionGroups(for: 1).count, 1)
    }

    func testSystemRowsNeverTouchTheMap() {
        let store = LurkerStore()
        store.apply(backlog([line(1, reactions: [thumbs])]))
        // A system-buffer row sharing the id, carrying nothing.
        store.apply(.backlog(
            buffer: Buffer(networkId: nil, target: ":system:", kind: .system, hydrated: true),
            messages: [line(1)], hydrated: true, append: false, speakers: nil
        ))
        XCTAssertEqual(store.state.reactionGroups(for: 1).count, 1)
    }

    func testGroupsKeepFirstReactedOrderAndMarkOurs() {
        let groups = Reactions.groups([
            MessageReaction(nick: "bob", value: "👍", isSelf: false),
            MessageReaction(nick: "carol", value: "lol", isSelf: false),
            MessageReaction(nick: "me", value: "👍", isSelf: true),
        ])
        XCTAssertEqual(groups, [
            ReactionGroup(value: "👍", nicks: ["bob", "me"], mine: true),
            ReactionGroup(value: "lol", nicks: ["carol"], mine: false),
        ])
    }

    func testLiveReactionsAddDedupeAndRemove() {
        let store = LurkerStore()
        store.apply(backlog([line(1)]))
        store.apply(change(1, "bob", "👍"))
        store.apply(change(1, "Bob", "👍")) // same person, server-cased differently
        store.apply(change(1, "carol", "👍"))
        XCTAssertEqual(store.state.reactionGroups(for: 1), [ReactionGroup(value: "👍", nicks: ["bob", "carol"], mine: false)])

        store.apply(change(1, "bob", "👍", remove: true))
        XCTAssertEqual(store.state.reactionGroups(for: 1).first?.nicks, ["carol"])
        store.apply(change(1, "carol", "👍", remove: true))
        XCTAssertNil(store.state.reactions[1], "an emptied line leaves no entry behind")
    }

    /// ⚠⚠ Our own unreact matches by `self`, never by nick: a reaction given under an older nick
    /// is still ours, and matching the nick would leave it standing forever.
    func testOurUnreactMatchesSelfNotNick() {
        let store = LurkerStore()
        store.apply(backlog([line(1, reactions: [MessageReaction(nick: "oldme", value: "👍", isSelf: true), thumbs])]))
        store.apply(change(1, "newme", "👍", isSelf: true, remove: true))
        XCTAssertEqual(store.state.reactionGroups(for: 1), [ReactionGroup(value: "👍", nicks: ["bob"], mine: false)])
    }

    func testAReactionWeAlreadyHoldChangesNothing() {
        let store = LurkerStore()
        store.apply(backlog([line(1, reactions: [thumbs])]))
        let key = BufferKey(networkId: 1, target: "#lurker")
        let revision = store.state.reactionsRevision(for: key)
        store.apply(change(1, "bob", "👍"))
        store.apply(change(1, "nobody", "x", remove: true))
        XCTAssertEqual(store.state.reactionsRevision(for: key), revision, "no change, no redraw")
    }

    func testSyncIsAuthoritativeForEveryIdItNames() {
        let store = LurkerStore()
        store.apply(backlog([line(1, reactions: [thumbs]), line(2, reactions: [thumbs]), line(3)]))
        let lol = MessageReaction(nick: "carol", value: "lol", isSelf: false)
        store.apply(.reactionsSync(messageIds: [1, 3], reactions: [3: [lol]]))
        XCTAssertTrue(store.state.reactionGroups(for: 1).isEmpty, "named, absent = none now")
        XCTAssertEqual(store.state.reactionGroups(for: 2).count, 1, "not named = untouched")
        XCTAssertEqual(store.state.reactionGroups(for: 3).map(\.value), ["lol"])
    }

    func testClosingABufferDropsItsLinesReactions() {
        let store = LurkerStore()
        store.apply(backlog([line(1, reactions: [thumbs])]))
        store.apply(.bufferClosed(networkId: 1, target: "#lurker"))
        XCTAssertNil(store.state.reactions[1])
    }

    func testSyncIdsAreTheNewestOfEachNetworkBuffer() {
        let store = LurkerStore()
        store.apply(backlog((1...(Reactions.syncPerBuffer + 10)).map { line($0) }))
        store.apply(.backlog(
            buffer: Buffer(networkId: nil, target: ":system:", kind: .system, hydrated: true),
            messages: [line(9999)], hydrated: true, append: false, speakers: nil
        ))
        let ids = store.state.reactionSyncIds()
        XCTAssertEqual(ids.count, Reactions.syncPerBuffer)
        XCTAssertEqual(ids.first, Reactions.syncPerBuffer + 10, "newest first")
        XCTAssertFalse(ids.contains(9999), "system lines are another id space")
    }

    // MARK: - canReact

    func testCanReactNeedsTheFlagAndALiveLink() {
        let store = LurkerStore()
        store.apply(.socketOpen)
        store.apply(.snapshot([NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [])],
                              globalIgnores: [], maxUploadBytes: nil))
        XCTAssertFalse(store.state.canReact(networkId: 1), "false until the burst says otherwise")
        store.apply(.reactSupport(networkId: 1, canReact: true))
        XCTAssertTrue(store.state.canReact(networkId: 1))

        // The link drops: whatever the last registration allowed is no answer now…
        store.apply(.networkState(networkId: 1, state: .reconnecting, nick: nil))
        XCTAssertFalse(store.state.canReact(networkId: 1))
        // …and coming back isn't one either until the new burst re-announces it.
        store.apply(.networkState(networkId: 1, state: .connected, nick: nil))
        XCTAssertFalse(store.state.canReact(networkId: 1))
        XCTAssertFalse(store.state.canReact(networkId: nil))
        XCTAssertFalse(store.state.canReact(networkId: 99))
    }

    /// While our own socket is down, the network's last-known state says nothing: whatever we
    /// send goes nowhere.
    func testCanReactNeedsOurOwnSocket() {
        let store = LurkerStore()
        store.apply(.socketOpen)
        store.apply(.snapshot([NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [], canReact: true)],
                              globalIgnores: [], maxUploadBytes: nil))
        XCTAssertTrue(store.state.canReact(networkId: 1))
        store.apply(.socketClosed(reason: nil, code: nil))
        XCTAssertFalse(store.state.canReact(networkId: 1))
    }

    /// ⚠⚠ Someone who takes the nick we reacted under is not us: their reaction is theirs, and
    /// taking theirs back must not take ours.
    func testANickCollisionNeverFoldsIntoOurReaction() {
        let store = LurkerStore()
        store.apply(backlog([line(1, reactions: [MessageReaction(nick: "alice", value: "👍", isSelf: true)])]))
        store.apply(change(1, "alice", "👍"))
        XCTAssertEqual(store.state.reactionGroups(for: 1), [ReactionGroup(value: "👍", nicks: ["alice", "alice"], mine: true)])
        store.apply(change(1, "alice", "👍", remove: true))
        XCTAssertEqual(store.state.reactionGroups(for: 1), [ReactionGroup(value: "👍", nicks: ["alice"], mine: true)])
    }

    func testAReactionToALineNobodyLoadedIsDropped() {
        let store = LurkerStore()
        store.apply(backlog([line(1)]))
        store.apply(change(77, "bob", "👍"))
        XCTAssertNil(store.state.reactions[77], "its row brings its reactions when it's fetched")
        XCTAssertEqual(store.state.reactionsRevision(for: BufferKey(networkId: 1, target: "#lurker")), 0)
    }

    func testARevisionIsPerBuffer() {
        let store = LurkerStore()
        store.apply(backlog([line(1)]))
        store.apply(backlog([line(2)], target: "#other"))
        store.apply(change(1, "bob", "👍"))
        XCTAssertEqual(store.state.reactionsRevision(for: BufferKey(networkId: 1, target: "#lurker")), 1)
        XCTAssertEqual(store.state.reactionsRevision(for: BufferKey(networkId: 1, target: "#other")), 0)
    }

    /// System-buffer ids are another sequence: dropping that buffer must not free network lines'.
    func testDroppingTheSystemBufferLeavesNetworkReactionsAlone() {
        let store = LurkerStore()
        store.apply(backlog([line(1, reactions: [thumbs])]))
        store.apply(.backlog(
            buffer: Buffer(networkId: nil, target: ":system:", kind: .system, hydrated: true),
            messages: [line(1)], hydrated: true, append: false, speakers: nil
        ))
        store.apply(.bufferClosed(networkId: nil, target: ":system:"))
        XCTAssertEqual(store.state.reactionGroups(for: 1).count, 1)
    }

    // MARK: - Gates

    func testValueRules() {
        XCTAssertTrue(Reactions.isValidValue("👍"))
        XCTAssertTrue(Reactions.isValidValue("lol"))
        XCTAssertTrue(Reactions.isValidValue("👨‍👩‍👧‍👦"), "one grapheme, however many scalars")
        XCTAssertFalse(Reactions.isValidValue("  "))
        XCTAssertFalse(Reactions.isValidValue("a\nb"))
        XCTAssertTrue(Reactions.isValidValue(String(repeating: "x", count: 64)))
        XCTAssertFalse(Reactions.isValidValue(String(repeating: "x", count: 65)))
    }

    func testSendGate() {
        let ok = line(1)
        XCTAssertTrue(Reactions.canSend(on: ok, target: "#lurker", networkCanReact: true))
        XCTAssertTrue(Reactions.canSend(on: ok, target: "bob", networkCanReact: true), "a DM")
        XCTAssertTrue(Reactions.canSend(on: line(1, type: .action), target: "#lurker", networkCanReact: true))
        XCTAssertFalse(Reactions.canSend(on: ok, target: "#lurker", networkCanReact: false))
        XCTAssertFalse(Reactions.canSend(on: line(1, msgid: nil), target: "#lurker", networkCanReact: true))
        XCTAssertFalse(Reactions.canSend(on: line(0), target: "#lurker", networkCanReact: true))
        XCTAssertFalse(Reactions.canSend(on: line(1, isE2E: true), target: "#lurker", networkCanReact: true))
        XCTAssertFalse(Reactions.canSend(on: line(1, type: .notice), target: "#lurker", networkCanReact: true))
        XCTAssertFalse(Reactions.canSend(on: ok, target: ":server:1", networkCanReact: true))
        XCTAssertFalse(Reactions.canSend(on: ok, target: "=bob", networkCanReact: true), "DCC chat")
    }

    func testReactActionFollowsTheSendGate() {
        let keys = { (message: Message, canReact: Bool) in
            MessageActions.build(
                for: message,
                scope: MessageActionScope(networkId: 1, isBookmarked: false, target: "#lurker", canReact: canReact)
            ).map(\.key)
        }
        XCTAssertTrue(keys(line(1), true).contains(.react))
        XCTAssertTrue(keys(line(1, isSelf: true), true).contains(.react), "you can react to your own line")
        XCTAssertFalse(keys(line(1), false).contains(.react))
        XCTAssertFalse(keys(line(1, type: .notice), true).contains(.react))

        var reacted: Message?
        let context = MessageActionContext(
            reply: { _ in }, copy: { _ in }, setBookmark: { _, _ in }, showProfile: { _ in },
            react: { reacted = $0 }
        )
        let scope = MessageActionScope(networkId: 1, isBookmarked: false, target: "#lurker", canReact: false)
        MessageActions.run(.react, on: line(1), scope: scope, context: context)
        XCTAssertNil(reacted, "not offered, so not run")
        MessageActions.run(.react, on: line(1), scope: MessageActionScope(
            networkId: 1, isBookmarked: false, target: "#lurker", canReact: true), context: context)
        XCTAssertEqual(reacted?.id, 1)
    }
}

/// `GET /api/activity` (iOS #183): two sources merged, a cursor per source.
final class ActivityFeedParsingTests: XCTestCase {

    func testHighlightAndReactionRowsAndThePairedCursor() {
        let page = FrameParser.parseActivity(##"""
        {"items":[
          {"kind":"reaction","id":40,"reactionId":7,"networkId":1,"networkName":"Libera","target":"#c","nick":"bob","userhost":"bob!b@h","value":"🎉","time":"2026-09-30T12:00:00Z","text":"my line","messageTime":"2026-09-30T11:00:00Z"},
          {"kind":"highlight","id":39,"networkId":1,"target":"#c","type":"message","nick":"carol","text":"me: hi","matched":true}
        ],"next":{"beforeMessage":39,"beforeReaction":7}}
        """##)
        XCTAssertEqual(page.items.count, 2)
        let reaction = page.items[0]
        XCTAssertEqual(reaction.reaction, FeedReaction(reactionId: 7, value: "🎉", lineText: "my line"))
        XCTAssertEqual(reaction.message.id, 40, "your line's id: the jump target")
        XCTAssertEqual(reaction.message.nick, "bob", "the reactor, for the header and ignore rules")
        XCTAssertEqual(reaction.message.text, "🎉")
        XCTAssertEqual(reaction.message.userhost, "bob!b@h")
        XCTAssertNotNil(reaction.message.date, "the reaction's own time")
        XCTAssertNil(page.items[1].reaction)
        XCTAssertEqual(page.items[1].message.text, "me: hi")
        XCTAssertEqual(page.next, FeedCursor(beforeMessage: 39, beforeReaction: 7))
        XCTAssertTrue(page.hasMore)
    }

    func testOneSidedCursorStillPagesAndNullEnds() {
        let oneSided = FrameParser.parseActivity(##"{"items":[],"next":{"beforeReaction":3}}"##)
        XCTAssertEqual(oneSided.next, FeedCursor(beforeMessage: nil, beforeReaction: 3))
        XCTAssertTrue(oneSided.hasMore, "a side that's given nothing yet has no cursor, and that's not the end")
        XCTAssertFalse(FrameParser.parseActivity(##"{"items":[],"next":null}"##).hasMore)
    }

    func testAReactionRowWithoutAValueIsDropped() {
        let page = FrameParser.parseActivity(##"{"items":[{"kind":"reaction","id":1,"reactionId":2,"value":""}],"next":null}"##)
        XCTAssertTrue(page.items.isEmpty)
    }
}

/// `/react` (iOS #183).
final class ReactCommandTests: XCTestCase {

    private func effects(_ input: String) -> [CommandEffect] {
        guard case .command(let effects) = CommandParser.parse(input, networkId: 1, target: "#c") else { return [] }
        return effects
    }

    func testParses() {
        XCTAssertEqual(effects("/react 👍"), [.react(value: "👍")])
        XCTAssertEqual(effects("/react  nice one "), [.react(value: "nice one")])
        guard case .info = effects("/react").first else { return XCTFail("usage expected") }
        guard case .info = effects("/react " + String(repeating: "x", count: 65)).first else {
            return XCTFail("too long should be refused before it reaches the wire")
        }
    }

    private func line(_ id: Int, _ type: EventType = .message, isSelf: Bool = false, msgid: String? = "m", e2e: Bool = false) -> Message {
        Message(id: id, type: type, nick: isSelf ? "me" : "bob", text: "x", isSelf: isSelf, msgid: msgid, isE2E: e2e)
    }

    func testLandsOnTheLastLineSomeoneElseSaid() {
        let target = Reactions.commandTarget(in: [line(1), line(2), line(3, isSelf: true), line(4, .join), Message(id: 0, type: .system, nick: nil, text: "local")])
        XCTAssertEqual(try? target.get().id, 2)
    }

    func testSaysWhyRatherThanReachingBack() {
        XCTAssertEqual(Reactions.commandTarget(in: [line(1), line(2, .notice)]), .failure(.init("can't react to a notice")))
        XCTAssertEqual(Reactions.commandTarget(in: [line(1), line(2, e2e: true)]), .failure(.init("can't react to an encrypted line")))
        XCTAssertEqual(Reactions.commandTarget(in: [line(1), line(2, msgid: nil)]), .failure(.init("can't react to that line (no message id)")))
        XCTAssertEqual(Reactions.commandTarget(in: [line(3, isSelf: true)]), .failure(.init("nothing here to react to")))
    }
}

@MainActor
final class ReactionRenameTests: XCTestCase {
    func testARenameCarriesTheRevision() {
        let store = LurkerStore()
        store.apply(.backlog(
            buffer: Buffer(networkId: 1, target: "bob", kind: .dm, hydrated: true),
            messages: [Message(id: 1, type: .message, nick: "bob", text: "hi", msgid: "m")],
            hydrated: true, append: false, speakers: nil))
        store.apply(.reaction(ReactionChange(networkId: 1, target: "bob", messageId: 1, nick: "me", value: "👍", isSelf: true, remove: false, toSelf: false)))
        store.apply(.bufferRenamed(networkId: 1, from: "bob", to: "bobby", bufferId: nil, merged: false, mergedFromBufferId: nil))
        XCTAssertEqual(store.state.reactionsRevision(for: BufferKey(networkId: 1, target: "bobby")), 1)
        XCTAssertNil(store.state.reactionsRevisions["1::bob"])
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Channel controls (lurker-ios#187, the iOS half of lurker#727): the mode vocabulary and
/// channel state off the wire, rank gating, the settings form's diff, its drafts, and how an
/// open list stays current.
@MainActor
final class ChannelModesTests: XCTestCase {

    private let spec = ModeSpec(
        list: "beIq", always: "k", onSet: "lj", flags: "imnstC",
        prefix: [PrefixMode(mode: "o", symbol: "@"), PrefixMode(mode: "v", symbol: "+")],
        maxModes: 4, topicLen: 390
    )

    // MARK: - Wire

    func testSnapshotCarriesTheSpecAndEachChannelsModeState() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"snapshot","networks":[{"networkId":1,"state":"connected","nick":"me",
          "modeSpec":{"list":"beI","always":"k","onSet":"l","flags":"imnst",
            "prefix":[{"mode":"o","symbol":"@"},{"mode":"vv","symbol":"+"},{"mode":"v","symbol":"+"}],
            "maxModes":null,"topicLen":307},
          "channels":[{"name":"#c","topic":"hi","topicSetBy":"alice!a@h","topicSetAt":"2026-09-01T10:00:00.000Z",
            "modes":"ntkl","modeParams":{"l":"50"},"createdAt":"2020-01-01T00:00:00.000Z","members":[]}]}]}
        """##)
        guard case let .snapshot(networks, _, _) = frame, let network = networks.first else {
            return XCTFail("expected snapshot, got \(frame)")
        }
        let parsed = network.modeSpec
        XCTAssertEqual(parsed?.list, "beI")
        XCTAssertEqual(parsed?.prefix.map(\.mode), ["o", "v"], "a prefix entry that isn't one letter is dropped")
        XCTAssertNil(parsed?.maxModes, "null is no limit, not a default")
        XCTAssertEqual(parsed?.topicLen, 307)
        let channel = network.channels.first?.modeState
        XCTAssertEqual(channel?.modes, "ntkl")
        XCTAssertEqual(channel?.params, ["l": "50"])
        XCTAssertEqual(channel?.topicSetBy, "alice!a@h")
        XCTAssertNotNil(channel?.topicSetAt)
        XCTAssertNotNil(channel?.createdAt)
    }

    /// ⚠⚠ Null until the burst ends — and null must stay "unknown", never become the defaults.
    func testANullSpecIsUnknown() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":1,"state":"connected","nick":"me","modeSpec":null,"channels":[]}]}"##
        )
        guard case let .snapshot(networks, _, _) = frame else { return XCTFail("expected snapshot") }
        XCTAssertNil(networks.first?.modeSpec)
    }

    /// A network-scoped frame on a `:server:` carrier — below the target guard it would be a line.
    func testModeSpecFrame() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"irc","networkId":2,"target":":server:2","type":"mode-spec",
         "modeSpec":{"list":"beIq","always":"k","onSet":"l","flags":"nt","prefix":[{"mode":"o","symbol":"@"}],"maxModes":4,"topicLen":null}}
        """##)
        XCTAssertEqual(frame, .modeSpec(networkId: 2, spec: ModeSpec(
            list: "beIq", always: "k", onSet: "l", flags: "nt",
            prefix: [PrefixMode(mode: "o", symbol: "@")], maxModes: 4, topicLen: nil
        )))
    }

    func testChannelModesFrameNeverBecomesALine() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#c","type":"channel-modes","modes":"ntl","modeParams":{"l":"50"},"createdAt":null}"##
        )
        XCTAssertEqual(frame, .channelModes(networkId: 1, target: "#c", modes: "ntl", params: ["l": "50"], createdAt: nil))
    }

    /// The setter's KEY is what says the server stated it: `null` replaces a stale setter, an
    /// absent key leaves it alone.
    func testChannelTopicMetaFollowsKeyPresence() {
        let stated = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#c","type":"channel-topic","topic":"t","setBy":"bob","setAt":null}"##
        )
        guard case let .channelTopic(_, _, _, meta) = stated else { return XCTFail("expected channelTopic") }
        XCTAssertEqual(meta, TopicMeta(setBy: "bob", setAt: nil))

        let silent = FrameParser.parseWs(##"{"kind":"irc","networkId":1,"target":"#c","type":"channel-topic","topic":"t"}"##)
        guard case let .channelTopic(_, _, _, none) = silent else { return XCTFail("expected channelTopic") }
        XCTAssertNil(none)
    }

    func testVerbReplyCarriesItsData() {
        let list = FrameParser.parseVerbReply(##"""
        {"kind":"send-result","clientId":"ios-verb-3","ok":true,"data":{"ok":true,"channel":"#c","letter":"b",
         "entries":[{"mask":"*!*@bad","setBy":"op","setAt":"2026-09-01T10:00:00.000Z"},{"mask":"x!*@*","setBy":null,"setAt":null},{"mask":""}]}}
        """##)
        XCTAssertEqual(list?.clientId, "ios-verb-3")
        XCTAssertEqual(list?.reply.ok, true)
        XCTAssertEqual(list?.reply.entries?.map(\.mask), ["*!*@bad", "x!*@*"], "an entry with no mask names nothing")
        XCTAssertEqual(list?.reply.entries?.first?.setBy, "op")
        XCTAssertNotNil(list?.reply.entries?.first?.setAt)

        let refused = FrameParser.parseVerbReply(##"""
        {"kind":"send-result","clientId":"ios-verb-4","ok":false,"error":"refused","data":{"ok":false,"error":"refused","numeric":"482","text":"You're not a channel operator"}}
        """##)
        XCTAssertEqual(ChatViewModel.listError(refused!.reply), "Only channel operators can see this list.")
        XCTAssertNil(FrameParser.parseVerbReply(##"{"kind":"send-result","ok":true}"##), "no clientId, nobody waiting")
    }

    func testVerbErrorsAreWorded() {
        XCTAssertNil(ChatViewModel.saveError(VerbReply(ok: true, error: nil)))
        XCTAssertEqual(ChatViewModel.saveError(.notSent), "Not connected.")
        XCTAssertEqual(ChatViewModel.saveError(.noAnswer), "The server didn't answer.")
        XCTAssertEqual(ChatViewModel.saveError(VerbReply(ok: false, error: "unknown-mode:x")), "Couldn't save (unknown-mode:x).")
        XCTAssertEqual(
            ChatViewModel.listError(VerbReply(ok: false, error: "refused", numeric: "403", text: "No such channel")),
            "The server refused: No such channel"
        )
        XCTAssertEqual(ChatViewModel.listError(.noAnswer), "The server didn't answer.")
        XCTAssertEqual(ChatViewModel.listError(VerbReply(ok: false, error: "no-reply")), "The server didn't answer.")
        XCTAssertEqual(
            ChatViewModel.listError(VerbReply(ok: false, error: "account-paused")),
            "This account is paused, so nothing can be fetched.", "a refusal is not silence"
        )
        XCTAssertEqual(
            ChatViewModel.listError(VerbReply(ok: false, error: "unsupported-list-mode")),
            "Couldn't load the list (unsupported-list-mode)."
        )
    }

    func testNetworkConfigReadsChannelKeys() {
        let configs = FrameParser.parseNetworkConfigs(##"""
        {"networks":[{"id":1,"name":"n","host":"h","port":6697,"nick":"me",
          "channels":[{"name":"#Secret","key":"hunter2"},{"name":"#open","key":null},{"name":"","key":"x"}]}]}
        """##)
        let config = configs?.first
        XCTAssertEqual(config?.key(for: "#secret"), "hunter2", "looked up case-insensitively")
        XCTAssertNil(config?.key(for: "#open"))
        XCTAssertEqual(config?.channelKeys.count, 1)
    }

    // MARK: - Live lines

    /// The settings screens patch lists and read refusals off these — including for a detached
    /// buffer, which holds live lines out of its log. So they come off the frame, not the store.
    func testLiveLinesAndResyncsReachChannelEvents() {
        let model = ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.channelmodes"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.channelmodes")!)
        )
        var seen: [String] = []
        let sink = model.channelEvents.sink { event in
            switch event {
            case .line(let key, let message): seen.append("\(key.id) \(message.type.rawValue)")
            case .resynced: seen.append("resynced")
            }
        }
        defer { sink.cancel() }
        model.handle(.live(networkId: 1, target: "#C", message: Message(
            id: 7, type: .mode, nick: "op", text: "+b x", modes: [ModeChange(mode: "+b", param: "x", kind: .list)]
        )))
        model.handle(.socketOpen)
        model.handle(.snapshot([NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [])], globalIgnores: [], maxUploadBytes: nil))
        XCTAssertEqual(seen, ["1::#c mode", "resynced"], "after the snapshot, not the socket opening")
    }

    // MARK: - Store

    private func storeWithChannel(modes: String = "nt", selfModes: [String] = ["o"]) -> LurkerStore {
        let store = LurkerStore()
        store.apply(.socketOpen)
        store.apply(.snapshot([NetworkSnapshot(
            id: 1, state: .connected, nick: "me",
            channels: [ChannelSnapshot(
                name: "#c", topic: "hi",
                members: [Member(nick: "Me", modes: selfModes), Member(nick: "bob")],
                modeState: ChannelModeState(modes: modes, topicSetBy: "alice")
            )],
            modeSpec: spec
        )], globalIgnores: [], maxUploadBytes: nil))
        return store
    }

    private let key = BufferKey(networkId: 1, target: "#c")

    func testSnapshotSeedsSpecAndChannelState() {
        let store = storeWithChannel()
        XCTAssertEqual(store.state.networks[1]?.modeSpec, spec)
        XCTAssertEqual(store.state.channelModes[key.id]?.modes, "nt")
        XCTAssertEqual(store.state.channelModes[key.id]?.topicSetBy, "alice")
    }

    func testChannelModesFrameReplacesModesButKeepsTheTopicSetter() {
        let store = storeWithChannel()
        store.apply(.channelModes(networkId: 1, target: "#C", modes: "ntl", params: ["l": "9"], createdAt: nil))
        XCTAssertEqual(store.state.channelModes[key.id]?.modes, "ntl")
        XCTAssertEqual(store.state.channelModes[key.id]?.params, ["l": "9"])
        XCTAssertEqual(store.state.channelModes[key.id]?.topicSetBy, "alice")

        store.apply(.channelModes(networkId: 1, target: "#elsewhere", modes: "n", params: [:], createdAt: nil))
        XCTAssertNil(store.state.channelModes[BufferKey(networkId: 1, target: "#elsewhere").id], "never materializes")
    }

    func testATopicLineNamesItsSetter() {
        let store = storeWithChannel()
        let when = Date(timeIntervalSince1970: 1_000)
        store.apply(.live(networkId: 1, target: "#c", message: Message(id: 5, type: .topic, nick: "carol", text: "new", date: when)))
        XCTAssertEqual(store.state.buffers[key.id]?.topic, "new")
        XCTAssertEqual(store.state.channelModes[key.id]?.topicSetBy, "carol")
        XCTAssertEqual(store.state.channelModes[key.id]?.topicSetAt, when)
    }

    func testChannelTopicMetaReplacesOnlyWhenStated() {
        let store = storeWithChannel()
        store.apply(.channelTopic(networkId: 1, target: "#c", topic: "x"))
        XCTAssertEqual(store.state.channelModes[key.id]?.topicSetBy, "alice", "no meta: the held setter stands")
        store.apply(.channelTopic(networkId: 1, target: "#c", topic: "x", meta: TopicMeta(setBy: nil, setAt: nil)))
        XCTAssertNil(store.state.channelModes[key.id]?.topicSetBy)
    }

    func testSpecIsForgottenWhenTheLinkDropsAndRestatedByTheFrame() {
        let store = storeWithChannel()
        store.apply(.networkState(networkId: 1, state: .reconnecting, nick: nil))
        XCTAssertNil(store.state.networks[1]?.modeSpec)
        store.apply(.networkState(networkId: 1, state: .connected, nick: nil))
        XCTAssertNil(store.state.networks[1]?.modeSpec, "unknown until the new burst says")
        store.apply(.modeSpec(networkId: 1, spec: spec))
        XCTAssertEqual(store.state.networks[1]?.modeSpec, spec)
        store.apply(.modeSpec(networkId: 9, spec: spec))
        XCTAssertNil(store.state.networks[9], "never materializes a network")
    }

    func testChannelStateFollowsARenameAndGoesWithAClose() {
        let store = storeWithChannel()
        store.apply(.bufferRenamed(networkId: 1, from: "#c", to: "#d", bufferId: nil, merged: false, mergedFromBufferId: nil))
        XCTAssertNil(store.state.channelModes[key.id])
        XCTAssertEqual(store.state.channelModes[BufferKey(networkId: 1, target: "#d").id]?.modes, "nt")
        store.apply(.bufferClosed(networkId: 1, target: "#d"))
        XCTAssertNil(store.state.channelModes[BufferKey(networkId: 1, target: "#d").id])
    }

    // MARK: - Access

    func testAnOpEditsEverything() {
        let access = storeWithChannel().state.channelAccess(key)
        XCTAssertTrue(access.joined)
        XCTAssertTrue(access.canEditModes, "our own row found case-insensitively")
        XCTAssertTrue(access.canSetTopic)
    }

    func testPlusTGatesTheTopicOnHalfopAndAVoiceEditsNoModes() {
        let voiced = storeWithChannel(modes: "nt", selfModes: ["v"]).state.channelAccess(key)
        XCTAssertFalse(voiced.canEditModes)
        XCTAssertFalse(voiced.canSetTopic, "+t, and this network has no halfop: the gate rounds UP to op")
        let open = storeWithChannel(modes: "n", selfModes: []).state.channelAccess(key)
        XCTAssertTrue(open.canSetTopic, "-t: anyone in the channel")
    }

    func testNothingIsEditableOutOfTheChannel() {
        let store = storeWithChannel()
        store.apply(.channelParted(networkId: 1, target: "#c"))
        let access = store.state.channelAccess(key)
        XCTAssertFalse(access.joined)
        XCTAssertFalse(access.canEditModes)
        XCTAssertFalse(access.canSetTopic)
    }

    // MARK: - Rank

    func testRankUsesTheNetworksOwnLadder() {
        let odd = [PrefixMode(mode: "Y", symbol: "!"), PrefixMode(mode: "o", symbol: "@"), PrefixMode(mode: "v", symbol: "+")]
        XCTAssertTrue(ChannelRank.atLeast(["Y"], prefix: odd, "o"))
        XCTAssertTrue(ChannelRank.atLeast(["v", "o"], prefix: odd, "o"), "scans by rank, not array order")
        XCTAssertFalse(ChannelRank.atLeast(["v"], prefix: odd, "o"))
        XCTAssertFalse(ChannelRank.atLeast([], prefix: odd, "v"))
        XCTAssertEqual(ChannelRank.index(["v", "Y"], prefix: odd), 0)
    }

    func testAGateForALetterTheNetworkLacksRoundsUp() {
        let noHalfop = [PrefixMode(mode: "o", symbol: "@"), PrefixMode(mode: "v", symbol: "+")]
        XCTAssertTrue(ChannelRank.atLeast(["o"], prefix: noHalfop, "h"))
        XCTAssertFalse(ChannelRank.atLeast(["v"], prefix: noHalfop, "h"))
        XCTAssertFalse(ChannelRank.atLeast(["o"], prefix: noHalfop, "Z"), "a letter on no ladder gates nobody in")
    }

    // MARK: - Form

    func testRowsComeFromTheSpecNamedFirst() {
        let rows = ChannelModeForm.rows(spec)
        XCTAssertEqual(rows.map(\.letter), ["i", "m", "n", "s", "t", "k", "l", "C", "j"])
        XCTAssertEqual(rows.first { $0.letter == "k" }?.kind, .key)
        XCTAssertEqual(rows.first { $0.letter == "j" }?.kind, .param)
        XCTAssertNil(rows.first { $0.letter == "C" }?.name, "no name we can vouch for")
        XCTAssertFalse(rows.contains { $0.letter == "b" }, "lists have their own screens")
        XCTAssertEqual(ChannelModeForm.lists(in: spec).map(\.letter), ["b", "e", "I", "q"])
    }

    private func changes(_ live: ChannelModeForm.Live, _ draft: [String: ChannelModeForm.DraftRow])
        -> Result<[OutgoingModeChange], ChannelModeForm.ChangeError> {
        ChannelModeForm.changes(spec: spec, live: live, draft: draft)
    }

    private func row(_ on: Bool, _ value: String = "") -> ChannelModeForm.DraftRow {
        ChannelModeForm.DraftRow(on: on, value: value)
    }

    func testFlagsDiffAgainstTheLiveState() {
        let live = ChannelModeForm.Live(modes: "nt", params: [:])
        XCTAssertEqual(try changes(live, ["m": row(true), "t": row(false), "n": row(true)]).get(), [
            OutgoingModeChange(sign: "+", letter: "m"),
            OutgoingModeChange(sign: "-", letter: "t"),
        ])
    }

    func testParamModes() {
        let live = ChannelModeForm.Live(modes: "nl", params: ["l": "50"])
        XCTAssertEqual(try changes(live, ["l": row(true, " 60 ")]).get(), [OutgoingModeChange(sign: "+", letter: "l", param: "60")])
        XCTAssertEqual(try changes(live, ["l": row(true, "50")]).get(), [], "unchanged")
        XCTAssertEqual(try changes(live, ["l": row(false, "50")]).get(), [OutgoingModeChange(sign: "-", letter: "l")], "-l takes no param")
        XCTAssertEqual(try changes(live, ["j": row(true)]).get_error(), .valueRequired("j"))
        XCTAssertEqual(try changes(live, ["j": row(true, "3 4")]).get_error(), .spaces("j"))
        XCTAssertEqual(try changes(live, ["j": row(false, "3 4")]).get(), [], "a value being turned off needn't be valid")
    }

    func testTheKey() {
        let keyed = ChannelModeForm.Live(modes: "k", params: ["k": "old"])
        XCTAssertEqual(try changes(keyed, ["k": row(true, "new")]).get(), [
            OutgoingModeChange(sign: "-", letter: "k"),
            OutgoingModeChange(sign: "+", letter: "k", param: "new"),
        ], "replacing a key takes the old one off first (467 otherwise)")
        XCTAssertEqual(try changes(keyed, ["k": row(true, "")]).get(), [], "on, and no new key: keep it")
        XCTAssertEqual(try changes(keyed, ["k": row(false)]).get(), [OutgoingModeChange(sign: "-", letter: "k")], "the server fills -k")

        let unknownKey = ChannelModeForm.Live(modes: "k", params: [:])
        XCTAssertEqual(try changes(unknownKey, ["k": row(true, "")]).get(), [], "Key is set, and left alone")

        let open = ChannelModeForm.Live(modes: "", params: [:])
        XCTAssertEqual(try changes(open, ["k": row(true, "")]).get_error(), .keyRequired)
        XCTAssertEqual(try changes(open, ["k": row(true, "s3cret")]).get(), [OutgoingModeChange(sign: "+", letter: "k", param: "s3cret")])
    }

    /// A B-group mode other than the key names its value to unset it — `*` when we never learned it.
    func testAnAlwaysParamModeNamesItsValueToUnset() {
        let bGroup = ModeSpec(list: "b", always: "kf", onSet: "l", flags: "n", prefix: [], maxModes: 3, topicLen: nil)
        let live = ChannelModeForm.Live(modes: "f", params: [:])
        XCTAssertEqual(
            try ChannelModeForm.changes(spec: bGroup, live: live, draft: ["f": row(false)]).get(),
            [OutgoingModeChange(sign: "-", letter: "f", param: "*")]
        )
    }

    func testTopicIsBytesAndOneLine() {
        XCTAssertEqual(ChannelModeForm.topicBytes("héllo"), 6)
        XCTAssertEqual(ChannelModeForm.topicToSend("a\r\nb\nc"), "a b c")
    }

    // MARK: - Drafts

    func testAnEditDissolvesWhenTheChannelMatchesIt() {
        let live = ChannelModeForm.Live(modes: "nt", params: [:])
        var drafts = ChannelModeDrafts()
        drafts.setOn("m", true, live: live)
        drafts.reconcile(live: live, liveTopic: "")
        XCTAssertNotNil(drafts.rows["m"], "the channel hasn't answered yet")
        drafts.reconcile(live: ChannelModeForm.Live(modes: "ntm", params: [:]), liveTopic: "")
        XCTAssertNil(drafts.rows["m"])
    }

    /// The server may echo a value normalized — `+l 050` comes back as 50. A saved row whose
    /// live state MOVED is answered, matching or not.
    func testASavedRowDissolvesWhenItsLiveStateMoves() {
        let live = ChannelModeForm.Live(modes: "nl", params: ["l": "50"])
        var drafts = ChannelModeDrafts()
        drafts.setValue("l", "050", live: live)
        let sent = try! ChannelModeForm.changes(spec: spec, live: live, draft: drafts.rows).get()
        drafts.noteSent(drafts.sending(sent, live: live))
        drafts.reconcile(live: live, liveTopic: "")
        XCTAssertNotNil(drafts.rows["l"], "never cleared on the ack — only the channel answers")
        drafts.reconcile(live: ChannelModeForm.Live(modes: "nl", params: ["l": "50"]), liveTopic: "")
        XCTAssertNotNil(drafts.rows["l"], "nothing moved: a refusal leaves the edit standing")
        drafts.reconcile(live: ChannelModeForm.Live(modes: "nl", params: ["l": "51"]), liveTopic: "")
        XCTAssertNil(drafts.rows["l"])
    }

    /// Untick +m again before +m comes back: the echo answers the edit that was SENT, and the
    /// newer one is the user's to keep.
    func testANewerEditOutlivesTheEchoOfTheOldOne() {
        let live = ChannelModeForm.Live(modes: "n", params: [:])
        var drafts = ChannelModeDrafts()
        drafts.setOn("m", true, live: live)
        drafts.setOn("s", true, live: live)
        drafts.noteSent(drafts.sending([OutgoingModeChange(sign: "+", letter: "m")], live: live))
        drafts.setOn("m", false, live: live)
        drafts.reconcile(live: ChannelModeForm.Live(modes: "nm", params: [:]), liveTopic: "")
        XCTAssertEqual(drafts.rows["m"], ChannelModeForm.DraftRow(on: false, value: ""), "the untick stands")
        XCTAssertNotNil(drafts.rows["s"], "a row nobody answered stands")
    }

    func testTheTopicDraft() {
        var drafts = ChannelModeDrafts()
        XCTAssertNil(drafts.topicChange(live: "old"), "untouched")
        drafts.setTopic("new\nline")
        XCTAssertEqual(drafts.topicChange(live: "old"), "new line")
        drafts.noteTopicSent("new line", liveTopic: "old")
        drafts.reconcile(live: ChannelModeForm.Live(modes: "", params: [:]), liveTopic: "old")
        XCTAssertNotNil(drafts.topic)
        // The server trimmed it: moved, so the saved edit is answered.
        drafts.reconcile(live: ChannelModeForm.Live(modes: "", params: [:]), liveTopic: "new lin")
        XCTAssertNil(drafts.topic)
    }

    /// ⚠⚠ A change that never went out is not the echo's to answer. The topic failed, so the
    /// +m behind it never left — and another op's +m then -m must not dissolve it.
    func testAnUnsentChangeIsNotAnsweredBySomeoneElsesMove() {
        let live = ChannelModeForm.Live(modes: "n", params: [:])
        var drafts = ChannelModeDrafts()
        drafts.setOn("m", true, live: live)
        let sending = drafts.sending([OutgoingModeChange(sign: "+", letter: "m")], live: live)
        drafts.noteSent(sending)
        drafts.noteNotSent(sending)
        drafts.reconcile(live: ChannelModeForm.Live(modes: "nm", params: [:]), liveTopic: "")
        XCTAssertNil(drafts.rows["m"], "matching still answers it")

        drafts.setOn("m", true, live: live)
        let again = drafts.sending([OutgoingModeChange(sign: "+", letter: "m")], live: live)
        drafts.noteSent(again)
        drafts.noteNotSent(again)
        drafts.reconcile(live: ChannelModeForm.Live(modes: "ns", params: [:]), liveTopic: "")
        XCTAssertNotNil(drafts.rows["m"], "but a move it never caused doesn't")
    }

    /// A slow first Save whose failure lands after a second Save must not take back the second's
    /// record.
    func testTakingBackAnOldSaveLeavesANewerOne() {
        var drafts = ChannelModeDrafts()
        let fifty = ChannelModeForm.Live(modes: "l", params: ["l": "50"])
        drafts.setValue("l", "60", live: fifty)
        let first = drafts.sending([OutgoingModeChange(sign: "+", letter: "l", param: "60")], live: fifty)
        drafts.noteSent(first)
        let fiftyFive = ChannelModeForm.Live(modes: "l", params: ["l": "55"])
        let second = drafts.sending([OutgoingModeChange(sign: "+", letter: "l", param: "60")], live: fiftyFive)
        drafts.noteSent(second)
        drafts.noteNotSent(first)
        // The server normalized: 55 → 56 is the second Save's echo, and answers the edit.
        drafts.reconcile(live: ChannelModeForm.Live(modes: "l", params: ["l": "56"]), liveTopic: "")
        XCTAssertNil(drafts.rows["l"])
    }

    func testOnlyErrorsSoonAfterAChangeAnswerIt() {
        var refusals = ChannelRefusals()
        let start = Date(timeIntervalSince1970: 1_000)
        refusals.note("before", at: start)
        XCTAssertEqual(refusals.current, [], "nothing sent yet")
        refusals.arm(at: start.addingTimeInterval(1))
        refusals.note("482 not an op", at: start.addingTimeInterval(2))
        refusals.note("much later", at: start.addingTimeInterval(1 + ChannelRefusals.window + 1))
        XCTAssertEqual(refusals.current, ["482 not an op"])
        refusals.arm(at: start.addingTimeInterval(100))
        XCTAssertEqual(refusals.current, [], "a new change starts clean")
    }

    func testASaveFailureSaysWhetherAnythingCanHaveGoneOut() {
        XCTAssertNil(ChatViewModel.saveFailure(VerbReply(ok: true, error: nil)))
        XCTAssertEqual(ChatViewModel.saveFailure(.notSent)?.certainlyUnsent, true)
        XCTAssertEqual(ChatViewModel.saveFailure(VerbReply(ok: false, error: "account-paused"))?.certainlyUnsent, true)
        XCTAssertEqual(ChatViewModel.saveFailure(.noAnswer)?.certainlyUnsent, false, "it may have gone out")
        XCTAssertEqual(ChatViewModel.saveFailure(.connectionLost)?.certainlyUnsent, false)
        XCTAssertEqual(ChatViewModel.saveFailure(.connectionLost)?.message, "The connection dropped before the server answered.")
    }

    // MARK: - Lists

    private func modeRow(_ nick: String, _ changes: [ModeChange]) -> Message {
        Message(id: 1, type: .mode, nick: nick, text: nil, date: Date(timeIntervalSince1970: 50), modes: changes)
    }

    func testAnOpenListIsPatchedFromLiveRows() {
        let fetched = [ModeListEntry(mask: "*!*@Bad.host", setBy: "op", setAt: nil)]
        let patched = ChannelModeForm.patch(fetched, with: [
            modeRow("op2", [ModeChange(mode: "+b", param: "troll!*@*", kind: .list)]),
            modeRow("op2", [ModeChange(mode: "-b", param: "*!*@bad.HOST", kind: .list)]),
            modeRow("op2", [ModeChange(mode: "+b", param: "TROLL!*@*", kind: .list)]),
            modeRow("op2", [ModeChange(mode: "+e", param: "friend!*@*", kind: .list)]),
            // Solanum's +q is a list; elsewhere it's an owner, which the server stamps `prefix`.
            modeRow("op2", [ModeChange(mode: "+b", param: "nick", kind: .prefix)]),
        ], letter: "b")
        XCTAssertEqual(patched.map(\.mask), ["troll!*@*"], "case-insensitive both ways, other letters and kinds ignored")
        XCTAssertEqual(patched.first?.setBy, "op2")
        XCTAssertEqual(patched.first?.setAt, Date(timeIntervalSince1970: 50))
    }

    func testLastKeyChange() {
        XCTAssertEqual(ChannelModeForm.lastKeyChange([]), .none)
        XCTAssertEqual(ChannelModeForm.lastKeyChange([modeRow("a", [ModeChange(mode: "+k", param: "pw", kind: .chan)])]), .set("pw"))
        XCTAssertEqual(ChannelModeForm.lastKeyChange([
            modeRow("a", [ModeChange(mode: "+k", param: "pw", kind: .chan)]),
            modeRow("a", [ModeChange(mode: "-k", param: "*", kind: .chan)]),
        ]), .removed)
        // A hidden value is still the newest word: an older key must not show through.
        XCTAssertEqual(ChannelModeForm.lastKeyChange([
            modeRow("a", [ModeChange(mode: "+k", param: "pw", kind: .chan)]),
            modeRow("a", [ModeChange(mode: "+k", param: "*", kind: .chan)]),
        ]), .setUnknown, "`*` is a mask, not a key")
        XCTAssertEqual(
            ChannelModeForm.lastKeyChange([modeRow("a", [ModeChange(mode: "+k", param: nil, kind: .chan)])]),
            .setUnknown
        )
    }
}

private extension Result {
    /// The failure, or nil — so a test can compare it with `XCTAssertEqual`.
    func get_error() throws -> Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

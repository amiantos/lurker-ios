// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The notification ladder end to end (lurker#359, Mobile lurker#1087): the flag off the wire
/// and through the store, the mute rules the quiet rungs are made of, the rung a buffer reads
/// as, and what picking one sends.
///
/// Ported from the web client's `useNotifyLadder.test.ts`, the mute-rule cases of
/// `stores/ignores.test.ts`, and the lifecycle hooks of `stores/channelNotify.ts`.
@MainActor
final class NotifyLadderTests: XCTestCase {

    private let channel = NotifyLadder.Scope.channel(networkId: 1, target: "#Chan")
    private let dm = NotifyLadder.Scope.dm(networkId: 1, target: "Bob")
    private let network = NotifyLadder.Scope.network(networkId: 1)

    private func mute(
        _ id: Int, channels: [String]? = nil, levels: [String] = ["NOUNREAD", "NONOTIFY"],
        mask: String? = nil, pattern: String? = nil, isExcept: Bool = false
    ) -> IgnoreRule {
        IgnoreRule(
            id: id, mask: mask, channels: channels, pattern: pattern, levels: levels, isExcept: isExcept
        )
    }

    // MARK: - Which ladder

    /// ⚠ All four sigils. A `#` probe would hand `&local` the DM ladder, whose "All messages"
    /// is the absence of a rule rather than the flag the server consults.
    func testEveryChannelSigilGetsTheChannelLadder() {
        for target in ["#chan", "&local", "+modeless", "!safe"] {
            XCTAssertEqual(
                NotifyLadder.Scope.of(BufferKey(networkId: 1, target: target)),
                .channel(networkId: 1, target: target),
                target
            )
        }
    }

    func testADmADccChatAndAServerLogEachGetTheirs() {
        XCTAssertEqual(
            NotifyLadder.Scope.of(BufferKey(networkId: 1, target: "bob")), .dm(networkId: 1, target: "bob")
        )
        // The web's buffer menu gives a `=nick` chat the DM ladder, under its own target.
        XCTAssertEqual(
            NotifyLadder.Scope.of(BufferKey(networkId: 1, target: "=bob")), .dm(networkId: 1, target: "=bob")
        )
        XCTAssertEqual(
            NotifyLadder.Scope.of(BufferKey(networkId: 1, target: ":server:1")), .network(networkId: 1)
        )
        XCTAssertNil(NotifyLadder.Scope.of(Buffer.system.key), "the app's own buffer has no ladder")
    }

    func testEachLadderOffersItsOwnRungsInOrder() {
        XCTAssertEqual(channel.rungs, [.all, .highlights, .nothing, .muted])
        XCTAssertEqual(dm.rungs, [.all, .nothing, .muted])
        XCTAssertEqual(network.rungs, [.highlights, .nothing, .muted])
        XCTAssertEqual(channel.rungs.map(\.label), ["All messages", "Highlights only", "Nothing", "Muted"])
    }

    // MARK: - The current rung

    func testWithNothingSetEachLadderRestsOnItsBase() {
        XCTAssertEqual(NotifyLadder.rung(for: channel, notifiesAlways: false, muteLevels: []), .highlights)
        XCTAssertEqual(NotifyLadder.rung(for: dm, notifiesAlways: false, muteLevels: []), .all)
        XCTAssertEqual(NotifyLadder.rung(for: network, notifiesAlways: false, muteLevels: []), .highlights)
    }

    func testTheRuleLevelsNameTheQuietRungs() {
        for scope in [channel, dm, network] {
            XCTAssertEqual(NotifyLadder.rung(for: scope, notifiesAlways: false, muteLevels: ["NONOTIFY"]), .nothing)
            XCTAssertEqual(
                NotifyLadder.rung(for: scope, notifiesAlways: false, muteLevels: ["NOUNREAD", "NONOTIFY"]), .muted
            )
        }
    }

    /// Badge hidden but notifications still firing — only a hand-typed `/ignore` makes one, and
    /// it is neither "Nothing" nor "Muted".
    func testANoUnreadOnlyRuleFallsThroughToTheBaseRung() {
        XCTAssertEqual(NotifyLadder.rung(for: channel, notifiesAlways: false, muteLevels: ["NOUNREAD"]), .highlights)
        XCTAssertEqual(NotifyLadder.rung(for: dm, notifiesAlways: false, muteLevels: ["NOUNREAD"]), .all)
        XCTAssertEqual(NotifyLadder.rung(for: network, notifiesAlways: false, muteLevels: ["NOUNREAD"]), .highlights)
    }

    func testTheFlagWinsOnAChannelAndIsNotReadAnywhereElse() {
        XCTAssertEqual(
            NotifyLadder.rung(for: channel, notifiesAlways: true, muteLevels: ["NOUNREAD", "NONOTIFY"]), .all
        )
        XCTAssertEqual(NotifyLadder.rung(for: dm, notifiesAlways: true, muteLevels: ["NONOTIFY"]), .nothing)
        XCTAssertEqual(NotifyLadder.rung(for: network, notifiesAlways: true, muteLevels: []), .highlights)
    }

    // MARK: - The plan

    private func plan(
        _ rung: NotifyRung, _ scope: NotifyLadder.Scope, always: Bool = false, rule: ScopedIgnoreRule? = nil
    ) -> [NotifyLadder.Step] {
        NotifyLadder.plan(to: rung, for: scope, notifiesAlways: always, muteRule: rule)
    }

    func testAlreadyThereIsNoSteps() {
        XCTAssertEqual(plan(.highlights, channel), [])
        XCTAssertEqual(plan(.all, channel, always: true), [])
        XCTAssertEqual(plan(.all, dm), [])
        XCTAssertEqual(plan(.highlights, network), [])
        let muted = ScopedIgnoreRule(rule: mute(5, channels: ["#chan"]), scope: 1)
        XCTAssertEqual(plan(.muted, channel, rule: muted), [])
        // Level ORDER is not a difference: the same two tokens either way round are one rule.
        let reversed = ScopedIgnoreRule(rule: mute(5, channels: ["#chan"], levels: ["NONOTIFY", "NOUNREAD"]), scope: 1)
        XCTAssertEqual(plan(.muted, channel, rule: reversed), [])
    }

    func testAllMessagesOnAChannelIsTheFlagAndNoRule() {
        XCTAssertEqual(
            plan(.all, channel), [.setNotifyAlways(networkId: 1, target: "#Chan", notifyAlways: true)]
        )
        XCTAssertEqual(
            plan(.highlights, channel, always: true),
            [.setNotifyAlways(networkId: 1, target: "#Chan", notifyAlways: false)]
        )
    }

    /// The rule a quiet rung adds: unmasked, unpatterned, non-except, scoped to exactly this
    /// one target folded, at network scope, with the levels in canonical order — the server
    /// dedupes on the stored CSV as a string.
    func testAQuietRungAddsItsRuleAtNetworkScope() {
        XCTAssertEqual(
            plan(.nothing, channel),
            [.addRule(networkId: 1, rule: IgnoreRule(channels: ["#chan"], levels: ["NONOTIFY"]))]
        )
        XCTAssertEqual(
            plan(.muted, dm),
            [.addRule(networkId: 1, rule: IgnoreRule(channels: ["bob"], levels: ["NOUNREAD", "NONOTIFY"]))]
        )
        guard case .addRule(_, let rule) = plan(.muted, channel).first else { return XCTFail("expected an add") }
        XCTAssertNil(rule.mask)
        XCTAssertNil(rule.pattern)
        XCTAssertFalse(rule.isExcept)
        XCTAssertNil(rule.expiresAt)
    }

    func testANetworkRuleHasNoChannelScope() {
        XCTAssertEqual(
            plan(.nothing, network),
            [.addRule(networkId: 1, rule: IgnoreRule(channels: nil, levels: ["NONOTIFY"]))]
        )
    }

    func testMovingBetweenQuietRungsRemovesTheOldRuleThenAddsTheNew() {
        let nothing = ScopedIgnoreRule(rule: mute(5, channels: ["#chan"], levels: ["NONOTIFY"]), scope: 1)
        XCTAssertEqual(
            plan(.muted, channel, rule: nothing),
            [
                .removeRule(id: 5, scope: 1),
                .addRule(networkId: 1, rule: IgnoreRule(channels: ["#chan"], levels: ["NOUNREAD", "NONOTIFY"])),
            ]
        )
    }

    /// A hand-typed global mute is removed from the GLOBAL bucket, where it lives; a removal
    /// addressed to the network would miss it. The replacement still goes in at network scope.
    func testAStaleRuleIsRemovedFromItsOwnScope() {
        let global = ScopedIgnoreRule(rule: mute(7, channels: ["#chan"]), scope: nil)
        XCTAssertEqual(plan(.highlights, channel, rule: global), [.removeRule(id: 7, scope: nil)])
        XCTAssertEqual(
            plan(.nothing, channel, rule: global),
            [
                .removeRule(id: 7, scope: nil),
                .addRule(networkId: 1, rule: IgnoreRule(channels: ["#chan"], levels: ["NONOTIFY"])),
            ]
        )
    }

    func testLeavingAQuietRungForAllMessagesSetsTheFlagAndClearsTheRule() {
        let muted = ScopedIgnoreRule(rule: mute(5, channels: ["#chan"]), scope: 1)
        XCTAssertEqual(
            plan(.all, channel, rule: muted),
            [.setNotifyAlways(networkId: 1, target: "#Chan", notifyAlways: true), .removeRule(id: 5, scope: 1)]
        )
        // A DM's "All messages" is only the absence of a rule: there is no flag to send.
        XCTAssertEqual(plan(.all, dm, always: true, rule: muted), [.removeRule(id: 5, scope: 1)])
    }

    func testGoingQuietFromAllMessagesClearsTheFlagFirst() {
        XCTAssertEqual(
            plan(.muted, channel, always: true),
            [
                .setNotifyAlways(networkId: 1, target: "#Chan", notifyAlways: false),
                .addRule(networkId: 1, rule: IgnoreRule(channels: ["#chan"], levels: ["NOUNREAD", "NONOTIFY"])),
            ]
        )
    }

    /// A `NOUNREAD`-only rule is on no rung, so a rung that needs no rule leaves it alone. The
    /// web's reconcile removes it; here the row that would do so is the one already checked,
    /// and tapping a checked row must not delete a rule somebody typed.
    func testARungThatNeedsNoRuleLeavesANoUnreadOnlyRuleAlone() {
        let badgeOnly = ScopedIgnoreRule(rule: mute(4, channels: ["#chan"], levels: ["NOUNREAD"]), scope: 1)
        XCTAssertEqual(plan(.highlights, channel, rule: badgeOnly), [])
        XCTAssertEqual(
            plan(.all, channel, rule: badgeOnly),
            [.setNotifyAlways(networkId: 1, target: "#Chan", notifyAlways: true)]
        )
    }

    /// A quiet rung still replaces it: one rule per buffer.
    func testAQuietRungReplacesANoUnreadOnlyRule() {
        let badgeOnly = ScopedIgnoreRule(rule: mute(4, channels: ["#chan"], levels: ["NOUNREAD"]), scope: 1)
        let steps = plan(.nothing, channel, rule: badgeOnly)
        XCTAssertEqual(steps.first, .removeRule(id: 4, scope: 1))
        XCTAssertEqual(steps.count, 2)
    }

    func testARungTheLadderDoesNotOfferPlansNothing() {
        XCTAssertEqual(plan(.highlights, dm), [])
        XCTAssertEqual(plan(.all, network), [])
    }

    // MARK: - The mute rules

    func testBufferMuteRuleFindsANetworkScopedPerChannelMuteAndReportsItsScope() {
        let set = IgnoreSet(byNetwork: [1: [mute(5, channels: ["#chan"])]])
        let found = set.bufferMuteRule(networkId: 1, target: "#Chan") // case-insensitive
        XCTAssertEqual(found?.rule.id, 5)
        XCTAssertEqual(found?.scope, 1)
        XCTAssertNil(set.bufferMuteRule(networkId: 2, target: "#chan"), "another network's rule")
    }

    func testBufferMuteRuleAlsoFindsAGlobalPerChannelMuteWithANilScope() {
        let set = IgnoreSet(global: [mute(7, channels: ["#chan"])])
        let found = set.bufferMuteRule(networkId: 1, target: "#chan")
        XCTAssertEqual(found?.rule.id, 7)
        XCTAssertNotNil(found)
        XCTAssertNil(found?.scope)
        // …and the badge path agrees the buffer is muted.
        XCTAssertTrue(set.mutesUnread(networkId: 1, target: "#chan"))
    }

    func testTheNetworkBucketIsSearchedBeforeTheGlobals() {
        let set = IgnoreSet(
            global: [mute(7, channels: ["#chan"])],
            byNetwork: [1: [mute(5, channels: ["#chan"], levels: ["NONOTIFY"])]]
        )
        XCTAssertEqual(set.bufferMuteRule(networkId: 1, target: "#chan")?.rule.id, 5)
    }

    func testBufferMuteRuleIgnoresMaskedPatternedExceptAndNonMuteRules() {
        let set = IgnoreSet(byNetwork: [1: [
            mute(1, channels: ["#chan"], mask: "bob"), // masked: not a whole-buffer mute
            mute(2, channels: ["#chan"], isExcept: true),
            mute(3, channels: ["#chan"], levels: ["PUBLIC"]), // a hide, not a mute
            mute(4, channels: ["#chan"], pattern: "spam"),
            mute(6, channels: ["#chan"], levels: ["NONOTIFY", "JOINS"]), // mute plus a hide
            mute(8, channels: ["#chan", "#other"]), // not this buffer's alone
            mute(9, channels: ["#chan"], levels: []),
        ]])
        XCTAssertNil(set.bufferMuteRule(networkId: 1, target: "#chan"))
    }

    func testNetworkMuteRuleFindsAChannellessMuteAndAPerChannelRuleIsNotIt() {
        let set = IgnoreSet(byNetwork: [1: [mute(9, channels: ["#chan"]), mute(8, channels: nil)]])
        let found = set.networkMuteRule(networkId: 1)
        XCTAssertEqual(found?.rule.id, 8)
        XCTAssertEqual(found?.scope, 1)
        XCTAssertNil(IgnoreSet(byNetwork: [1: [mute(9, channels: ["#chan"])]]).networkMuteRule(networkId: 1))
        // An empty channel list is the same "no channel scope" a nil one is.
        XCTAssertEqual(IgnoreSet(byNetwork: [1: [mute(3, channels: [])]]).networkMuteRule(networkId: 1)?.rule.id, 3)
        // A global one is "everything, everywhere", found from any network with a nil scope.
        let global = IgnoreSet(global: [mute(2)]).networkMuteRule(networkId: 4)
        XCTAssertEqual(global?.rule.id, 2)
        XCTAssertNil(global?.scope)
    }

    // MARK: - The wire

    func testParsesTheSnapshotsChannelNotifyMap() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"snapshot","networks":[{"networkId":7,"state":"connected","nick":"me","channels":[],
         "channelNotify":{"#Loud":{"notifyAlways":true},"&local":{"notifyAlways":true},
                          "#off":{"notifyAlways":false},"#bare":{},"#wrong":true,"":{"notifyAlways":true}}}]}
        """##)
        guard case let .snapshot(networks, _, _, _) = frame else { return XCTFail("expected a snapshot") }
        XCTAssertEqual(networks.first?.notifyAlways, ["#Loud", "&local"])
    }

    func testAMissingOrMalformedChannelNotifyIsNoChannelsAndNeverFatal() {
        for raw in ["", ##","channelNotify":null"##, ##","channelNotify":[]"##, ##","channelNotify":"yes""##] {
            let frame = FrameParser.parseWs(
                ##"{"kind":"snapshot","networks":[{"networkId":7,"state":"connected","nick":"me","channels":[]"##
                    + raw + "}]}"
            )
            guard case let .snapshot(networks, _, _, _) = frame else { return XCTFail("expected a snapshot: \(raw)") }
            XCTAssertEqual(networks.first?.id, 7, raw)
            XCTAssertEqual(networks.first?.notifyAlways, [], raw)
        }
    }

    func testParsesTheChangedFrame() {
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"channel-notify-changed","networkId":7,"target":"#Chan","bufferId":42,"notifyAlways":true}"##),
            .channelNotifyChanged(networkId: 7, target: "#Chan", bufferId: 42, notifyAlways: true)
        )
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"channel-notify-changed","networkId":7,"target":"#Chan","bufferId":null,"notifyAlways":false}"##),
            .channelNotifyChanged(networkId: 7, target: "#Chan", bufferId: nil, notifyAlways: false)
        )
    }

    /// A frame that can't say which channel, or doesn't say which way, changes nothing. An
    /// absent `notifyAlways` in particular is not a statement that it is off.
    func testAChangedFrameMissingAHalfIsRefused() {
        for bad in [
            ##"{"kind":"channel-notify-changed","target":"#chan","notifyAlways":true}"##,
            ##"{"kind":"channel-notify-changed","networkId":null,"target":"#chan","notifyAlways":true}"##,
            ##"{"kind":"channel-notify-changed","networkId":7,"notifyAlways":true}"##,
            ##"{"kind":"channel-notify-changed","networkId":7,"target":"","notifyAlways":true}"##,
            ##"{"kind":"channel-notify-changed","networkId":7,"target":"#chan"}"##,
            ##"{"kind":"channel-notify-changed","networkId":7,"target":"#chan","notifyAlways":"yes"}"##,
        ] {
            XCTAssertEqual(FrameParser.parseWs(bad), .ignored, bad)
        }
    }

    func testTheVerbCarriesTheChannelAndTheFlag() {
        let frame = LurkerClient.channelNotifyFrame(networkId: 3, target: "&local", notifyAlways: true)
        XCTAssertEqual(frame["type"] as? String, "set-channel-notify-always")
        XCTAssertEqual(frame["networkId"] as? Int, 3)
        XCTAssertEqual(frame["target"] as? String, "&local")
        XCTAssertEqual(frame["notifyAlways"] as? Bool, true)
        XCTAssertEqual(frame.count, 4)
    }

    // MARK: - The store

    private func snapshot(_ notifyAlways: [String], channels: [String] = ["#chan", "#other"]) -> ServerFrame {
        .snapshot(
            [NetworkSnapshot(
                id: 1, state: .connected, nick: "me",
                channels: channels.map { ChannelSnapshot(name: $0, topic: nil, members: []) },
                notifyAlways: notifyAlways
            )],
            globalIgnores: [], uploadLimits: .unstated
        )
    }

    func testTheSnapshotSeedsTheFlagsAndReplacesThemWholesale() {
        let store = LurkerStore()
        store.apply(snapshot(["#Chan"]))
        XCTAssertTrue(store.state.notifiesAlways(networkId: 1, target: "#chan"), "folded like a buffer key")
        XCTAssertTrue(store.state.notifiesAlways(networkId: 1, target: "#CHAN"))
        XCTAssertFalse(store.state.notifiesAlways(networkId: 1, target: "#other"))
        XCTAssertFalse(store.state.notifiesAlways(networkId: 2, target: "#chan"), "scoped to its network")

        // Turned off on the web while this device was away: it has to read off here.
        store.apply(snapshot(["#other"]))
        XCTAssertFalse(store.state.notifiesAlways(networkId: 1, target: "#chan"))
        XCTAssertTrue(store.state.notifiesAlways(networkId: 1, target: "#other"))
    }

    func testTheChangedFramePatchesOneChannel() {
        let store = LurkerStore()
        store.apply(snapshot(["#other"]))
        store.apply(.channelNotifyChanged(networkId: 1, target: "#Chan", bufferId: nil, notifyAlways: true))
        XCTAssertTrue(store.state.notifiesAlways(networkId: 1, target: "#chan"))
        XCTAssertTrue(store.state.notifiesAlways(networkId: 1, target: "#other"), "the others stand")

        store.apply(.channelNotifyChanged(networkId: 1, target: "#CHAN", bufferId: nil, notifyAlways: false))
        XCTAssertFalse(store.state.notifiesAlways(networkId: 1, target: "#chan"))
        XCTAssertEqual(store.state.notifyAlways.count, 1, "off drops the entry rather than storing a false")
    }

    /// The server keeps the flag when a channel is closed and reads it again on a rejoin, so
    /// the store keeps it too: dropped here, a rejoined channel would read "Highlights only"
    /// while every message still notified.
    func testAClosedBufferKeepsItsFlag() {
        let store = LurkerStore()
        store.apply(snapshot(["#chan", "#other"]))
        store.apply(.bufferClosed(networkId: 1, target: "#Chan"))
        XCTAssertTrue(store.state.notifiesAlways(networkId: 1, target: "#chan"))
        XCTAssertTrue(store.state.notifiesAlways(networkId: 1, target: "#other"))
    }

    func testARenamedBufferCarriesItsFlag() {
        let store = LurkerStore()
        store.apply(snapshot(["#chan"]))
        store.apply(.bufferRenamed(
            networkId: 1, from: "#chan", to: "#renamed", bufferId: nil, merged: false, mergedFromBufferId: nil
        ))
        XCTAssertFalse(store.state.notifiesAlways(networkId: 1, target: "#chan"))
        XCTAssertTrue(store.state.notifiesAlways(networkId: 1, target: "#renamed"))
    }

    func testARemovedNetworkTakesItsFlagsWithIt() {
        let store = LurkerStore()
        // `#gone` has no buffer row here, so only the network sweep can reach it.
        store.apply(snapshot(["#chan", "#gone"]))
        store.apply(.channelNotifyChanged(networkId: 11, target: "#chan", bufferId: nil, notifyAlways: true))
        store.apply(.networks([]))
        XCTAssertFalse(store.state.notifiesAlways(networkId: 1, target: "#chan"))
        XCTAssertFalse(store.state.notifiesAlways(networkId: 1, target: "#gone"))
        XCTAssertTrue(
            store.state.notifiesAlways(networkId: 11, target: "#chan"),
            "network 11 is not network 1: the sweep matches the whole id"
        )
    }

    func testTheStateReadsARungFromBothStores() {
        let store = LurkerStore()
        store.apply(snapshot([]))
        let scope = NotifyLadder.Scope.channel(networkId: 1, target: "#chan")
        XCTAssertEqual(store.state.notifyRung(for: scope), .highlights)

        store.apply(.ignoreListUpdated(networkId: 1, rules: [mute(5, channels: ["#chan"], levels: ["NONOTIFY"])]))
        XCTAssertEqual(store.state.notifyRung(for: scope), .nothing)
        XCTAssertEqual(store.state.notifyRung(for: .network(networkId: 1)), .highlights, "a channel's rule")

        store.apply(.channelNotifyChanged(networkId: 1, target: "#chan", bufferId: nil, notifyAlways: true))
        XCTAssertEqual(store.state.notifyRung(for: scope), .all)
        XCTAssertEqual(
            store.state.notifyPlan(to: .highlights, for: scope),
            [.setNotifyAlways(networkId: 1, target: "#chan", notifyAlways: false), .removeRule(id: 5, scope: 1)]
        )
    }

    // MARK: - Picking a rung

    /// Its own Keychain service and defaults suite; connected, with one channel.
    private func viewModel() -> ChatViewModel {
        let model = ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.notifyladder"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.notifyladder")!)
        )
        model.handle(.socketOpen)
        model.handle(snapshot([], channels: ["#chan"]))
        return model
    }

    private func recording(_ model: ChatViewModel, answering: Bool = true) -> () -> [NotifyLadder.Step] {
        final class Box { var steps: [NotifyLadder.Step] = [] }
        let box = Box()
        model.notifyStepSeam = { step in
            box.steps.append(step)
            return answering
        }
        return { box.steps }
    }

    /// A rung is a target: it reconciles against the state at the tap, not as it was when the
    /// menu opened (web #1136).
    func testPickingARungClearsNotifyAlwaysSetElsewhereWhileTheMenuWasOpen() {
        let model = viewModel()
        let sent = recording(model)
        let scope = NotifyLadder.Scope.channel(networkId: 1, target: "#chan")
        // What a menu drawn now would say: already on Highlights only, nothing to send.
        XCTAssertEqual(model.state.notifyPlan(to: .highlights, for: scope), [])
        // Another device turns All messages on while that menu sits open.
        model.handle(.channelNotifyChanged(networkId: 1, target: "#chan", bufferId: nil, notifyAlways: true))
        XCTAssertTrue(model.setNotifyRung(.highlights, for: scope))
        XCTAssertEqual(sent(), [.setNotifyAlways(networkId: 1, target: "#chan", notifyAlways: false)])
    }

    func testPickingARungLeavesNotifyAlwaysAloneWhenItAlreadyMatchesAtTheTap() {
        let model = viewModel()
        let sent = recording(model)
        let scope = NotifyLadder.Scope.channel(networkId: 1, target: "#chan")
        model.handle(.channelNotifyChanged(networkId: 1, target: "#chan", bufferId: nil, notifyAlways: true))
        // Turned off elsewhere; Highlights only now has nothing to change.
        model.handle(.channelNotifyChanged(networkId: 1, target: "#chan", bufferId: nil, notifyAlways: false))
        XCTAssertTrue(model.setNotifyRung(.highlights, for: scope), "nothing to do is not a failure")
        XCTAssertEqual(sent(), [])
    }

    func testPickingARungSendsEveryStepInOrder() {
        let model = viewModel()
        let sent = recording(model)
        model.handle(.ignoreListUpdated(networkId: nil, rules: [mute(7, channels: ["#chan"])]))
        XCTAssertTrue(model.setNotifyRung(.all, for: .channel(networkId: 1, target: "#chan")))
        XCTAssertEqual(
            sent(),
            [.setNotifyAlways(networkId: 1, target: "#chan", notifyAlways: true), .removeRule(id: 7, scope: nil)]
        )
    }

    /// Muted then All messages, tapped before the first echo: the second plan would see no rule
    /// and send only the flag, leaving both standing.
    func testASecondPickWaitsForTheFirstOnesEcho() {
        let model = viewModel()
        let sent = recording(model)
        let scope = NotifyLadder.Scope.channel(networkId: 1, target: "#chan")
        let start = Date()
        XCTAssertTrue(model.setNotifyRung(.muted, for: scope, now: start))
        let first = sent()
        XCTAssertEqual(first.count, 1)

        XCTAssertTrue(model.setNotifyRung(.all, for: scope, now: start.addingTimeInterval(0.5)), "dropped, not failed")
        XCTAssertEqual(sent(), first, "nothing more went out")

        // The echo lands: the channel is on Muted, and the next pick is planned against that.
        model.handle(.ignoreListUpdated(networkId: 1, rules: [mute(9, channels: ["#chan"])]))
        XCTAssertTrue(model.setNotifyRung(.all, for: scope, now: start.addingTimeInterval(1)))
        XCTAssertEqual(
            Array(sent().dropFirst(first.count)),
            [.setNotifyAlways(networkId: 1, target: "#chan", notifyAlways: true), .removeRule(id: 9, scope: 1)]
        )
    }

    /// A pick the server refused, or whose echo was lost, must not lock the ladder for good.
    func testAPickThatNeverSettlesStopsHoldingTheLadderAfterTheWindow() {
        let model = viewModel()
        let sent = recording(model)
        let scope = NotifyLadder.Scope.channel(networkId: 1, target: "#chan")
        let start = Date()
        XCTAssertTrue(model.setNotifyRung(.muted, for: scope, now: start))
        let late = start.addingTimeInterval(ChatViewModel.notifySettleWindow + 0.1)
        XCTAssertTrue(model.setNotifyRung(.all, for: scope, now: late))
        XCTAssertEqual(sent().last, .setNotifyAlways(networkId: 1, target: "#chan", notifyAlways: true))
    }

    /// One buffer waiting does not hold another.
    func testAPendingPickHoldsOnlyItsOwnBuffer() {
        let model = viewModel()
        let sent = recording(model)
        let start = Date()
        XCTAssertTrue(model.setNotifyRung(.muted, for: .channel(networkId: 1, target: "#chan"), now: start))
        XCTAssertTrue(model.setNotifyRung(.muted, for: .channel(networkId: 1, target: "#other"), now: start))
        XCTAssertEqual(sent().count, 2)
    }

    /// Carrying on past a remove that never left would add a second rule beside the first.
    func testAStepThatGoesNowhereStopsThePlanAndIsReported() {
        let model = viewModel()
        let sent = recording(model, answering: false)
        model.handle(.ignoreListUpdated(networkId: 1, rules: [mute(5, channels: ["#chan"], levels: ["NONOTIFY"])]))
        XCTAssertFalse(model.setNotifyRung(.muted, for: .channel(networkId: 1, target: "#chan")))
        XCTAssertEqual(sent(), [.removeRule(id: 5, scope: 1)])
    }

    /// Before the socket opens nothing can reach the server, whatever a seam would say.
    func testPickingARungOfflineSendsNothingAndSaysSo() {
        let model = ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.notifyladder"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.notifyladder")!)
        )
        let sent = recording(model)
        XCTAssertFalse(model.setNotifyRung(.muted, for: .channel(networkId: 1, target: "#chan")))
        XCTAssertEqual(sent(), [])

        // And with no seam, on a model that reads connected but has no socket: the real sends
        // answer false.
        XCTAssertFalse(viewModel().setNotifyRung(.muted, for: .network(networkId: 1)))
    }
}

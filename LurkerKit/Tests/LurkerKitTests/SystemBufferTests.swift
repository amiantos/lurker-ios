// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The system buffer rendered empty for its whole life because the chat screen filtered
/// every buffer by `isSpeech`, and *no* system line is speech. These lock the contract
/// that made that a silent failure rather than a crash.
final class SystemBufferTests: XCTestCase {

    // MARK: - The bug

    func testSystemBufferRendersSystemLines() {
        // The regression. Every line the server writes to the system buffer is
        // `type: "system"`, so a buffer that only renders speech renders nothing.
        XCTAssertTrue(BufferKind.system.renders(.system))
        XCTAssertFalse(EventType.system.isSpeech, "the type that IS the system buffer is not speech")
    }

    func testChannelsStillRenderOnlySpeech() {
        for kind in [BufferKind.channel, .dm, .server] {
            XCTAssertTrue(kind.renders(.message), "\(kind)")
            XCTAssertTrue(kind.renders(.action), "\(kind)")
            XCTAssertTrue(kind.renders(.notice), "\(kind)")
            XCTAssertFalse(kind.renders(.join), "\(kind)")
            XCTAssertFalse(kind.renders(.system), "\(kind)")
        }
    }

    func testSystemBufferRendersNothingButSystemLines() {
        XCTAssertFalse(BufferKind.system.renders(.message))
        XCTAssertFalse(BufferKind.system.renders(.join))
    }

    // MARK: - Severity rides `level`, not `type`

    func testAnErrorSystemLineIsStillTypeSystem() {
        // The server does NOT encode severity in `type` — reading `type: "error"` off a
        // system line would mean styling nothing, and filtering for it would mean
        // dropping the line entirely.
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":null,"target":":system:","type":"system","level":"error","text":"connect failed","time":"2026-07-16T10:00:00.000Z"}"##
        )
        guard case let .live(networkId, target, message) = frame else {
            return XCTFail("expected live, got \(frame)")
        }
        XCTAssertNil(networkId)
        XCTAssertEqual(target, ":system:")
        XCTAssertEqual(message.type, .system)
        XCTAssertEqual(message.level, .error)
        XCTAssertTrue(BufferKind.of(networkId: networkId, target: target).renders(message.type))
    }

    func testSystemLineDefaultsToInfoWhenLevelIsAbsentOrJunk() {
        let absent = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":null,"target":":system:","type":"system","text":"hello"}"##
        )
        guard case let .live(_, _, message) = absent else { return XCTFail("expected live") }
        XCTAssertEqual(message.level, .info, "matches the server's own default")

        let junk = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":null,"target":":system:","type":"system","level":"catastrophe","text":"hi"}"##
        )
        guard case let .live(_, _, junkMessage) = junk else { return XCTFail("expected live") }
        XCTAssertEqual(junkMessage.level, .info, "an unknown level must not drop the line")
    }

    func testLevelIsOnlySetForSystemLines() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#lurker","type":"message","nick":"alice","text":"hi"}"##
        )
        guard case let .live(_, _, message) = frame else { return XCTFail("expected live") }
        XCTAssertNil(message.level, "a channel message has no severity")
    }

    func testSeverityAndOriginAreBothSystemOnlyEvenIfTheWireSaysOtherwise() {
        // `systemLineToEvent` is the only producer of either field and only ever builds
        // `type: "system"` events, so seeing them on anything else means the wire is not
        // what we think it is — reading them there would invent a meaning it doesn't have.
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#lurker","type":"message","nick":"alice","text":"hi","level":"error","originNetworkId":7}"##
        )
        guard case let .live(_, _, message) = frame else { return XCTFail("expected live") }
        XCTAssertNil(message.level)
        XCTAssertNil(message.originNetworkId)
    }

    // MARK: - originNetworkId

    func testSystemLineCarriesTheNetworkItIsAbout() {
        // The system buffer is app-scoped (networkId nil), so this is the only thing that
        // lets a line say which network it's talking about.
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":null,"originNetworkId":7,"target":":system:","type":"system","level":"warn","text":"reconnecting"}"##
        )
        guard case let .live(networkId, _, message) = frame else { return XCTFail("expected live") }
        XCTAssertNil(networkId, "the buffer is app-scoped…")
        XCTAssertEqual(message.originNetworkId, 7, "…but the line is about network 7")
        XCTAssertEqual(message.level, .warn)
    }

    // MARK: - Types the server sends that the client didn't model

    func testTypesTheServerSendsThatTheClientDidNotModel() {
        // The server emits these; the enum used to lack them, so they all folded into
        // `.other` and lost their identity on the way in.
        for raw in ["motd", "invite", "e2e", "ctcp"] {
            // `##"…"##`, not `#"…"#`: the channel name puts a literal `"#` in the JSON,
            // which would otherwise close a single-pound raw string right there.
            let json = ##"{"kind":"irc","networkId":1,"target":"#lurker","type":"\##(raw)","text":"x"}"##
            guard case let .live(_, _, message) = FrameParser.parseWs(json) else {
                return XCTFail("expected live for \(raw)")
            }
            XCTAssertEqual(message.type, EventType(rawValue: raw), "\(raw) should parse to itself")
            XCTAssertNotEqual(message.type, .other, "\(raw) is modelled now")
        }
    }

    func testAGenuinelyUnknownTypeStillFoldsToOther() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#lurker","type":"telepathy","text":"x"}"##
        )
        guard case let .live(_, _, message) = frame else { return XCTFail("expected live") }
        XCTAssertEqual(message.type, .other)
    }

    // MARK: - The system backlog is a latest slice, never a resume delta

    func testTheSystemBacklogReplacesEvenThoughItSaysResetFalse() {
        // `buildSystemBacklog` hardcodes `reset: false` on EVERY connect — it always ships
        // a full latest slice. Reading that the way a *network* buffer's `reset` is read
        // ("reset present and false → this is a resume delta → append") is what corrupts
        // the buffer, so the system buffer must ignore the field entirely.
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":null,"target":":system:","reset":false,"hasMoreOlder":false,"events":[{"id":5,"type":"system","text":"hi"}]}"##
        )
        guard case let .backlog(_, _, _, append) = frame else { return XCTFail("expected backlog") }
        XCTAssertFalse(append, "the system backlog is a latest slice — replace, don't append")
    }

    func testANetworkResumeSliceStillAppends() {
        // The exception above must not cost channels their resume path.
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","reset":false,"hasMoreOlder":false,"events":[{"id":5,"type":"message","nick":"a","text":"hi"}]}"##
        )
        guard case let .backlog(_, _, _, append) = frame else { return XCTFail("expected backlog") }
        XCTAssertTrue(append, "reset:false on a network buffer IS a resume delta")
    }

    func testAnOversizedNetworkGapStillReplaces() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","reset":true,"hasMoreOlder":false,"events":[{"id":5,"type":"message","nick":"a","text":"hi"}]}"##
        )
        guard case let .backlog(_, _, _, append) = frame else { return XCTFail("expected backlog") }
        XCTAssertFalse(append, "reset:true means the gap overflowed — replace or splice a hole")
    }

    @MainActor
    func testALiveSystemLineBeatingTheBacklogDoesNotShoveHistoryBelowIt() {
        // The bug this guards: a system line logged at connect ("connecting to libera")
        // can land before the backlog. Appending the backlog then renders the entire
        // history *underneath* a line that came after all of it.
        let store = LurkerStore()
        store.apply(FrameParser.parseWs(
            ##"{"kind":"irc","networkId":null,"target":":system:","type":"system","id":101,"text":"connecting"}"##
        ))
        store.apply(FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":null,"target":":system:","reset":false,"hasMoreOlder":false,"events":[{"id":51,"type":"system","text":"older"},{"id":52,"type":"system","text":"newer"}]}"##
        ))
        let ids = store.state.messages[Buffer.system.key.id]?.map(\.id) ?? []
        XCTAssertEqual(ids, [51, 52, 101], "history first, then the live line that outran it")
    }

    // MARK: - What the server will actually answer

    func testOnlyChannelsAndDmsHydrateOnDemand() {
        // `handleOpenBuffer` drops the request for the system buffer and `:server:` logs
        // and never replies, so asking latches a wait on a reply that isn't coming.
        XCTAssertTrue(BufferKind.channel.hydratesOnDemand)
        XCTAssertTrue(BufferKind.dm.hydratesOnDemand)
        XCTAssertFalse(BufferKind.system.hydratesOnDemand, "server: `if (!networkId) return`")
        XCTAssertFalse(BufferKind.server.hydratesOnDemand, "server: `if (target.startsWith(':server:')) return`")
    }

    // MARK: - Naming

    func testTheSystemBufferIsCalledLurkerNotItsSentinel() {
        // `:system:` is a wire sentinel, not something to show anyone.
        XCTAssertEqual(Buffer.system.displayName(), "Lurker")
        XCTAssertEqual(Buffer.system.displayName(networkName: "libera"), "Lurker")
    }

    func testAServerLogPrefersItsNetworksName() {
        // Two copies of this lived in two view controllers and disagreed: the switcher
        // said "Server" while the pill it opened said "libera".
        let log = Buffer(networkId: 1, target: ":server:libera", kind: .server)
        XCTAssertEqual(log.displayName(networkName: "libera"), "libera")
        XCTAssertEqual(log.displayName(), "Server", "…and falls back when the roster hasn't landed")
    }

    func testChannelsAndDmsAreJustTheirTarget() {
        let channel = Buffer(networkId: 1, target: "#lurker", kind: .channel)
        let dm = Buffer(networkId: 1, target: "alice", kind: .dm)
        XCTAssertEqual(channel.displayName(networkName: "libera"), "#lurker")
        XCTAssertEqual(dm.displayName(networkName: "libera"), "alice")
    }

    // MARK: - The buffer itself

    func testTheSystemBufferIsConstructibleWithoutTheServer() {
        // It's the launch screen, so it must exist before any frame arrives.
        XCTAssertEqual(Buffer.system.kind, .system)
        XCTAssertNil(Buffer.system.networkId)
        XCTAssertEqual(Buffer.system.key.id, "sys::" + Buffer.systemTarget)
    }

    func testTheSyntheticSystemBufferMatchesTheServersOwn() {
        // If these keys ever diverged, the launch screen would sit on an empty buffer
        // forever while the real one filled up beside it.
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":null,"target":":system:","hasMoreOlder":false,"events":[]}"##
        )
        guard case let .backlog(buffer, _, _, _) = frame else { return XCTFail("expected backlog") }
        XCTAssertEqual(buffer.key.id, Buffer.system.key.id)
        XCTAssertEqual(buffer.kind, Buffer.system.kind)
    }
}

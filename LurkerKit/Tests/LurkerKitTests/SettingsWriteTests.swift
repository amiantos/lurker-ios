// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// A REST reply lands only in the session that sent it (`LurkerClient.deliver`). A sign-out while
/// it was out cleared the store and the settings cache; the departing account's settings, values
/// and roster must not come back into them for whoever signs in next.
@MainActor
final class SettingsWriteTests: XCTestCase {
    private func count(_ frames: [ServerFrame], _ matches: (ServerFrame) -> Bool) -> Int {
        frames.filter(matches).count
    }

    private func isValues(_ frame: ServerFrame) -> Bool {
        if case .settingsValues = frame { true } else { false }
    }

    func testAReplyLandsInTheSessionThatAsked() async throws {
        let server = try await OneStatusServer(status: 200, body: #"{"values":{"chat.smart_filter":true}}"#)
        var frames: [ServerFrame] = []
        let client = LurkerClient(onFrame: { frames.append($0) })
        client.restore(server: server.url, token: "live")
        let error = await client.updateSettings(["chat.smart_filter": .bool(true)])
        XCTAssertNil(error)
        XCTAssertEqual(count(frames, isValues), 1)
    }

    func testAWriteReplyForASignedOutSessionIsDropped() async throws {
        let server = try await OneStatusServer(status: 200, body: #"{"values":{"chat.smart_filter":true}}"#, gated: true)
        var frames: [ServerFrame] = []
        let client = LurkerClient(onFrame: { frames.append($0) })
        client.restore(server: server.url, token: "departing")
        let write = Task { await client.updateSettings(["system.timezone": .string("Asia/Tokyo")]) }
        try await waitUntil { server.requests.count == 1 }
        client.logout()
        server.open()
        // Nothing to say to a screen that's gone: no error, and nothing applied.
        let error = await write.value
        XCTAssertNil(error)
        XCTAssertEqual(count(frames, isValues), 0)
    }

    func testAFailedWriteForASignedOutSessionSaysNothing() async throws {
        let server = try await OneStatusServer(status: 400, body: #"{"error":"no"}"#, gated: true)
        let client = LurkerClient(onFrame: { _ in })
        client.restore(server: server.url, token: "departing")
        let write = Task { await client.updateSettings(["system.timezone": .string("Asia/Tokyo")]) }
        try await waitUntil { server.requests.count == 1 }
        client.logout()
        server.open()
        let error = await write.value
        XCTAssertNil(error)
    }

    func testABootstrapForASignedOutSessionIsDropped() async throws {
        let server = try await OneStatusServer(status: 200, body: #"{"registry":[],"values":{}}"#, gated: true)
        var frames: [ServerFrame] = []
        let client = LurkerClient(onFrame: { frames.append($0) })
        client.restore(server: server.url, token: "departing")
        let read = Task { await client.fetchSettings() }
        try await waitUntil { server.requests.count == 1 }
        client.logout()
        server.open()
        await read.value
        XCTAssertEqual(count(frames) { if case .settingsBootstrap = $0 { true } else { false } }, 0)
    }

    func testARosterForASignedOutSessionIsDropped() async throws {
        let server = try await OneStatusServer(status: 200, body: #"{"networks":[]}"#, gated: true)
        var frames: [ServerFrame] = []
        let client = LurkerClient(onFrame: { frames.append($0) })
        client.restore(server: server.url, token: "departing")
        let read = Task { await client.fetchNetworks() }
        try await waitUntil { server.requests.count == 1 }
        client.logout()
        server.open()
        _ = await read.value
        XCTAssertEqual(count(frames) { if case .networks = $0 { true } else { false } }, 0)
    }

    /// Not just a sign-out: a sign-in to another account while the read was out, too.
    func testARosterForAReplacedSessionIsDropped() async throws {
        let server = try await OneStatusServer(status: 200, body: #"{"networks":[]}"#, gated: true)
        var frames: [ServerFrame] = []
        let client = LurkerClient(onFrame: { frames.append($0) })
        client.restore(server: server.url, token: "departing")
        let read = Task { await client.fetchNetworks() }
        try await waitUntil { server.requests.count == 1 }
        client.logout()
        client.restore(server: server.url, token: "next")
        server.open()
        _ = await read.value
        XCTAssertEqual(count(frames) { if case .networks = $0 { true } else { false } }, 0)
    }

    /// The phone's time zone write: the server stores it and echoes it; its reply, the whole stored
    /// set, would replace the store's and could undo a setting changed meanwhile.
    func testAWriteThatAppliesNoReplyLeavesTheStoreToTheEcho() async throws {
        let server = try await OneStatusServer(status: 200, body: #"{"values":{"system.timezone":"Asia/Tokyo"}}"#)
        var frames: [ServerFrame] = []
        let client = LurkerClient(onFrame: { frames.append($0) })
        client.restore(server: server.url, token: "live")
        let error = await client.updateSettings(["system.timezone": .string("Asia/Tokyo")], applyingReply: false)
        XCTAssertNil(error)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(count(frames, isValues), 0)
    }

    /// The control for the two above: the same reads, answered while the session lives, do land.
    func testReadsLandInTheSessionThatAsked() async throws {
        let server = try await OneStatusServer(status: 200, body: #"{"registry":[],"values":{},"networks":[]}"#)
        var frames: [ServerFrame] = []
        let client = LurkerClient(onFrame: { frames.append($0) })
        client.restore(server: server.url, token: "live")
        await client.fetchSettings()
        _ = await client.fetchNetworks()
        XCTAssertEqual(count(frames) { if case .settingsBootstrap = $0 { true } else { false } }, 1)
        XCTAssertEqual(count(frames) { if case .networks = $0 { true } else { false } }, 1)
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// A settings write's reply lands only in the session that sent it. A sign-out while it was out
/// cleared the store and the settings cache; the departing account's values must not come back.
@MainActor
final class SettingsWriteTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "timed out")
    }

    private func settingsValues(_ frames: [ServerFrame]) -> Int {
        frames.filter { if case .settingsValues = $0 { true } else { false } }.count
    }

    func testAReplyLandsInTheSessionThatAsked() async throws {
        let server = try await OneStatusServer(status: 200, body: #"{"values":{"chat.smart_filter":true}}"#)
        var frames: [ServerFrame] = []
        let client = LurkerClient(onFrame: { frames.append($0) })
        client.restore(server: server.url, token: "live")
        let error = await client.updateSettings(["chat.smart_filter": .bool(true)])
        XCTAssertNil(error)
        XCTAssertEqual(settingsValues(frames), 1)
    }

    func testAReplyForASignedOutSessionIsDropped() async throws {
        let server = try await OneStatusServer(status: 200, body: #"{"values":{"chat.smart_filter":true}}"#, gated: true)
        var frames: [ServerFrame] = []
        let client = LurkerClient(onFrame: { frames.append($0) })
        client.restore(server: server.url, token: "departing")
        let write = Task { await client.updateSettings(["system.timezone": .string("Asia/Tokyo")]) }
        try await waitUntil { server.requests.count == 1 }
        // Signed out while the write was out.
        client.close()
        server.open()
        _ = await write.value
        XCTAssertEqual(settingsValues(frames), 0)
    }
}

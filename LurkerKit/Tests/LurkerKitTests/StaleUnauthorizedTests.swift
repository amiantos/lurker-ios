// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// A 401 ends the session only when it answered the token in use now.
@MainActor
final class StaleUnauthorizedTests: XCTestCase {

    private var frames: [ServerFrame] = []

    private func signedIn(as token: String) -> LurkerClient {
        let client = LurkerClient(onFrame: { [unowned self] frame in frames.append(frame) })
        client.restore(server: "https://app.lurker.chat", token: token)
        return client
    }

    /// Signed out and back in while a request made with the old token was still out.
    func testALateAnswerToTheOldTokenLeavesTheNewSessionAlone() {
        let client = signedIn(as: "old")
        client.close()
        client.restore(server: "https://app.lurker.chat", token: "new")
        client.reportUnauthorized(sentWith: "old")
        XCTAssertEqual(frames, [])
    }

    func testA401ForTheCurrentTokenEndsTheSession() {
        let client = signedIn(as: "current")
        client.reportUnauthorized(sentWith: "current")
        XCTAssertEqual(frames, [.unauthorized])
    }

    /// Signed out with nothing new yet, so there's no session left to end.
    func testA401AfterSignOutIsIgnored() {
        let client = signedIn(as: "old")
        client.close()
        client.reportUnauthorized(sentWith: "old")
        XCTAssertEqual(frames, [])
    }
}

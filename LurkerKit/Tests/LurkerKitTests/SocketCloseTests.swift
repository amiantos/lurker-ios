// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Which socket endings sign the user out, with the values `URLSessionWebSocketTask` reports
/// for each (measured against lurker's own close and refusal bytes).
final class SocketCloseTests: XCTestCase {

    /// Revoking the app in Settings closes its open socket with 4001. The upgrade's status is
    /// still the 101 that opened it, which is why the status alone kept the app reconnecting.
    func testARevokedSocketEndsTheSession() {
        XCTAssertTrue(LurkerClient.closeEndsSession(status: 101, closeCode: 4001))
    }

    func testARefusedUpgradeEndsTheSession() {
        XCTAssertTrue(LurkerClient.closeEndsSession(status: 401, closeCode: 0))
    }

    func testADroppedConnectionReconnects() {
        XCTAssertFalse(LurkerClient.closeEndsSession(status: 101, closeCode: 0))
        XCTAssertFalse(LurkerClient.closeEndsSession(status: 101, closeCode: 1001))
        XCTAssertFalse(LurkerClient.closeEndsSession(status: nil, closeCode: 0))
        XCTAssertFalse(LurkerClient.closeEndsSession(status: 502, closeCode: 0))
    }
}

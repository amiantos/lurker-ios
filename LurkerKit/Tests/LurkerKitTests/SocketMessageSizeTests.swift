// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The socket takes a frame of any size (#257). `URLSessionWebSocketTask` defaults to 1 MiB,
/// and the connect snapshot — one message carrying every live channel's member list — passed
/// that on an account with ~20 networks and ~100 channels. The first receive then failed before
/// any frame landed, and the app sat on "Connecting…" re-asking for the same snapshot.
@MainActor
final class SocketMessageSizeTests: XCTestCase {

    /// `reconnect` opens the socket without waiting on the roster read, so the task exists the
    /// moment it returns. Nothing listens on the address; the task fails on its own and that
    /// ending is just a `socketClosed` frame.
    func testTheSocketHasNoMessageSizeCap() {
        let client = LurkerClient(onFrame: { _ in })
        client.restore(server: "http://127.0.0.1:1", token: "t")
        client.reconnect(since: 0)
        let task = try? XCTUnwrap(client.socket)
        XCTAssertEqual(task?.maximumMessageSize, Int.max)
        XCTAssertNotEqual(task?.maximumMessageSize, 1_048_576, "the Foundation default is back")
        client.close()
    }
}

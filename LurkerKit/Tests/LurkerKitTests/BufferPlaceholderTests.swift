// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// What the message list shows when it has no messages: still-loading vs. genuinely-empty,
/// which a blank list can't tell apart.
final class BufferPlaceholderTests: XCTestCase {

    func testMessagesPresentMeansNoPlaceholder() {
        // Whatever the connection is doing, if there are lines to show, show them.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: true, hydrated: false, hydratesOnDemand: true, connection: .connecting),
            .none
        )
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: true, hydrated: true, hydratesOnDemand: false, connection: .connected),
            .none
        )
    }

    // MARK: - On-demand buffers (channels, DMs)

    func testOnDemandBufferLoadsUntilHydrated() {
        // A channel/DM arrives as a shell and isn't read until its open-buffer reply lands.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: false, hydratesOnDemand: true, connection: .connected),
            .loading
        )
    }

    func testOnDemandBufferHydratedButEmptyIsEmpty() {
        // The server read the history and there was none — a just-joined channel. Real, not
        // a failure. Note the socket can even be down by now; hydration is a fact we keep.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: true, hydratesOnDemand: true, connection: .reconnecting),
            .empty
        )
    }

    // MARK: - Off-demand buffers (system, server logs)

    func testOffDemandBufferLoadsUntilSocketUp() {
        // System/server history rides the connect backlog, so before the socket is up
        // "empty" would be a lie — it just hasn't arrived.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: false, hydratesOnDemand: false, connection: .connecting),
            .loading
        )
    }

    func testOffDemandBufferEmptyOnceConnected() {
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: false, hydratesOnDemand: false, connection: .connected),
            .empty
        )
    }
}

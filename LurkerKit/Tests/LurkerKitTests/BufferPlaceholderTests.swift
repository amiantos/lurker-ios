// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// What the message list shows when it has no messages: still-loading vs. genuinely-empty,
/// which a blank list can't tell apart.
final class BufferPlaceholderTests: XCTestCase {

    func testMessagesPresentMeansNoPlaceholder() {
        // Whatever else is true, if there are lines to show, show them.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: true, hydrated: false, hydratesOnDemand: true, bufferExists: false),
            .none
        )
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: true, hydrated: true, hydratesOnDemand: false, bufferExists: true),
            .none
        )
    }

    // MARK: - On-demand buffers (channels, DMs) — key off `hydrated`

    func testOnDemandBufferLoadsUntilHydrated() {
        // A channel/DM arrives as a shell (the row exists!) and isn't read until its
        // open-buffer reply lands — so row-existence can't tell them apart, only hydration.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: false, hydratesOnDemand: true, bufferExists: true),
            .loading
        )
    }

    func testOnDemandBufferHydratedButEmptyIsEmpty() {
        // The server read the history and there was none — a just-joined channel. Real, not
        // a failure.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: true, hydratesOnDemand: true, bufferExists: true),
            .empty
        )
    }

    // MARK: - Off-demand buffers (system, server logs) — key off row existence

    func testOffDemandBufferLoadsUntilItsRowMaterializes() {
        // The system/server row is created BY its connect backlog. Before that the row is
        // absent — and the socket can already read `.connected`, so keying off the socket
        // would flash `.empty` on the launch screen in the gap. Row absent → still loading.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: false, hydratesOnDemand: false, bufferExists: false),
            .loading
        )
    }

    func testOffDemandBufferEmptyOnceItsRowExists() {
        // Backlog landed and the row is here. An empty system buffer looks exactly like
        // this.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: true, hydratesOnDemand: false, bufferExists: true),
            .empty
        )
    }

    func testEmptyServerLogIsEmptyNotStuckLoading() {
        // The regression guard: an empty `:server:` backlog never sets `hydrated` (the
        // server omits `hasMoreOlder`, the parser defaults it true) and `:server:` can't
        // hydrate on demand to fix that — so a `hydrated`-keyed rule would spin forever.
        // Row existence is what saves it.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: false, hydratesOnDemand: false, bufferExists: true),
            .empty
        )
    }
}

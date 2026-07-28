// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The rule that decides what unit we ask history pages to be sized in (#10).
///
/// One rule, one place, because getting it backwards is silent in both directions: asking for
/// `.event` while we consolidate is the blank-first-screenful bug this exists to fix, and asking
/// for `.renderable` while we don't drags the server's whole scan window into a page the reader
/// then sees in full. Neither shows up as an error anywhere.
final class HistoryCountByTests: XCTestCase {

    private func settings(consolidate: Bool?) -> Settings {
        var s = Settings()
        guard let consolidate else { return s }
        s.replaceValues(["chat.consolidate_joins": .bool(consolidate)])
        return s
    }

    func testAsksForRenderablePagesWhileConsolidating() {
        XCTAssertEqual(HistoryCountBy.forRendering(settings(consolidate: true)), .renderable)
    }

    func testFallsBackToEventCountingWhenConsolidationIsOff() {
        XCTAssertEqual(HistoryCountBy.forRendering(settings(consolidate: false)), .event)
    }

    /// Before settings bootstrap lands — and against a server too old to know the key — we
    /// consolidate by default, so the unit we ask for has to default the same way. A mismatch
    /// here would only show on the very first buffer the user opens after launch, which is
    /// exactly the fetch this feature is about.
    func testDefaultsToRenderableBeforeBootstrap() {
        XCTAssertEqual(HistoryCountBy.forRendering(settings(consolidate: nil)), .renderable)
    }

    /// It travels on the wire as its raw value, so the spelling is protocol, not an enum name.
    func testWireSpelling() {
        XCTAssertEqual(HistoryCountBy.renderable.rawValue, "renderable")
        XCTAssertEqual(HistoryCountBy.event.rawValue, "event")
    }
}

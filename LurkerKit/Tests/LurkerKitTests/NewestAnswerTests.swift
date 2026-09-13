// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Overlapping reads of `/api/config`: which answer is allowed to land.
final class NewestAnswerTests: XCTestCase {

    func testAnOlderAnswerLandingLastIsRefused() {
        var reads = NewestAnswer()
        let older = reads.start()
        let newer = reads.start()
        XCTAssertTrue(reads.accept(newer))
        XCTAssertFalse(reads.accept(older), "it would undo the newer answer")
    }

    /// The edge `/code-review` found on #17: keyed on the newest request, a newer read that failed
    /// discarded the older one that succeeded, and a stale refusal stayed on screen.
    func testANewerReadThatFailsDoesNotDiscardAnOlderAnswer() {
        var reads = NewestAnswer()
        let older = reads.start()
        _ = reads.start() // fails, so it never answers
        XCTAssertTrue(reads.accept(older))
    }

    func testAnswersThatLandInOrderAllApply() {
        var reads = NewestAnswer()
        let first = reads.start()
        XCTAssertTrue(reads.accept(first))
        let second = reads.start()
        XCTAssertTrue(reads.accept(second))
    }
}

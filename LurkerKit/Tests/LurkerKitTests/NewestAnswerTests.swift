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

    /// Copilot on #171: a compatible `/api/config` answer to a read sent before a 426 cleared the
    /// refusal the 426 had just set, and the app tried the socket again.
    func testAnAnswerFromElsewhereRefusesReadsAlreadyOut() {
        var reads = NewestAnswer()
        let before = reads.start()
        reads.supersedeInFlight()
        XCTAssertFalse(reads.accept(before))
        let after = reads.start()
        XCTAssertTrue(reads.accept(after), "a read started afterwards can still land")
    }

    func testAnswersThatLandInOrderAllApply() {
        var reads = NewestAnswer()
        let first = reads.start()
        XCTAssertTrue(reads.accept(first))
        let second = reads.start()
        XCTAssertTrue(reads.accept(second))
    }
}

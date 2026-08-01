// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Dragging a Favorites chip (#53) writes back to a list that is *longer* than the grid — a
/// pinned buffer whose network hasn't connected yet has a stored slot and no chip. The
/// interesting cases are all about that gap, because the failure mode is losing a favorite the
/// user can't currently see, and the only copy of the list is the one being rewritten.
final class FavoriteOrderTests: XCTestCase {

    func testAMoveWithEverythingVisible() {
        XCTAssertEqual(
            FavoriteOrder.moved(["a", "b", "c"], visible: ["a", "b", "c"], from: 0, to: 2),
            ["b", "c", "a"]
        )
        XCTAssertEqual(
            FavoriteOrder.moved(["a", "b", "c"], visible: ["a", "b", "c"], from: 2, to: 0),
            ["c", "a", "b"]
        )
    }

    func testHiddenFavoritesKeepTheirSlots() {
        // `b` has no chip (its network is still connecting). Dragging `c` above `a` reorders
        // the two chips and leaves `b` exactly where it was — it isn't part of the gesture, so
        // it can't be moved by it, and it certainly can't be dropped.
        let next = FavoriteOrder.moved(["a", "b", "c", "d"], visible: ["a", "c", "d"], from: 1, to: 0)
        XCTAssertEqual(next, ["c", "b", "a", "d"])
        XCTAssertEqual(next.count, 4, "nothing is lost")
        XCTAssertEqual(Set(next), Set(["a", "b", "c", "d"]), "and nothing is invented")
    }

    func testAMoveIsANoOpWhenItLandsWhereItStarted() {
        XCTAssertEqual(
            FavoriteOrder.moved(["a", "b"], visible: ["a", "b"], from: 1, to: 1),
            ["a", "b"]
        )
    }

    func testOutOfRangeIndicesChangeNothing() {
        XCTAssertEqual(FavoriteOrder.moved(["a", "b"], visible: ["a", "b"], from: 5, to: 0), ["a", "b"])
        XCTAssertEqual(FavoriteOrder.moved(["a", "b"], visible: ["a", "b"], from: 0, to: 5), ["a", "b"])
        XCTAssertEqual(FavoriteOrder.moved([], visible: [], from: 0, to: 0), [])
    }

    func testAVisibleKeyTheStoredListDoesNotHaveChangesNothing() {
        // The two lists have drifted — a rebuild raced the drop. Rewriting on a partial match
        // would deal the visible keys into too few slots and leave a stale one behind.
        XCTAssertEqual(
            FavoriteOrder.moved(["a", "b"], visible: ["a", "b", "ghost"], from: 0, to: 2),
            ["a", "b"]
        )
    }

    func testADuplicateInTheStoredListCannotSmuggleAKeyIn() {
        // The case a count-only guard let through: the second "a" contributes a third slot, so
        // the counts agreed while "c" — which was never pinned — had no slot at all. The deal
        // then wrote "c" into the list and destroyed an "a".
        XCTAssertEqual(
            FavoriteOrder.moved(["a", "a", "b"], visible: ["a", "b", "c"], from: 0, to: 2),
            ["a", "a", "b"]
        )
    }

    func testADuplicateInTheVisibleListChangesNothing() {
        // Two chips for one key can't be dealt into one slot. There's no sane answer, so the
        // gesture is refused rather than resolved arbitrarily.
        XCTAssertEqual(
            FavoriteOrder.moved(["a", "b"], visible: ["a", "a"], from: 0, to: 1),
            ["a", "b"]
        )
    }

    // MARK: - Where a hidden favorite sits (the boundary cases)

    func testAHiddenFavoriteAtTheHeadKeepsTheHead() {
        // The documented cost: "drag this to the top" means the top of the *grid*, and a hidden
        // key at stored index 0 still comes back above it. Pinned so the behavior is a decision
        // rather than something a reader discovers on a bug report.
        XCTAssertEqual(
            FavoriteOrder.moved(["hidden", "b", "c"], visible: ["b", "c"], from: 1, to: 0),
            ["hidden", "c", "b"]
        )
    }

    func testAHiddenFavoriteAtTheTailKeepsTheTail() {
        XCTAssertEqual(
            FavoriteOrder.moved(["b", "c", "hidden"], visible: ["b", "c"], from: 0, to: 1),
            ["c", "b", "hidden"]
        )
    }

    func testEveryPairwiseMoveAppliesTheMoveAndKeepsEveryKey() {
        // Two properties, because the first alone is satisfied by doing nothing — which is
        // exactly the branch `moved` takes when it declines a gesture. Asserting only that the
        // set survives would pass against `{ return stored }`, and the test guarding the
        // lose-a-pin failure mode would never have exercised the code that can lose one.
        let stored = ["a", "b", "c", "d", "e"]
        let visible = ["a", "c", "e"]
        for from in visible.indices {
            for to in visible.indices {
                let next = FavoriteOrder.moved(stored, visible: visible, from: from, to: to)
                XCTAssertEqual(next.sorted(), stored.sorted(), "move \(from)→\(to) changed the set")
                XCTAssertEqual(next[1], "b", "move \(from)→\(to) moved a hidden key")
                XCTAssertEqual(next[3], "d", "move \(from)→\(to) moved a hidden key")

                // And the grid really is in the order the drag drew it.
                var expected = visible
                expected.insert(expected.remove(at: from), at: to)
                XCTAssertEqual(
                    next.filter(visible.contains), expected,
                    "move \(from)→\(to) wasn't applied"
                )
            }
        }
    }
}

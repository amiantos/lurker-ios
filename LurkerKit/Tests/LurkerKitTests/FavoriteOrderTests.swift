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

    func testEveryPairwiseMoveIsAPermutation() {
        // The property that matters: whatever the drag, the stored list keeps exactly the keys
        // it had. A reorder must never be able to add or drop a pin.
        let stored = ["a", "b", "c", "d", "e"]
        let visible = ["a", "c", "e"]
        for from in visible.indices {
            for to in visible.indices {
                let next = FavoriteOrder.moved(stored, visible: visible, from: from, to: to)
                XCTAssertEqual(next.sorted(), stored.sorted(), "move \(from)→\(to) changed the set")
                XCTAssertEqual(next[1], "b", "move \(from)→\(to) moved a hidden key")
                XCTAssertEqual(next[3], "d", "move \(from)→\(to) moved a hidden key")
            }
        }
    }
}

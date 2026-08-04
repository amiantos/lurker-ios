// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest

@testable import LurkerKit

final class NetworkAbbreviationTests: XCTestCase {
    func testOneNetworkAbbreviatesToASingleCharacter() {
        XCTAssertEqual(NetworkAbbreviation.shortestUniquePrefixes([1: "libera"]), [1: "l"])
    }

    func testDistinctFirstLettersStopAtOne() {
        let out = NetworkAbbreviation.shortestUniquePrefixes([1: "libera", 2: "mansionNET"])
        XCTAssertEqual(out, [1: "l", 2: "m"])
    }

    /// The reason this isn't just `first`: a shared first letter has to grow until it separates.
    func testSharedPrefixGrowsUntilUnique() {
        let out = NetworkAbbreviation.shortestUniquePrefixes([1: "libera", 2: "lurkernet"])
        XCTAssertEqual(out, [1: "li", 2: "lu"])
    }

    /// Unique against every *other* name, not just distinct from the other labels: `lunar`
    /// can't stop at `lu` even though no other label is `lu`, because `lurker` starts with it.
    func testGrowsPastTwoWhenNeeded() {
        let out = NetworkAbbreviation.shortestUniquePrefixes([1: "lurker", 2: "lurknet", 3: "lunar"])
        XCTAssertEqual(out, [1: "lurke", 2: "lurkn", 3: "lun"])
    }

    /// One name being a strict prefix of another is the case that can't be separated from the
    /// short side: every prefix of "irc" is also a prefix of "ircnet", so "irc" takes its whole
    /// name while "ircnet" needs one more character.
    func testNameThatIsAPrefixOfAnotherTakesItsFullName() {
        let out = NetworkAbbreviation.shortestUniquePrefixes([1: "irc", 2: "ircnet"])
        XCTAssertEqual(out, [1: "irc", 2: "ircn"])
    }

    func testLowercasesRegardlessOfHowTheNetworkIsNamed() {
        let out = NetworkAbbreviation.shortestUniquePrefixes([1: "MansionNET", 2: "Libera"])
        XCTAssertEqual(out, [1: "m", 2: "l"])
    }

    /// Identical names can't be separated at all. Both get the full name rather than a
    /// tiebreaker the web client doesn't have — the ambiguity is real and saying so is honest.
    func testIdenticalNamesBothTakeTheFullName() {
        let out = NetworkAbbreviation.shortestUniquePrefixes([1: "libera", 2: "libera"])
        XCTAssertEqual(out, [1: "libera", 2: "libera"])
    }

    func testEmptyInputsDoNotTrap() {
        XCTAssertEqual(NetworkAbbreviation.shortestUniquePrefixes([:]), [:])
        XCTAssertEqual(NetworkAbbreviation.shortestUniquePrefixes([1: ""]), [1: ""])
        XCTAssertEqual(NetworkAbbreviation.shortestUniquePrefixes([1: "", 2: "libera"]), [1: "", 2: "l"])
    }

    /// The result must depend only on the set of names, never on dictionary iteration order —
    /// otherwise a chip's label could change across a rebuild with nothing else moving.
    func testIsIndependentOfInsertionOrder() {
        let names = [3: "lurkernet", 1: "libera", 2: "mansionNET"]
        let expected = [1: "li", 2: "m", 3: "lu"]
        for _ in 0 ..< 20 {
            XCTAssertEqual(NetworkAbbreviation.shortestUniquePrefixes(names), expected)
        }
    }
}

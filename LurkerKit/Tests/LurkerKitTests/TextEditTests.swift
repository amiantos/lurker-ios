// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

final class TextEditTests: XCTestCase {

    private func apply(_ old: String, _ new: String) -> String {
        let edit = TextEdit.difference(from: old, to: new)
        return (old as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func testRewritesOnlyWhatChanged() {
        let edit = TextEdit.difference(from: "hi al", to: "hi alice: ")
        XCTAssertEqual(edit.range, NSRange(location: 5, length: 0))
        XCTAssertEqual(edit.replacement, "ice: ")
    }

    func testAPrependSharingAPrefixStillLandsRight() {
        XCTAssertEqual(apply("alice is cool", "alice: alice is cool"), "alice: alice is cool")
        XCTAssertEqual(apply("bob: hi", "hi"), "hi")
        XCTAssertEqual(apply("same", "same"), "same")
        XCTAssertEqual(apply("", "new"), "new")
        XCTAssertEqual(apply("old", ""), "")
    }

    /// 😀 and 😃 share their high surrogate: an edit cut in UTF-16 would replace only the low half.
    func testNeverSplitsASurrogatePair() {
        let edit = TextEdit.difference(from: "x😀", to: "x😃")
        XCTAssertEqual(edit.range, NSRange(location: 1, length: 2))
        XCTAssertEqual(edit.replacement, "😃")
        let tail = TextEdit.difference(from: "😀x", to: "😃x")
        XCTAssertEqual(tail.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(tail.replacement, "😃")
    }

    /// A flag is two regional indicators; changing one must replace the whole flag.
    func testNeverSplitsAGraphemeCluster() {
        let edit = TextEdit.difference(from: "a🇫🇷", to: "a🇫🇮")
        XCTAssertEqual(edit.replacement, "🇫🇮")
        XCTAssertEqual(apply("a🇫🇷", "a🇫🇮"), "a🇫🇮")
    }
}

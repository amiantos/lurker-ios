// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// `IRCFormatting.drawsNothing`: whether a wire string has anything to show (lurker#1297). A topic
/// that draws nothing gets the "No topic set." placeholder; one that paints a box does not.
final class FormattingVisibilityTests: XCTestCase {

    func testControlCodesAndUnpaintedWhitespaceDrawNothing() {
        XCTAssertTrue(IRCFormatting.drawsNothing(""))
        XCTAssertTrue(IRCFormatting.drawsNothing("   \n"))
        XCTAssertTrue(IRCFormatting.drawsNothing("\u{03}\u{02}"))
        // A foreground on spaces colours nothing visible.
        XCTAssertTrue(IRCFormatting.drawsNothing("\u{03}04   \u{03}"))
        XCTAssertTrue(IRCFormatting.drawsNothing("\u{02} \u{1D} \u{0F}"))
    }

    func testTextDraws() {
        XCTAssertFalse(IRCFormatting.drawsNothing("hi"))
        XCTAssertFalse(IRCFormatting.drawsNothing("\u{03}04x\u{03}"))
        XCTAssertFalse(IRCFormatting.drawsNothing("   .   "))
    }

    func testPaintedWhitespaceDraws() {
        // A background is a box, reverse video a block, an underline or a strike a rule.
        XCTAssertFalse(IRCFormatting.drawsNothing("\u{03}04,04   \u{03}"))
        XCTAssertFalse(IRCFormatting.drawsNothing("\u{16}   \u{16}"))
        XCTAssertFalse(IRCFormatting.drawsNothing("\u{1F}   \u{1F}"))
        XCTAssertFalse(IRCFormatting.drawsNothing("\u{1E}   \u{1E}"))
    }
}

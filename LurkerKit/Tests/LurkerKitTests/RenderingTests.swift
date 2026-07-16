// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The pure rendering pieces: the mIRC control-code parser, the per-nick color hash, and
/// URL extraction. The NSAttributedString assembly lives in the app; this locks the logic
/// the web client and iOS must agree on.
final class RenderingTests: XCTestCase {

    // MARK: - mIRC formatting

    func testBoldTogglesRuns() {
        let runs = IRCFormatting.parse("a\u{02}b\u{02}c")
        XCTAssertEqual(runs.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(runs.map(\.bold), [false, true, false])
    }

    func testColorParsesForegroundAndBackground() {
        let runs = IRCFormatting.parse("\u{03}04,08red")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "red")
        XCTAssertEqual(runs[0].fg, 4)
        XCTAssertEqual(runs[0].bg, 8)
    }

    func testForegroundOnlyLeavesNoBackground() {
        let runs = IRCFormatting.parse("\u{03}04red")
        XCTAssertEqual(runs[0].fg, 4)
        XCTAssertNil(runs[0].bg)
        XCTAssertEqual(runs[0].text, "red")
    }

    func testResetClearsFormatting() {
        let runs = IRCFormatting.parse("\u{02}\u{03}04loud\u{0F}plain")
        XCTAssertEqual(runs.last?.text, "plain")
        XCTAssertEqual(runs.last?.bold, false)
        XCTAssertNil(runs.last?.fg)
    }

    func testMonospaceAndReverseAreConsumedNotRendered() {
        let runs = IRCFormatting.parse("a\u{11}b\u{16}c")
        XCTAssertEqual(runs.map(\.text).joined(), "abc")
    }

    func testPlainTextIsASingleRun() {
        let runs = IRCFormatting.parse("hello world")
        XCTAssertEqual(runs, [FormattingRun(
            text: "hello world", bold: false, italic: false, underline: false, strike: false, fg: nil, bg: nil
        )])
    }

    // MARK: - Nick colors

    func testNickColorIsDeterministic() {
        XCTAssertEqual(NickColor.index(for: "alice"), NickColor.index(for: "alice"))
    }

    func testNickColorTrimsStopChars() {
        // Away/alt suffixes must not change the color.
        XCTAssertEqual(NickColor.index(for: "amiantos__"), NickColor.index(for: "amiantos"))
        XCTAssertEqual(NickColor.index(for: "amiantos|"), NickColor.index(for: "amiantos"))
    }

    func testNickColorIsCaseInsensitive() {
        XCTAssertEqual(NickColor.index(for: "Alice"), NickColor.index(for: "alice"))
    }

    func testNickColorIndexInRange() {
        for nick in ["a", "somebody", "🙂user", "___", "z9"] {
            let index = NickColor.index(for: nick)
            XCTAssertTrue(index >= 0 && index < IRCPalette.nick.count, "\(nick) → \(index)")
        }
    }

    // MARK: - URLs

    func testMatchesAnHttpUrl() {
        let matches = URLMatcher.matches(in: "see https://example.com/x now")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].href, "https://example.com/x")
    }

    func testWwwGetsAnHttpScheme() {
        XCTAssertEqual(URLMatcher.matches(in: "www.example.com").first?.href, "http://www.example.com")
    }

    func testTrailingPunctuationIsTrimmed() {
        XCTAssertEqual(URLMatcher.matches(in: "go to https://example.com.").first?.href, "https://example.com")
    }

    func testUnbalancedClosingParenIsTrimmed() {
        XCTAssertEqual(URLMatcher.matches(in: "(see https://example.com)").first?.href, "https://example.com")
    }

    func testBareEmailGetsMailto() {
        XCTAssertEqual(URLMatcher.matches(in: "ping me@example.com").first?.href, "mailto:me@example.com")
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// `:shortcode:` emoji (lurker#1294): the bundled table, the grammar the web's
/// `emojiShortcodes.ts` tests pin down, and the render-time replacement over an attributed
/// string — the cases of `splitTextByEmoji` in the web's `nickColor.test.ts`.
final class EmojiShortcodesTests: XCTestCase {

    // MARK: - The table

    func testTheTableLoadsFromTheBundle() {
        // A resource that doesn't reach the bundle fails silently — an empty table, and every
        // shortcode in every message stays literal, which looks like the bug this feature fixes.
        XCTAssertGreaterThan(EmojiShortcodes.table.count, 1800)
        XCTAssertEqual(EmojiShortcodes.glyph(for: "skull"), "💀")
        XCTAssertEqual(EmojiShortcodes.glyph(for: "+1"), "👍")
        XCTAssertEqual(EmojiShortcodes.glyph(for: "e-mail"), "📧")
    }

    func testLookupIsCaseInsensitiveAndUnknownIsNil() {
        XCTAssertEqual(EmojiShortcodes.glyph(for: "Bone"), "🦴")
        XCTAssertEqual(EmojiShortcodes.glyph(for: "TADA"), "🎉")
        XCTAssertNil(EmojiShortcodes.glyph(for: "nope"))
        XCTAssertNil(EmojiShortcodes.glyph(for: ""))
    }

    // MARK: - Scanning a message (`shortcodeScanRegex`, `splitTextByEmoji`)

    private func scan(_ text: String, protecting: [NSRange] = []) -> [(String, String)] {
        EmojiShortcodes.matches(in: text, protecting: protecting).map {
            ((text as NSString).substring(with: $0.range), $0.glyph)
        }
    }

    func testMatchesEveryCompletedShortcode() {
        XCTAssertEqual(scan("a :smile: b :tada:").map(\.0), [":smile:", ":tada:"])
        XCTAssertEqual(scan("a :smile: b :tada:").map(\.1), ["😄", "🎉"])
    }

    func testMatchesNamesWithPlusAndMinus() {
        XCTAssertEqual(scan(":+1: and :e-mail:").map(\.1), ["👍", "📧"])
    }

    func testConvertsAdjacentShortcodes() {
        let matches = EmojiShortcodes.matches(in: ":+1::+1:")
        XCTAssertEqual(matches.map(\.range), [NSRange(location: 0, length: 4), NSRange(location: 4, length: 4)])
    }

    func testLeavesAnUnknownShortcodeLiteral() {
        XCTAssertEqual(scan("what :nope: is").count, 0)
    }

    func testSkipsAColonGluedToAWordOrNumber() {
        // The composer's boundary rule: `word:smile:` is not a shortcode start, and neither is
        // any colon in a clock.
        XCTAssertEqual(scan("word:smile: 12:00:00").count, 0)
        XCTAssertEqual(scan("at 12:00:00 sharp").count, 0)
        XCTAssertEqual(scan("C:\\path").count, 0)
        XCTAssertEqual(scan(":-)").count, 0)
    }

    func testMatchesCaseInsensitivelyOverASCIIOnly() {
        XCTAssertEqual(scan(":Tada:").map(\.1), ["🎉"])
        // The web's regex has no Unicode case folding: a Kelvin sign is not a `k`, and a long s
        // before the colon is not a name character gluing it shut.
        XCTAssertEqual(scan(":s\u{212A}ull:").count, 0)
        XCTAssertEqual(scan("\u{17F}:skull:").map(\.1), ["💀"])
    }

    func testAMatchTouchingAProtectedRangeIsLeftAlone() {
        // The renderer hands over its spoilers and links; a shortcode inside either stays text.
        let text = "ok :tada: https://x.test/:tada: done :skull:"
        let link = (text as NSString).range(of: "https://x.test/:tada:")
        let found = scan(text, protecting: [link])
        XCTAssertEqual(found.map(\.0), [":tada:", ":skull:"])
        XCTAssertEqual(EmojiShortcodes.matches(in: text, protecting: [link]).map(\.range.location), [3, 37])
    }

    func testNothingInEmptyText() {
        XCTAssertEqual(EmojiShortcodes.matches(in: ""), [])
    }

    // MARK: - Replacing in an attributed string (the render pass)

    func testReplaceSwapsEveryMatchAndKeepsOffsetsStraight() {
        let attributed = NSMutableAttributedString(string: "a :smile: b :tada: c")
        EmojiShortcodes.replace(in: attributed)
        XCTAssertEqual(attributed.string, "a 😄 b 🎉 c")
    }

    func testTheGlyphTakesTheRunsAttributes() {
        // The web carries active IRC formatting onto the glyph: a bold `:tada:` is a bold 🎉.
        let key = NSAttributedString.Key("test.bold")
        let attributed = NSMutableAttributedString(string: "x ")
        attributed.append(NSAttributedString(string: ":tada:", attributes: [key: true]))
        EmojiShortcodes.replace(in: attributed)
        XCTAssertEqual(attributed.string, "x 🎉")
        XCTAssertEqual(attributed.attribute(key, at: 2, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(attributed.attribute(key, at: 0, effectiveRange: nil))
    }

    func testAProtectedRangeSurvivesReplacement() {
        let text = ":tada: https://x.test/:tada:"
        let attributed = NSMutableAttributedString(string: text)
        let link = (text as NSString).range(of: "https://x.test/:tada:")
        EmojiShortcodes.replace(in: attributed, protecting: [link])
        XCTAssertEqual(attributed.string, "🎉 https://x.test/:tada:")
    }

    // MARK: - The composer (`findCompletedShortcode`)

    func testCompletedFindsTheShortcodeWhoseClosingColonWasJustTyped() {
        let text = "hi :tada:"
        let match = EmojiShortcodes.completed(in: text, caret: text.utf16.count)
        XCTAssertEqual(match, EmojiShortcodes.Match(range: NSRange(location: 3, length: 6), glyph: "🎉"))
    }

    func testCompletedHandlesPlusAndMinusAndCase() {
        XCTAssertEqual(EmojiShortcodes.completed(in: ":+1:", caret: 4)?.glyph, "👍")
        XCTAssertEqual(EmojiShortcodes.completed(in: ":Bone:", caret: 6)?.glyph, "🦴")
    }

    func testCompletedIsNilWithoutAClosingColonAtTheCaret() {
        XCTAssertNil(EmojiShortcodes.completed(in: ":tada", caret: 5))
        // The caret inside the token, or after a space, is not the closing moment.
        XCTAssertNil(EmojiShortcodes.completed(in: ":tada: ", caret: 7))
        XCTAssertNil(EmojiShortcodes.completed(in: ":tada:", caret: 3))
        XCTAssertNil(EmojiShortcodes.completed(in: "", caret: 0))
    }

    func testCompletedIsNilForAClockAMidWordColonRunOrAnUnknownName() {
        XCTAssertNil(EmojiShortcodes.completed(in: "12:00:", caret: 6))
        XCTAssertNil(EmojiShortcodes.completed(in: "word:smile:", caret: 11))
        XCTAssertNil(EmojiShortcodes.completed(in: ":nope:", caret: 6))
    }

    func testCompletedIsNilWhenANewlineFollowsTheShortcode() {
        // ICU's `$` matches before a final line terminator; the pattern uses `\z` so a newline
        // typed after a literal `:tada:` (a restored line, a synced draft) doesn't swap the line above.
        XCTAssertNil(EmojiShortcodes.completed(in: ":tada:\n", caret: 7))
        XCTAssertNil(EmojiShortcodes.completed(in: "hi :tada:\n", caret: 10))
    }

    func testCompletedOnlyLooksBeforeTheCaret() {
        // Text after the caret is someone else's problem — the conversion is for what was just typed.
        let text = ":tada: :skull:"
        XCTAssertEqual(EmojiShortcodes.completed(in: text, caret: 6)?.glyph, "🎉")
        XCTAssertNil(EmojiShortcodes.completed(in: text, caret: 20))
    }

    // MARK: - A typed reaction (`reactionFromInput`)

    func testReactionResolvesAWholeShortcodeClosingColonOptional() {
        XCTAssertEqual(EmojiShortcodes.reaction(from: ":tada:"), "🎉")
        XCTAssertEqual(EmojiShortcodes.reaction(from: ":tada"), "🎉")
        XCTAssertEqual(EmojiShortcodes.reaction(from: " :+1: "), "👍")
        XCTAssertEqual(EmojiShortcodes.reaction(from: ":-1"), "👎")
    }

    func testReactionResolvesOneLetterNamesLikeTheWeb() {
        // gemoji has one-letter names, so `:x` and `:o` are ❌ and ⭕ here as in the web's
        // `reactionFromInput` — parity, pinned so a change to it is a decision for all three clients.
        XCTAssertEqual(EmojiShortcodes.reaction(from: ":x"), "❌")
        XCTAssertEqual(EmojiShortcodes.reaction(from: ":o"), "⭕")
    }

    func testReactionSendsAnythingElseAsTyped() {
        XCTAssertEqual(EmojiShortcodes.reaction(from: ":nope:"), ":nope:")
        XCTAssertEqual(EmojiShortcodes.reaction(from: ":D"), ":D")
        XCTAssertEqual(EmojiShortcodes.reaction(from: ":-D"), ":-D")
        XCTAssertEqual(EmojiShortcodes.reaction(from: ":-)"), ":-)")
        XCTAssertEqual(EmojiShortcodes.reaction(from: "lol"), "lol")
        XCTAssertEqual(EmojiShortcodes.reaction(from: "👍"), "👍")
        XCTAssertEqual(EmojiShortcodes.reaction(from: ":tada: :tada:"), ":tada: :tada:")
        XCTAssertEqual(EmojiShortcodes.reaction(from: "  "), "")
    }
}

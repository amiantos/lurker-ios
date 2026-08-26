// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The pure rendering pieces: the mIRC control-code parser, the per-nick color hash, and
/// URL extraction. The NSAttributedString assembly lives in the app; this locks the logic
/// the web client and iOS must agree on.
final class RenderingTests: XCTestCase {

    // MARK: - mIRC formatting

    /// What a line reads as, for showing a message somewhere that can't render its formatting —
    /// the actions sheet's header (#60). The control byte is invisible but its color digits are
    /// not, so an unstripped header shows a different string from the line that was pressed.
    func testStripRemovesControlCodesAndKeepsText() {
        XCTAssertEqual(IRCFormatting.strip("\u{03}04ALERT\u{03} disk full"), "ALERT disk full")
        XCTAssertEqual(IRCFormatting.strip("\u{02}bold\u{02} and \u{1D}italic\u{1D}"), "bold and italic")
        XCTAssertEqual(IRCFormatting.strip("\u{03}04,08warned\u{0F} again"), "warned again")
    }

    /// Text with nothing to strip comes back untouched — including a bare digit after a word,
    /// which must not be mistaken for a color argument.
    func testStripLeavesPlainTextAlone() {
        XCTAssertEqual(IRCFormatting.strip("just a message"), "just a message")
        XCTAssertEqual(IRCFormatting.strip("route 66 is long"), "route 66 is long")
        XCTAssertEqual(IRCFormatting.strip(""), "")
    }

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

    /// ⚠⚠ The reason the trim COUNTS brackets rather than stripping closers outright, and the
    /// property the running-balance rewrite had to preserve: a pair that closes what it opened
    /// belongs to the address. Getting this wrong resolves the URL one character short, the card
    /// silently never appears, and the 404 is cached for an hour under a string appearing nowhere
    /// in the message.
    func testABalancedPairBelongsToTheAddress() {
        XCTAssertEqual(
            URLMatcher.matches(in: "https://e.test/wiki/Rust_(programming_language)").first?.href,
            "https://e.test/wiki/Rust_(programming_language)")
        // ...and it is still balanced when the whole thing is wrapped in prose brackets, where the
        // surplus comes from the closer the sentence added rather than from the address.
        XCTAssertEqual(
            URLMatcher.matches(in: "(see https://e.test/wiki/Rust_(programming_language))").first?
                .href,
            "https://e.test/wiki/Rust_(programming_language)")
    }

    /// ⚠ The shape the balance tally exists to keep cheap. Recomputing the count per character
    /// makes this quadratic in the app-wide linkifier; the web's copy of the function carries a
    /// note that it cost ~0.5ms per render. Asserted for CORRECTNESS at length — a timing
    /// assertion would just be a flake — so a future rewrite that drops the running tally still
    /// has to produce the right answer here.
    func testALongRunOfClosersIsTrimmedToTheAddress() {
        let url = "https://e.test/a.png"
        XCTAssertEqual(
            URLMatcher.matches(in: url + String(repeating: ")", count: 100)).first?.href, url)
    }

    func testBareEmailGetsMailto() {
        XCTAssertEqual(URLMatcher.matches(in: "ping me@example.com").first?.href, "mailto:me@example.com")
    }

    /// `<https://example.com>` is RFC 3986 Appendix C's delimiter convention, which Discord
    /// borrowed as "link, but no unfurl". `PreviewSelection` declines to resolve one; the
    /// renderer deletes the brackets, so the report is the range they occupy.
    func testAngleBracketsAreReportedSoTheRendererCanDropThem() {
        let matches = URLMatcher.matches(in: "see <https://example.com> now")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].href, "https://example.com")
        // The `<` through the `>`, so deleting it takes both delimiters and nothing else.
        XCTAssertEqual(matches[0].delimiters, NSRange(location: 4, length: 21))
    }

    /// ⚠⚠ Inside brackets the URL is NOT trailing-punctuation trimmed — the author has stated
    /// where the address ends, which is the whole reason the convention exists. Trimming here
    /// would also mean the closing `>` no longer sits where the bracket test looks for it, so
    /// the convention would stop being recognised on exactly the ambiguous URLs it is for.
    func testABracketedUrlKeepsItsTrailingPunctuation() {
        let matches = URLMatcher.matches(in: "<https://en.wikipedia.org/wiki/Foo.>")
        XCTAssertEqual(matches.first?.href, "https://en.wikipedia.org/wiki/Foo.")
    }

    /// ⚠⚠ The convention delimits a URI. A bare `foo@bar.com` is not one — we merely GUESS
    /// `mailto:` for it — and a guess is not grounds for rewriting what somebody typed. The
    /// renderer deletes whatever `delimiters` reports, so reporting it here rewrote
    /// `Co-Authored-By: Claude <noreply@anthropic.com>` into
    /// `Co-Authored-By: Claude noreply@anthropic.com`, in every message, for every user, with
    /// both preview settings off. RFC 5322 angle-addr is ordinary IRC traffic.
    func testAngleBracketsAroundABareEmailAreLeftAlone() {
        let matches = URLMatcher.matches(in: "Co-Authored-By: Claude <noreply@anthropic.com>")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].href, "mailto:noreply@anthropic.com")
        XCTAssertNil(matches[0].delimiters, "a bare email is not a URI the convention delimits")
    }

    /// ...while a written scheme still is one, including the `www.` case `isBracketedUrl`'s own
    /// note calls out.
    func testAngleBracketsStillStripForAWrittenScheme() {
        XCTAssertNotNil(URLMatcher.matches(in: "<https://example.com>").first?.delimiters)
        XCTAssertNotNil(URLMatcher.matches(in: "<www.example.com>").first?.delimiters)
        XCTAssertNotNil(URLMatcher.matches(in: "<mailto:a@b.co>").first?.delimiters)
    }

    /// ⚠⚠ `range` is the TRIMMED address and it is the only span on offer — the untrimmed match
    /// is deliberately no longer returned beside it (#126). It used to be, for the hidden-URL
    /// deletion, and having both within reach is what let that deletion take a closing delimiter
    /// whose partner sat in the prose: `look at this (<url>)` rendered as `look at this (`.
    /// Reaching past the address for the punctuation it may absorb is `PreviewText.absorbing`'s
    /// job now, because that question has an answer this trimmer does not know.
    func testRangeIsTheTrimmedAddressAndNothingElse() {
        let text = "look at this https://e.test/a.png."
        let match = URLMatcher.matches(in: text).first
        XCTAssertEqual(match?.href, "https://e.test/a.png")
        XCTAssertEqual(match?.range.length, ("https://e.test/a.png" as NSString).length)
    }

    /// ⚠⚠ The two trims INTERLEAVE, so one pass each is not enough. The sentence pass used to run
    /// once and hand over to the bracket pass: `(…/a.png.)` stopped it dead on the `)`, the bracket
    /// pass then exposed a `.`, and nothing looked again. The address kept a full stop nobody
    /// typed, the tappable link 404'd, and `PreviewSelection` sent the resolver a string appearing
    /// nowhere in the message — which is then negative-cached for an hour.
    func testTrimsToAFixpointWhenThePunctuationInterleaves() {
        XCTAssertEqual(
            URLMatcher.matches(in: "(https://e.test/a.png.)").first?.href, "https://e.test/a.png")
        XCTAssertEqual(
            URLMatcher.matches(in: "[see https://e.test/a.png!]").first?.href,
            "https://e.test/a.png")
    }

    /// ⚠ macOS substitutes `…` for `...` as you type, so it arrives in pasted text constantly.
    /// Without it in the trim set it rode into the href: the link broke, and `looksLikeMedia` saw
    /// a path not ending in `.png` and charged the URL to the tight CARD budget instead of the
    /// generous media one.
    func testAnEllipsisIsSentencePunctuationLikeAnyOther() {
        XCTAssertEqual(
            URLMatcher.matches(in: "look at this https://e.test/a.png\u{2026}").first?.href,
            "https://e.test/a.png")
    }

    func testAnOrdinaryUrlReportsNoDelimiters() {
        XCTAssertNil(URLMatcher.matches(in: "see https://example.com now").first?.delimiters)
        // A half-open bracket is ordinary prose, not the convention.
        XCTAssertNil(URLMatcher.matches(in: "<https://example.com").first?.delimiters)
    }
}

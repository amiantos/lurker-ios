// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Testing

@testable import LurkerKit

/// Mirrors the `hideableUrls` half of `vue_client/src/utils/previewUrls.test.ts`.
///
/// When a message's picture is on screen, the address that produced it is a duplicate of what
/// the reader is already looking at. When it is mid-sentence, it is part of something somebody
/// wrote. Telling those apart is the whole of this rule.
@Suite("PreviewHiding")
struct PreviewHidingTests {

    private let a = "https://e.test/a.png"
    private let b = "https://e.test/b.png"
    private let c = "https://e.test/c.png"
    private let page = "https://news.example/article"

    private func hidden(_ text: String?, _ candidates: String...) -> [String] {
        PreviewHiding.hideableUrls(in: text, candidates: Set(candidates)).sorted()
    }

    @Test("hides a URL that is the whole message")
    func wholeMessage() {
        #expect(hidden(a, a) == [a])
    }

    @Test("hides a URL the message begins or ends with")
    func atAnEdge() {
        #expect(hidden("\(a) look at this", a) == [a])
        #expect(hidden("look at this \(a)", a) == [a])
    }

    @Test("KEEPS a URL with prose on both sides")
    func proseOnBothSides() {
        // The rule's whole point. Mid-sentence the address is part of something somebody wrote —
        // "I read $URL and then..." — and deleting it leaves a sentence with a hole in it.
        #expect(hidden("I read \(a) this morning", a).isEmpty)
    }

    @Test("hides every URL in a message that is nothing but URLs")
    func peelsThroughTheMiddle() {
        // ⚠⚠ The reason this is a peel rather than a per-URL edge test. `b` touches neither end
        // of the message; it becomes an edge only once `a` has been taken.
        #expect(hidden("\(a) \(b) \(c)", a, b, c) == [a, b, c].sorted())
    }

    @Test("peels forward through a run of URLs when only the leading end is free")
    func leadingPeelAdvancesOnItsOwn() {
        // ⚠⚠ This case exists because the one above could not see the bug it names. With prose
        // at neither end, the TRAILING peel reaches every URL by itself — so replacing the
        // leading peel's cursor with a fixed "is it at position zero" test left that suite green
        // while the rule was broken. Adding a tail parks the trailing peel at the first
        // character and leaves the leading peel to do the work alone, which is the only
        // arrangement that can tell a peel from an edge test.
        #expect(hidden("\(a) \(b) tail", a, b) == [a, b].sorted())
        // ...and its mirror, so neither end is guarded only by the other.
        #expect(hidden("lead \(a) \(b)", a, b) == [a, b].sorted())
    }

    @Test("stops peeling at a URL that is NOT a candidate")
    func stopsAtANonCandidate() {
        // A page link renders a card and KEEPS its address, so it is not something the peel may
        // step over: anything behind it is still in the middle of the line. Without the
        // candidate test the peel would consume the page as though it were hidden — and, worse,
        // report it as hidden, taking the address off a card that is about to render one.
        #expect(hidden("\(page) \(b) tail", b).isEmpty)
        #expect(hidden("lead \(b) \(page)", b).isEmpty)
    }

    @Test("hides a trailing image even when a card precedes it")
    func trailingImageBehindACard() {
        // The flip side of the above, and the reason the peel is per-end: the message still ENDS
        // with the picture, so its address is still a duplicate of what the reader can see.
        #expect(hidden("\(page) \(b)", b) == [b])
    }

    @Test("peels from both ends independently")
    func bothEnds() {
        #expect(hidden("\(a) some words \(b) more words \(c)", a, b, c) == [a, c].sorted())
    }

    @Test("does not count a spoiler run as whitespace")
    func spoilerTextOccupiesTheLine() {
        // ⚠ Spoiler runs contribute no URLs — a hidden link must never be resolved — but their
        // TEXT still occupies the line. Ignoring it entirely would make a URL that follows a
        // spoiler look like the start of the message and take its address out from under the
        // reveal box.
        #expect(hidden("\(SpoilerMarkup.apply(to: "||psst||")) \(a)", a) == [a])
        #expect(hidden("\(SpoilerMarkup.apply(to: "||psst||")) \(a) tail", a).isEmpty)
    }

    @Test("trailing sentence punctuation does not decide the verdict")
    func trimmedPunctuationDoesNotBlockThePeel() {
        // ⚠⚠ The span's end was measured to the end of the TRIMMED address, so the `.` the
        // trimmer had just discarded sat between the span and the end of the message and failed
        // the "nothing but whitespace after it" test. The same URL at the FRONT hid regardless,
        // because the leading check is vacuously true at offset zero — so identical punctuation
        // produced opposite verdicts depending only on which end the URL sat at.
        #expect(hidden("look at this \(a).", a) == [a])
        #expect(hidden("look at this \(a)!", a) == [a])
        #expect(hidden("look at this (\(a))", a) == [a])
        // ...and prose still wins over punctuation, which is the rule the fix must not soften.
        #expect(hidden("I read \(a). this morning", a).isEmpty)
    }

    @Test("hides nothing when there are no candidates")
    func noCandidates() {
        #expect(PreviewHiding.hideableUrls(in: "\(a) \(b)", candidates: []).isEmpty)
        #expect(hidden(nil, a).isEmpty)
    }

    @Test("a bracketed URL never becomes a candidate, so its text is never hidden")
    func bracketedIsNeverACandidate() {
        // ⚠⚠ Written first as `hideableUrls("<a>", candidates: [a])`, which passed against every
        // implementation — including one with the bracket test deleted — because `<` and `>` are
        // not whitespace, so a bracketed URL can never sit at a blank edge in the first place.
        // That assertion was about the punctuation, not about the rule.
        //
        // What actually keeps a bracketed URL's address on screen is upstream: it is never
        // resolved, so it is never in `candidates`. That is the property worth guarding, and it
        // spans the two modules, so the test does too.
        let text = "<\(a)>"
        let candidates = Set(
            PreviewSelection.urls(in: text, inlineMedia: true, linkPreviews: true))
        #expect(candidates.isEmpty, "nothing was resolved, so nothing can stand in for it")
        #expect(PreviewHiding.hideableUrls(in: text, candidates: candidates).isEmpty)

        // And the same message without the brackets does hide, so the assertion above is about
        // the brackets rather than about the fixture.
        let bare = Set(PreviewSelection.urls(in: a, inlineMedia: true, linkPreviews: true))
        #expect(PreviewHiding.hideableUrls(in: a, candidates: bare) == [a])
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
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
        #expect(hidden("look at this \(a)?!", a) == [a])
        #expect(hidden("look at this \(a),", a) == [a])
        // ...and prose still wins over punctuation, which is the rule the fix must not soften.
        #expect(hidden("I read \(a). this morning", a).isEmpty)
    }

    @Test("will not absorb a delimiter whose partner is in the prose")
    func pairedDelimitersAreNotAbsorbed() {
        // ⚠⚠ This is #126, and the assertion here used to say the opposite: `(\(a))` was
        // expected to hide. The span measured to the end of the raw MATCH, which swallowed the
        // `)` — so the URL looked flush against the end of the message, and the renderer, deleting
        // the same span, took the closer and left `look at this (` painted above the picture. A
        // lone bracket is not whitespace, so the blank-body collapse never fired either.
        //
        // The rule now stops at anything PAIRED. Its partner sits in the prose, and taking half a
        // pair is the same orphan this whole rule exists to prevent — merely moved to the other
        // end. So a wrapped URL is simply not hideable: its address stays on screen beside its own
        // preview, which is redundant rather than broken.
        #expect(hidden("look at this (\(a))", a).isEmpty)
        #expect(hidden("look at this [\(a)]", a).isEmpty)
        #expect(hidden("he said \"check \(a)\"", a).isEmpty)
        #expect(hidden("he said 'check \(a)'", a).isEmpty)

        // ⚠ The same address with nothing wrapping it still hides, so the assertions above are
        // about the delimiters rather than about the fixture.
        #expect(hidden("look at this \(a)", a) == [a])
    }

    @Test("a formatting code between the address and its full stop changes nothing")
    func punctuationAcrossAFormattingBoundary() {
        // ⚠⚠ A common bot-output shape: the URL is bolded and the sentence's full stop is not, so
        // the regex match stops at the run boundary and the `.` sits outside it. The web had to
        // reach for its VISIBLE body to see this; iOS gets it free, because `urlSpans` already
        // scans what `MessageRenderer` assembled — but only while the absorption is measured
        // there too, which is what this guards.
        #expect(hidden("look at this \u{2}\(a)\u{2}.", a) == [a])
        // And the paired case stays paired across the boundary for the same reason.
        #expect(hidden("look at this (\u{2}\(a)\u{2})", a).isEmpty)
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

/// The other half of the hiding rule: what actually comes out of the body.
///
/// ⚠⚠ These drive `PreviewText.stripHiddenUrls` — the deletion itself — and that is the point.
/// The deletion used to live in `MessageRenderer`, in the app target, which has no test bundle;
/// what could be reached from here was `absorbing`, and a test comparing it against `UrlSpan.end`
/// is TAUTOLOGICAL, because `end` is computed by calling it. Such a test passes against a renderer
/// that deletes an entirely different range — which is precisely what #126 and the orphaned full
/// stop before it both were. Making the deletion reachable is what turned this suite into a guard.
///
@Suite("PreviewHiding/absorption")
struct PreviewAbsorptionTests {

    private let a = "https://e.test/a.png"

    /// What the URL at the head of `text` takes with it, beyond its own address.
    ///
    /// ⚠⚠ Records an issue rather than returning `""` when nothing matched. Every assertion about
    /// a delimiter below is `.isEmpty`, so a helper that answers `""` for "no URL here" satisfies
    /// them whether the absorption correctly stopped at the `)` or the matcher simply found
    /// nothing — and those are the exact assertions pinning #126. A test that cannot fail is not
    /// a test; make the absence loud.
    private func absorbed(_ text: String) -> String {
        let ns = text as NSString
        guard let match = URLMatcher.matches(in: text).first else {
            Issue.record("no URL matched in \(text) — the fixture, not the rule, is wrong")
            return "<no match>"
        }
        let span = PreviewText.absorbing(match.range, in: text)
        return ns.substring(with: NSRange(
            location: NSMaxRange(match.range),
            length: NSMaxRange(span) - NSMaxRange(match.range)))
    }

    @Test("takes sentence punctuation, which has no partner")
    func takesSentencePunctuation() {
        #expect(absorbed("look at this \(a).") == ".")
        #expect(absorbed("look at this \(a)?!") == "?!")
        #expect(absorbed("look at this \(a)...") == "...")
        #expect(absorbed("look at this \(a),") == ",")
        #expect(absorbed("look at this \(a); and more") == ";")
    }

    @Test("leaves a closing delimiter alone, because its partner is not the URL's to take")
    func leavesPairedDelimiters() {
        // ⚠⚠ Every one of these is trimmed OFF the address by `URLMatcher.trimTrailingPunctuation`
        // — that is why reaching for "everything the trimmer dropped" looked like the fix and was
        // not. The trimmer answers "where does the address end"; this answers "what may the
        // address take with it", and they are different questions with different answers.
        #expect(absorbed("look at this (\(a))").isEmpty)
        #expect(absorbed("look at this [\(a)]").isEmpty)
        #expect(absorbed("he said \"check \(a)\"").isEmpty)
        #expect(absorbed("he said 'check \(a)'").isEmpty)
    }

    @Test("takes nothing when the address runs to the end, or into whitespace")
    func nothingToAbsorb() {
        #expect(absorbed(a).isEmpty)
        #expect(absorbed("look at this \(a) and more").isEmpty)
    }

    @Test("what the rule measured is what the renderer deletes")
    func theTwoSidesAgree() {
        // ⚠⚠ Written first as a comparison of `absorbing(match.range)` against `span.end` — which
        // is TAUTOLOGICAL, because `span.end` is computed by calling `absorbing` on the same
        // range. It would have passed against a renderer that deleted `match.range` and orphaned
        // every full stop, which is the bug it claimed to guard. The deletion had to become
        // reachable before it could be pinned; that is why `stripHiddenUrls` moved into LurkerKit.
        //
        // So: assert the BODY, the thing the reader ends up looking at.
        let a = "https://e.test/a.png"
        #expect(stripped("look at this \(a).", hiding: a) == "look at this")
        #expect(stripped("look at this \(a)?!", hiding: a) == "look at this")
        #expect(stripped("\(a). look at this", hiding: a) == "look at this")
        #expect(stripped("look at this \u{2}\(a)\u{2}.", hiding: a) == "look at this")
    }

    @Test("a body that was only a link, and its punctuation, comes out empty")
    func onlyALinkCollapses() {
        // ⚠⚠ The symptom that made #774 visible: the address went and the full stop stayed, so the
        // body was not empty, so the whitespace-only end-trim left it — and a line holding a lone
        // `.` was painted above the picture. An empty body is what lets the caller drop the label.
        let a = "https://e.test/shot.png"
        #expect(stripped(a, hiding: a).isEmpty)
        #expect(stripped("\(a).", hiding: a).isEmpty)
        #expect(stripped("  \(a)!  ", hiding: a).isEmpty)
        #expect(stripped("\(a)\u{2026}", hiding: a).isEmpty)
    }

    @Test("a wrapped URL keeps its address rather than losing half a pair")
    func wrappedUrlIsLeftIntact() {
        // ⚠⚠ #126 itself, asserted where it was actually seen. The rule declines to hide these, so
        // nothing should be deleted at all — the old renderer took the `)` and left `look at this (`
        // above the picture. Driving the deletion (rather than the rule) is what makes this real:
        // it fails if either side reaches for the untrimmed match again.
        let a = "https://e.test/a.png"
        for body in ["look at this (\(a))", "look at this [\(a)]", "he said \"check \(a)\""] {
            #expect(
                stripped(body, hiding: PreviewHiding.hideableUrls(in: body, candidates: [a]))
                    == body,
                "nothing was hideable, so nothing may be deleted: \(body)")
        }
    }

    @Test("a spoilered copy of a hidden address keeps its characters")
    func spoilerIsNotShrunkByATwin() {
        // ⚠⚠ Hiding is decided by URL STRING, not by span identity — `PreviewHiding` says so and
        // declines to fix it, reasonably. The cost lands here: post the same image bare and again
        // inside a spoiler, and the bare one being hideable marked BOTH for deletion. The second
        // deletion takes characters out of a box the reader never opened.
        //
        // ⚠ `stripHiddenUrls` is given the spoiler ranges for exactly this. The delimiter branch
        // beside it has always guarded them; the hiding branch had not.
        let a = "https://e.test/a.png"
        let body = "\(a) then \(a)"
        let spoiler = NSRange(location: ("\(a) then " as NSString).length, length: (a as NSString).length)

        let out = NSMutableAttributedString(string: body)
        PreviewText.stripHiddenUrls(from: out, hidden: [a], spoilered: [spoiler])
        #expect(out.string == "then \(a)", "the spoilered twin must survive intact")
    }

    /// The body a reader is left with, after `hidden`'s addresses are taken out.
    private func stripped(_ body: String, hiding hidden: Set<String>) -> String {
        let out = NSMutableAttributedString(
            string: IRCFormatting.parse(body).map(\.text).joined())
        PreviewText.stripHiddenUrls(from: out, hidden: hidden, spoilered: [])
        return out.string
    }

    private func stripped(_ body: String, hiding url: String) -> String {
        stripped(body, hiding: [url])
    }
}

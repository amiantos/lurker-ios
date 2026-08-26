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
/// ⚠⚠ `MessageRenderer` lives in the app target, which has no test bundle, so the deletion cannot
/// be driven end to end from here. What CAN be pinned is the thing the deletion is made of —
/// `PreviewText.absorbing`, the single call both sides make — and the property that the renderer's
/// starting range agrees with the span the rule measured. That agreement is the whole defect class:
/// #126 was a disagreement of one character, and so was the bug before it.
@Suite("PreviewHiding/absorption")
struct PreviewAbsorptionTests {

    private let a = "https://e.test/a.png"

    private func absorbed(_ text: String) -> String {
        let ns = text as NSString
        guard let match = URLMatcher.matches(in: text).first else { return "" }
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

    @Test("what the rule measured is what the renderer would delete")
    func theTwoSidesAgree() {
        // ⚠⚠ The drift guard, and the reason `absorbing` is one function rather than two rules
        // that happen to match. Measure wide and delete narrow and the full stop is orphaned
        // (`look at this .`); measure narrow and delete wide and the deletion eats a character
        // the peel never licensed. Both have shipped.
        let bodies = [
            a, "look at this \(a).", "look at this \(a)?!", "\(a) first",
            "look at this \u{2}\(a)\u{2}.", "look at this (\(a))", "\(a). \(a)",
        ]
        for body in bodies {
            let (visible, spans) = PreviewText.urlSpans(in: body)
            let matches = URLMatcher.matches(in: visible)
            for span in spans {
                // ⚠ Paired by LOCATION, not by href. `\(a). \(a)` below is the same address
                // twice, and matching on the string hands both spans the first occurrence — a
                // failure of the test's bookkeeping that reads exactly like the drift it is
                // looking for. The renderer has no such ambiguity: it walks the matches and
                // absorbs from each one's own range.
                guard let match = matches.first(where: { $0.range.location == span.start }) else {
                    Issue.record("no rendered link at \(span.start) in \(body)")
                    continue
                }
                #expect(
                    PreviewText.absorbing(match.range, in: visible)
                        == NSRange(location: span.start, length: span.end - span.start),
                    "the span and the deletion disagree in: \(body)")
            }
        }
    }
}

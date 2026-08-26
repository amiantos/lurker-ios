// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Where the URLs in a message body are — the single scan both preview modules read.
///
/// ⚠⚠ **Matched over the ASSEMBLED body, never per formatting run**, and that is the whole
/// reason this type exists. `MessageRenderer` builds its attributed string run by run and then
/// linkifies `attributed.string` — the assembled text — so a run-by-run scan here disagrees with
/// the tappable link the reader actually gets, because `IRCFormatting.parse` flushes a run at
/// every control code and a code inside a URL therefore splits it:
///
///     "http://ex\u{3}4ample.com/page"   per run → "http://ex"   assembled → the real address
///     "\u{2}https://\u{2}e.test/page"   per run → nothing        assembled → a live link
///
/// The first sends the resolver a host that does not exist, and negative-caches the 404 for an
/// hour under a string appearing nowhere in the message; the second renders a link with no
/// preview and, once the views land, would look up hideable URLs by strings the renderer's own
/// link ranges do not contain.
///
/// This is the two-parsers defect one level up from the one `URLMatcher.rawRanges` fixed: that
/// round shared the PATTERN between the selector and the linkifier, and it was not enough,
/// because they were still being handed different INPUT. Sharing the pattern is not sharing the
/// parse.
///
/// ⚠ The web client does not have this bug and its structure is not the fix to copy: its
/// renderer splits per run too, so its selector and renderer agree by construction. iOS
/// assembles first, so iOS has to scan what it assembled.
public enum PreviewText {

    /// A URL and where it sits in what the reader actually sees.
    public struct UrlSpan: Equatable, Sendable {
        /// The address, trailing punctuation trimmed — what gets resolved.
        public let url: String
        /// UTF-16 offset of the match in the visible body.
        public let start: Int
        /// UTF-16 offset of the end of `url` PLUS the sentence punctuation that reads as
        /// belonging to it — see `PreviewText.absorbing(_:in:)`.
        ///
        /// ⚠⚠ Not `start + url.utf16.count`. Measuring to the end of the trimmed address leaves
        /// the punctuation the trimmer just discarded sitting between the span and the end of the
        /// message, so `look at this https://e.test/a.png.` failed the "nothing but whitespace
        /// after it" test and kept its address, while the same URL at the FRONT hid — the
        /// leading check being vacuously true at offset zero. Identical punctuation, opposite
        /// verdicts, decided by which end the URL sat at.
        ///
        /// ⚠⚠ And not the end of the raw MATCH either, which is where the first version of this
        /// went. The trimmer also discards a closing delimiter whose partner sits BEFORE the
        /// address, so absorbing everything it dropped made `look at this (https://e.test/a.png)`
        /// hideable — and the renderer, deleting the same span, left a line holding a lone `(`
        /// above the picture. The same orphan this rule exists to remove, moved to the other end.
        public let end: Int
    }

    /// The visible body — formatting codes removed, spoiler text kept — and every resolvable
    /// URL in it.
    ///
    /// ⚠⚠ Spoiler runs contribute their TEXT but none of their URLs, and both halves matter. A
    /// hidden link must never be resolved (unfurling one renders the target full-size beside the
    /// reveal box, defeating the spoiler); and the run's characters still occupy the line, so a
    /// URL following a spoiler is not at the start of the message and must not be peeled as
    /// though it were. Carried as RANGES rather than by skipping runs, because the scan now runs
    /// over the assembled text and no longer knows where a run ended.
    public static func urlSpans(in text: String) -> (visible: String, spans: [UrlSpan]) {
        var visible = ""
        var spoilers: [NSRange] = []
        for run in IRCFormatting.parse(text) {
            let base = (visible as NSString).length
            visible += run.text
            if PreviewSelection.isSpoilerRun(run) {
                spoilers.append(
                    NSRange(location: base, length: (run.text as NSString).length))
            }
        }

        let ns = visible as NSString
        var out: [UrlSpan] = []
        for range in URLMatcher.rawRanges(in: visible) {
            // Any overlap at all disqualifies it. A URL straddling the edge of a spoiler is
            // partly hidden, and resolving the visible half is both wrong and a leak.
            if spoilers.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }

            let raw = ns.substring(with: range)
            // The shared pattern also matches bare `www.` hosts and email addresses. Neither is
            // fetchable as written, and we are emphatically not resolving somebody's email.
            let lower = raw.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { continue }

            // ⚠ `<https://example.com>` is the author saying "link, but don't unfurl it" — the
            // only per-link control there is, since the two settings are all-or-nothing.
            if URLMatcher.isBracketedUrl(visible, at: range) { continue }

            let url = URLMatcher.trimTrailingPunctuation(raw)
            guard !url.isEmpty else { continue }
            let trimmed = NSRange(location: range.location, length: (url as NSString).length)
            out.append(
                UrlSpan(
                    url: url, start: range.location,
                    end: NSMaxRange(absorbing(trimmed, in: visible))))
        }
        return (visible, out)
    }

    /// The punctuation a URL may absorb.
    ///
    /// ⚠⚠ Narrower than `URLMatcher.trimTrailingPunctuation`'s class, deliberately, and the two
    /// characters left out are the whole point: `'` and `"` are PAIRED, as are the brackets that
    /// function handles by balance. A closing delimiter has a partner sitting before the address,
    /// so absorbing it deletes half a pair and strands the other half — `he said "check <url>"`
    /// became `he said "check`. Sentence punctuation has no partner, so taking it with the
    /// address is safe and reads correctly: a message ending `…shot.png.` ends with the picture.
    ///
    /// The cost of the narrowness is that a wrapped URL is simply not hideable — its address
    /// stays on screen beside its own preview, which is redundant rather than broken. That is the
    /// right way to be wrong here.
    /// ⚠ `…` is here for the same reason it is in `URLMatcher.trimTrailingPunctuation`'s set, and
    /// the two must move together: that one decides where the address ends, this one decides what
    /// the address may take with it. A character dropped there and not deletable here is left
    /// orphaned on screen — which is the whole of #126, in the other direction.
    public static let absorbable: Set<Character> = [".", ",", ";", ":", "!", "?", "\u{2026}"]

    /// `range` — a URL's TRIMMED span in `text` — extended across the sentence punctuation that
    /// reads as part of the address.
    ///
    /// ⚠⚠ The one definition, called by both sides on purpose. `UrlSpan.end` counts this
    /// punctuation as part of the address when it decides whether the URL sits against an edge,
    /// and `MessageRenderer` deletes what that decision measured. Two answers here means one of
    /// them orphans something: measure wide and delete narrow and the full stop is left behind
    /// (`look at this .`); measure narrow and delete wide and the peel never fires while the
    /// deletion eats a character it was not licensed to.
    ///
    /// ⚠ Measured on the ASSEMBLED body, not on the regex match, and that closes a case the match
    /// cannot see. `look at this \u{2}https://e.test/a.png\u{2}.` puts the full stop outside the
    /// match — a common bot-output shape — and adjacency in the assembled text is adjacency ON
    /// SCREEN, which is the domain this rule is about. (iOS gets this for free where the web had
    /// to reach for it: `urlSpans` already scans what `MessageRenderer` assembled.)
    public static func absorbing(_ range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        var end = NSMaxRange(range)
        while end < ns.length,
            let scalar = Unicode.Scalar(ns.character(at: end)),
            absorbable.contains(Character(scalar))
        {
            end += 1
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    /// Take the hidden URLs' addresses out of a rendered body, and close up the gap they leave.
    ///
    /// Moved out of `MessageRenderer` so it can be tested: the renderer is in the app target,
    /// which has no test bundle, and the range it chooses to delete IS the defect class here
    /// (#126, and the orphaned full stop before it). A property test that only re-derives
    /// `UrlSpan.end` from `absorbing` cannot see a renderer that reaches for a different range —
    /// which is exactly what both bugs were.
    ///
    /// ⚠⚠ Back to front, one pass. The caller's own bookkeeping (colour runs, spoiler ranges,
    /// link ranges) is plain arrays of offsets into the assembled string and does NOT move when
    /// characters do, so deleting from the front silently mis-styles everything after it. The
    /// attributed string's own attributes survive a deletion; the arrays beside it do not.
    ///
    /// Two jobs:
    ///
    /// 1. `<https://example.com>` renders WITHOUT its brackets — RFC 3986 Appendix C's delimiter
    ///    convention, which Discord borrowed as "link, but no unfurl". `PreviewSelection` already
    ///    declines to resolve one; this is the other half, and without it the convention is
    ///    visible punctuation that appears to do nothing. ⚠ This runs for EVERY message, not only
    ///    previewed ones — the two settings are off by default and this is the app-wide
    ///    linkifier. Deliberate, and it matches the web.
    ///
    /// 2. Addresses whose picture is about to stand in for them come out entirely.
    public static func stripHiddenUrls(
        from attributed: NSMutableAttributedString,
        hidden: Set<String>,
        spoilered: [NSRange]
    ) {
        // ⚠ One snapshot, taken before the first deletion, and every range below is an offset
        // into it — the matches already are, and the absorption has to be too. Asking the live
        // string mid-loop measures against a document the earlier (higher-offset) deletions have
        // already shortened, which is not the one `urlSpans` judged.
        let source = attributed.string
        for match in URLMatcher.matches(in: source).reversed() {
            let inSpoiler = spoilered.contains {
                NSIntersectionRange($0, match.range).length > 0
            }
            if hidden.contains(match.href) {
                // ⚠⚠ Never inside a spoiler, even though the address matches. Hiding is decided
                // by URL STRING, not by span identity (see `PreviewHiding`), so a message posting
                // the same image bare at one end and again inside a spoiler marks BOTH — and
                // deleting the second one takes characters out of a box the reader never revealed,
                // shrinking it to fit a secret it no longer holds. A spoilered URL is never
                // resolved and so never has a picture standing in for it; there is nothing there
                // to be redundant with. The delimiter branch below has always guarded this.
                guard !inSpoiler else { continue }
                // ⚠⚠ Exactly what the hiding rule MEASURED — `absorbing`, the same call
                // `UrlSpan.end` makes — and neither of the two obvious ranges beside it.
                //
                // Deleting the trimmed `match.range` orphans the punctuation the span counted as
                // part of the address: `look at this https://e.test/a.png.` became `look at this
                // .`, and a message that was ONLY `https://e.test/shot.png.` collapsed to a body
                // of one full stop — not empty, so the end-trim below (whitespace only) left it
                // and a line holding a lone `.` was painted above the picture.
                //
                // Deleting the untrimmed match is the same orphan at the other end. The trimmer
                // discards a closing delimiter whose partner sits in the PROSE, so taking the
                // whole match ate the `)` and left `look at this (` (#126). The span stops at
                // anything paired, so such a URL is not hideable and never reaches this line —
                // but only while both sides ask the same function.
                attributed.deleteCharacters(
                    in: match.delimiters ?? absorbing(match.range, in: source))
                continue
            }
            guard let delimiters = match.delimiters, !inSpoiler else { continue }
            attributed.deleteCharacters(
                in: NSRange(location: delimiters.location + delimiters.length - 1, length: 1))
            attributed.deleteCharacters(in: NSRange(location: delimiters.location, length: 1))
        }
        // Trim the ends, which is what makes a body that lost a URL read as a sentence rather
        // than as one with a hole in it: dropping the address from "look at this: <url>" leaves
        // a colon and a trailing space, and dropping it from a message that WAS only a link
        // leaves pure whitespace, which still paints a blank line above the picture.
        guard !hidden.isEmpty else { return }
        let text = attributed.string as NSString
        let firstInk = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        if firstInk.location == NSNotFound {
            attributed.deleteCharacters(in: NSRange(location: 0, length: attributed.length))
            return
        }
        let lastInk = text.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards)
        let tail = lastInk.location + lastInk.length
        if tail < text.length {
            attributed.deleteCharacters(in: NSRange(location: tail, length: text.length - tail))
        }
        if firstInk.location > 0 {
            attributed.deleteCharacters(in: NSRange(location: 0, length: firstInk.location))
        }
    }
}

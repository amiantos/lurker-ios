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
        /// UTF-16 offset of the END OF THE MATCH — **not** of `url`.
        ///
        /// ⚠⚠ Untrimmed deliberately. Measuring to the end of the trimmed address leaves the
        /// punctuation the trimmer just discarded sitting between the span and the end of the
        /// message, so `look at this https://e.test/a.png.` failed the "nothing but whitespace
        /// after it" test and kept its address, while the same URL at the FRONT hid — the
        /// leading check being vacuously true at offset zero. Identical punctuation, opposite
        /// verdicts, decided by which end the URL sat at.
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
            out.append(
                UrlSpan(url: url, start: range.location, end: range.location + range.length))
        }
        return (visible, out)
    }
}

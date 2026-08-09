// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which URLs in a message may have their address removed from the body, because the picture
/// they produced has taken their place.
///
/// The counterpart of the web client's `hideableUrls`. The DECISION lives here so it can be
/// tested without a view; applying it to a rendered body is the renderer's job.
///
/// ⚠⚠ A card NEVER loses its URL, and that is a rule about meaning rather than layout: a card's
/// heading is different text from the address, and the address is what somebody copies. Only
/// MEDIA — a picture that IS the thing linked — can stand in for its own URL. The caller decides
/// which resolved previews qualify and passes them as `candidates`.
public enum PreviewHiding {

    /// A URL and where it sits in what the reader actually sees.
    ///
    /// Offsets are UTF-16, into the VISIBLE body — formatting codes removed, spoiler text kept.
    struct UrlSpan {
        let url: String
        let start: Int
        let end: Int
    }

    /// Every resolvable URL in `text`, with its position in the visible body.
    ///
    /// ⚠⚠ Spoiler runs contribute their TEXT but none of their URLs, and both halves matter.
    /// `PreviewSelection` skips those runs entirely because a hidden link must not be resolved;
    /// here the run's characters still occupy the line, so a URL following a spoiler is not at
    /// the start of the message and must not be treated as though it were.
    static func spans(in text: String) -> (visible: String, spans: [UrlSpan]) {
        var visible = ""
        var out: [UrlSpan] = []
        for run in IRCFormatting.parse(text) {
            let base = (visible as NSString).length
            visible += run.text
            if PreviewSelection.isSpoilerRun(run) { continue }
            let ns = run.text as NSString
            for range in URLMatcher.rawRanges(in: run.text) {
                let raw = ns.substring(with: range)
                let lower = raw.lowercased()
                guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { continue }
                // ⚠ Structural, not a decision: `<` and `>` are not whitespace, so a bracketed
                // URL can never sit at a blank edge and the peel would stop at it regardless.
                // Kept because this scan is meant to agree with `PreviewSelection`'s about what
                // a URL is — a reader comparing them should not find a difference to explain —
                // but no test can redden its removal, and that is expected rather than a gap.
                // What actually protects a bracketed address is that it is never resolved, so it
                // is never a candidate; `PreviewHidingTests` asserts that instead.
                if URLMatcher.isBracketedUrl(run.text, at: range) { continue }
                let url = URLMatcher.trimTrailingPunctuation(raw)
                guard !url.isEmpty else { continue }
                out.append(
                    UrlSpan(
                        url: url,
                        start: base + range.location,
                        end: base + range.location + (url as NSString).length
                    )
                )
            }
        }
        return (visible, out)
    }

    /// Which of `candidates` may have their URL text dropped from the body.
    ///
    /// The rule: a URL is hideable when nothing but whitespace and OTHER HIDEABLE URLs sit
    /// between it and the start or the end of the message. So a message that is nothing but
    /// links loses all of them, a message that opens or closes with one loses that one, and a
    /// URL with prose on both sides keeps its text — because there the address is part of a
    /// sentence somebody wrote.
    ///
    /// ⚠⚠ A peel from each end, NOT a per-URL edge test, and the difference is a real case. In
    /// `https://a.png https://b.png https://c.png` the middle URL touches neither edge; testing
    /// it alone leaves one bare address stranded between two images. Peeling consumes `a` first,
    /// which is what makes `b` an edge.
    ///
    /// ⚠ The peel STOPS at a non-candidate rather than stepping over it. A page link renders as
    /// a card and keeps its URL, so anything behind it is no longer against the edge — hiding it
    /// would leave the image's address gone while the card's remained, mid-line.
    ///
    /// ⚠ Hiding is by URL STRING, so the same address posted twice loses both occurrences when
    /// either is at an edge. Left as-is: it is one address, it renders one preview, and a
    /// message repeating a link is not a case worth carrying span identity through the renderer
    /// for.
    public static func hideableUrls(in text: String?, candidates: Set<String>) -> Set<String> {
        var out = Set<String>()
        guard let text, !text.isEmpty, !candidates.isEmpty else { return out }
        let (visible, found) = spans(in: text)
        let ns = visible as NSString

        func isBlank(_ from: Int, _ to: Int) -> Bool {
            guard to > from else { return true }
            return ns.substring(with: NSRange(location: from, length: to - from))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var cursor = 0
        for span in found {
            guard candidates.contains(span.url), isBlank(cursor, span.start) else { break }
            out.insert(span.url)
            cursor = span.end
        }

        cursor = ns.length
        for span in found.reversed() {
            guard candidates.contains(span.url), isBlank(span.end, cursor) else { break }
            out.insert(span.url)
            cursor = span.start
        }

        return out
    }
}

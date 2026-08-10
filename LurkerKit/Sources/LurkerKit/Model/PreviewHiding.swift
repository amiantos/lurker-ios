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
        let (visible, found) = PreviewText.urlSpans(in: text)
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

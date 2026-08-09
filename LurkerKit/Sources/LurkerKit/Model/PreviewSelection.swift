// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which URLs in a message body are worth asking the server about.
///
/// The direct counterpart of the web client's `utils/previewUrls.ts`, deliberately kept in
/// step with it: both clients ask the same server the same questions, and a message that
/// sprouts two previews on the web and three on the phone would be a bug nobody could
/// explain. The port is of the *rule*, not the code — see `feedback_ios_not_bound_to_web`;
/// where iOS should diverge (rendering, tap targets, playback) it does, but "which links
/// count" is a question with one right answer.
public enum PreviewSelection {

    /// Cap on CARDS per message.
    ///
    /// Slack allows five, halloy defaults to one. Three is enough for a message genuinely
    /// sharing a few links, and short of enough for one message to take over a screen. Each
    /// card costs real vertical space, so this one stays tight.
    public static let maxCardsPerMessage = 3

    /// Cap on MEDIA per message — deliberately generous.
    ///
    /// Media doesn't cost vertical space the way a card does: two or more images render as one
    /// horizontally-scrolling strip of fixed height, so the tenth image costs exactly as much
    /// screen as the second.
    ///
    /// A limit still exists, because a message carrying fifty image URLs is spam and each one
    /// is an outbound fetch on the server's behalf. Set high enough not to bind on anything a
    /// person would actually post. Matches the web client.
    public static let maxMediaPerMessage = 20

    /// URL-ish spans in a message, matching the server's shared `urlPattern`.
    ///
    /// Only `http(s)` survives the filter below, but the pattern also matches bare `www.`
    /// hosts and email addresses, so they have to be *found* before they can be dropped.
    private static let detector: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?:(?:https?|ftps?)://|mailto:|www\\.)[^\\s<>`]+"
            + "|\\b[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9][A-Za-z0-9.-]*\\.[A-Za-z]{2,}\\b",
        options: [.caseInsensitive]
    )

    /// Extensions that mean "this URL IS a file", governing which setting applies.
    ///
    /// ⚠ A HINT, not a verdict. The server answers authoritatively from `Content-Type`, and
    /// `LinkPreview.isAllowed` re-checks that answer. Guessing wrong here costs one wasted
    /// resolve, never a render the user switched off.
    private static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "avif", "bmp",
        "mp4", "mov", "m4v", "webm",
        "mp3", "m4a", "ogg", "oga", "wav", "flac",
    ]

    private static func looksLikeMedia(_ url: String) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        let path = parsed.path.lowercased()
        return mediaExtensions.contains { path.hasSuffix(".\($0)") || path.contains(".\($0)/") }
    }

    /// The URLs to resolve for one message body.
    ///
    /// With both toggles off this returns empty without touching anything — that's what
    /// makes the features genuinely free when disabled, rather than merely invisible.
    public static func urls(
        in text: String?, inlineMedia: Bool, linkPreviews: Bool
    ) -> [String] {
        guard inlineMedia || linkPreviews else { return [] }
        guard let text, !text.isEmpty, let detector else { return [] }

        var out: [String] = []
        var seen = Set<String>()
        var mediaCount = 0
        var cardCount = 0
        let full = NSRange(text.startIndex..., in: text)

        for match in detector.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = String(text[range])

            // Neither a bare `www.` host nor an email address is fetchable as written, and
            // we are emphatically not resolving somebody's email address.
            guard raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://")
            else { continue }

            // Trailing punctuation belongs to the sentence, not to the URL: "see
            // https://example.com/x." must not resolve a path ending in a full stop. A
            // closing bracket goes too, at the known cost of clipping the rare URL that
            // legitimately ends in one.
            let url = String(raw.reversed().drop { ".,;:!?)]}'\"".contains($0) }.reversed())
            guard !url.isEmpty, !seen.contains(url) else { continue }

            let isMedia = looksLikeMedia(url)
            guard isMedia ? inlineMedia : linkPreviews else { continue }
            // Counted separately: one class filling up must not consume the other's budget.
            guard isMedia ? mediaCount < maxMediaPerMessage : cardCount < maxCardsPerMessage
            else { continue }

            if isMedia { mediaCount += 1 } else { cardCount += 1 }
            seen.insert(url)
            out.append(url)
        }
        return out
    }
}

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
    /// Media doesn't cost vertical space the way a card does: images render as a two-column
    /// grid, so a fifth image adds half a row rather than a whole picture.
    ///
    /// A limit still exists, because a message carrying fifty image URLs is spam and each one
    /// is an outbound fetch on the server's behalf. Set high enough not to bind on anything a
    /// person would actually post. Matches the web client.
    ///
    /// ⚠ This is now the ONLY bound on how many pictures one message can draw. The grid has no
    /// cell cap and no `+N` badge — see the mosaic section of `LINK_PREVIEWS_PR_PLAN.md` — so
    /// lowering this is the only lever if a message ever does take over the screen.
    public static let maxMediaPerMessage = 20

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

    /// Whether a formatting run is the IRC spoiler convention: text painted in its own
    /// background colour, i.e. invisible until selected or revealed.
    ///
    /// ⚠ The `<= 15` half has to match the renderer exactly. Slots above 15 paint nothing, so
    /// such a run is not hidden and its links are ordinary links — and since `SpoilerMarkup`
    /// closes a spoiler with `\u{3}99,99` when a digit follows, the tail of those messages IS a
    /// 99,99 run. Without the bound, a URL anywhere after a spoiler would silently lose its
    /// preview, which is a hard failure to trace back to a colour code.
    static func isSpoilerRun(_ run: FormattingRun) -> Bool {
        guard let fg = run.fg, let bg = run.bg else { return false }
        return fg == bg && fg <= 15
    }

    /// The URLs to resolve for one message body.
    ///
    /// With both toggles off this returns empty without touching anything — that's what
    /// makes the features genuinely free when disabled, rather than merely invisible.
    ///
    /// ⚠⚠ Runs through the IRC formatting parser rather than over the raw wire text, and both
    /// reasons bite. **A URL inside a SPOILER run must not be resolved at all** — the renderer
    /// deliberately declines to linkify there so a hidden link can't leak its target, and
    /// unfurling one renders the destination full-size beside the click-to-reveal box, which
    /// defeats the spoiler completely. And formatting codes otherwise live INSIDE the matched
    /// token: a `\u{3}` on the end of a URL was being sent to the resolver as part of the
    /// address.
    public static func urls(
        in text: String?, inlineMedia: Bool, linkPreviews: Bool
    ) -> [String] {
        guard inlineMedia || linkPreviews else { return [] }
        guard let text, !text.isEmpty else { return [] }

        var out: [String] = []
        var seen = Set<String>()
        var mediaCount = 0
        var cardCount = 0

        for run in IRCFormatting.parse(text) {
            if isSpoilerRun(run) { continue }
            let ns = run.text as NSString

            for range in URLMatcher.rawRanges(in: run.text) {
                let raw = ns.substring(with: range)

                // The shared pattern also matches bare `www.` hosts and email addresses.
                // Neither is fetchable as written, and we are emphatically not resolving
                // somebody's email address.
                let lower = raw.lowercased()
                guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { continue }

                // ⚠ `<https://example.com>` is an explicit "link, but don't unfurl it". Skipped
                // BEFORE `seen`, so the same address posted bare earlier in the message still
                // resolves: the brackets speak for the occurrence they wrap, not for the
                // address.
                if URLMatcher.isBracketedUrl(run.text, at: range) { continue }

                // ⚠ The LINKIFIER's trimmer, shared rather than re-expressed — see
                // `URLMatcher.rawRanges` for the bug that came of having two of them.
                let url = URLMatcher.trimTrailingPunctuation(raw)
                guard !url.isEmpty, !seen.contains(url) else { continue }

                // ⚠⚠ A non-media URL is wanted when EITHER toggle is on, and that asymmetry is
                // load-bearing. `looksLikeMedia` is false both for "definitely a page" and for
                // "no extension to judge by", and requiring `linkPreviews` for the second case
                // meant an extensionless image host — imgur, twimg, the common case on IRC —
                // could never render for someone who enabled ONLY inline media. Permanently,
                // because priming is ingest-driven and nothing revisits a message. Unknowns are
                // charged to the CARD budget, which is the tight one, so honouring them can't
                // turn a link-heavy message into twenty speculative fetches.
                let isMedia = looksLikeMedia(url)
                guard isMedia ? inlineMedia : (linkPreviews || inlineMedia) else { continue }
                // Counted separately: one class filling up must not consume the other's budget.
                guard isMedia ? mediaCount < maxMediaPerMessage : cardCount < maxCardsPerMessage
                else { continue }

                if isMedia { mediaCount += 1 } else { cardCount += 1 }
                seen.insert(url)
                out.append(url)
            }
        }
        return out
    }
}

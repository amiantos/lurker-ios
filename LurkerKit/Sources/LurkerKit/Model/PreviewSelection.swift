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

    /// Whether an event is a kind that can carry a preview at all.
    ///
    /// ⚠⚠ Read by BOTH the priming path and the render path, and that is the point of it being
    /// here rather than expressed twice. Priming used to run over every event a frame carried
    /// while only some rows could ever draw an attachment — and part/quit publish their reason
    /// as `text`, topic publishes the topic, and a history page ships the whole contiguous range
    /// with the noise included. So joining a channel whose topic is a URL, or scrolling past
    /// `Quit: HexChat https://hexchat.github.io`, made the server fetch a page on the reader's
    /// behalf that nothing would ever display.
    ///
    /// Speech minus `notice`: a notice is usually a service or a bot announcing something, and
    /// unfurling ChanServ is not a feature anybody asked for. Matches the web client, which
    /// mounts its attachments for `message` and `action` only.
    public static func isPreviewable(_ type: EventType) -> Bool {
        type == .message || type == .action
    }

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

    /// The URLs to resolve for a buffer's worth of events — the whole priming policy, in one
    /// testable call.
    ///
    /// Its own function rather than a loop inside `ChatViewModel.primePreviews`, and for the
    /// same reason the web keeps `previewEvents.ts` separate from its socket layer: this is pure
    /// policy about what the server may be asked to fetch on the reader's behalf, and nothing in
    /// the frame-routing layer is reachable from a test. What is left at the call site is a
    /// `switch` that names the frames priming listens to, which is plumbing.
    ///
    /// Two filters, and both of them stop the SERVER making an outbound request for something
    /// nobody will ever see — see `isPreviewable` for the type half, and the ignore half below.
    public static func urls(
        in messages: [Message],
        networkId: Int?,
        target: String,
        ignores: IgnoreSet,
        inlineMedia: Bool,
        linkPreviews: Bool
    ) -> [String] {
        guard inlineMedia || linkPreviews else { return [] }
        var out: [String] = []
        for message in messages {
            guard isPreviewable(message.type) else { continue }

            // ⚠⚠ Ignoring somebody is a veto on the FETCH, not just on the row. Ignores are
            // client-side and applied when the store hands rows to the list, which is long after
            // priming runs — so this happily asked the server to go and fetch every link posted
            // by someone the user had explicitly silenced. The row was then dropped and the
            // preview never seen, which is exactly what kept it invisible.
            //
            // `isMessageHidden` rather than a hand-built matcher input: it already derives
            // DM-ness through `ChannelName.isChannelTarget` (all four sigils), and re-deriving
            // that is how the two tiers drifted apart the last time.
            if ignores.isMessageHidden(networkId: networkId, message: message, target: target) {
                continue
            }

            out.append(
                contentsOf: urls(
                    in: message.text, inlineMedia: inlineMedia, linkPreviews: linkPreviews
                )
            )
        }
        return out
    }

    /// The URLs to resolve for one message body.
    ///
    /// With both toggles off this returns empty without touching anything — that's what
    /// makes the features genuinely free when disabled, rather than merely invisible.
    ///
    /// ⚠⚠ Reads `PreviewText.urlSpans`, which scans the ASSEMBLED body rather than each
    /// formatting run — see that type for why scanning per run disagreed with the tappable link
    /// the renderer produces. Spoilered and `<bracketed>` URLs are already excluded there.
    public static func urls(
        in text: String?, inlineMedia: Bool, linkPreviews: Bool
    ) -> [String] {
        guard inlineMedia || linkPreviews else { return [] }
        guard let text, !text.isEmpty else { return [] }

        var out: [String] = []
        var seen = Set<String>()
        var mediaCount = 0
        var cardCount = 0

        for span in PreviewText.urlSpans(in: text).spans {
            let url = span.url
            guard !seen.contains(url) else { continue }

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
        return out
    }
}

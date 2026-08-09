// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Testing

@testable import LurkerKit

/// Mirrors `vue_client/src/utils/previewUrls.test.ts` case for case.
///
/// Both clients ask the same server the same questions, and a message that sprouts two
/// previews on the web and three on the phone would be a bug nobody could explain. Porting
/// the reference's suite is how that stays true — the divergences between the clients are
/// deliberate and elsewhere (rendering, tap targets, playback), not here.
@Suite("PreviewSelection")
struct PreviewSelectionTests {

    private func urls(_ text: String?, media: Bool = true, pages: Bool = true) -> [String] {
        PreviewSelection.urls(in: text, inlineMedia: media, linkPreviews: pages)
    }

    // MARK: - The toggles

    @Test("asks for nothing at all when both settings are off")
    func bothOff() {
        // The load-bearing property of default-off: no work, not even a request that gets
        // thrown away.
        #expect(
            urls("https://e.test/a.png and https://e.test/page", media: false, pages: false)
                .isEmpty)
    }

    @Test("gates the two classes asymmetrically, because only one of them is knowable")
    func asymmetricGating() {
        // `looksLikeMedia` recognises MEDIA extensions and is false for everything else — a
        // page, a bare host, an extensionless image alike. So "this is media" is a verdict the
        // client can act on, and "this is not media" never is. Link-previews-off therefore drops
        // a .png outright, while inline-media-off cannot drop an unknown without breaking the
        // extensionless image case below.
        #expect(urls("https://e.test/a.png", media: false, pages: true).isEmpty)
        #expect(urls("https://e.test/a.png", media: true, pages: false) == ["https://e.test/a.png"])
    }

    @Test("inline media still asks about an EXTENSIONLESS link, because it cannot tell")
    func extensionlessUnderMediaOnly() {
        // ⚠ The deliberate trade, and it costs a fetch: with only inline media on, an
        // extensionless URL is asked about even though most turn out to be pages. The
        // alternative is worse — imgur, twimg and every CDN serve images from extensionless
        // paths, so treating "no extension" as "definitely a page" made inline media
        // permanently unable to render the majority of real image links, and permanently is the
        // right word: priming is ingest-driven and never revisits a message. Bounded by the CARD
        // cap (3), not the media cap, so a link-heavy message can't become twenty speculative
        // fetches. A page that comes back is still not RENDERED — `isAllowed` re-checks the
        // server's answer.
        #expect(
            urls("https://i.imgur.com/aBcDeF", media: true, pages: false)
                == ["https://i.imgur.com/aBcDeF"])
        let many = (0..<9).map { "https://e.test/p\($0)" }.joined(separator: " ")
        #expect(urls(many, media: true, pages: false).count == PreviewSelection.maxCardsPerMessage)
    }

    @Test("link previews selects pages and ignores file links")
    func pagesOnly() {
        #expect(
            urls("https://e.test/a.png https://e.test/article", media: false, pages: true)
                == ["https://e.test/article"])
    }

    @Test("both on selects both")
    func bothOn() {
        #expect(
            urls("https://e.test/a.png https://e.test/article")
                == ["https://e.test/a.png", "https://e.test/article"])
    }

    @Test("treats video and audio links as inline media, not as pages")
    func videoAndAudioAreMedia() {
        #expect(
            urls("https://e.test/clip.mp4 https://e.test/song.mp3", media: true, pages: false)
                == ["https://e.test/clip.mp4", "https://e.test/song.mp3"])
        #expect(urls("https://e.test/clip.mp4", media: false, pages: true).isEmpty)
    }

    // MARK: - What counts as a URL

    @Test("ignores bare www hosts, which are not fetchable as written")
    func ignoresBareWww() {
        #expect(urls("see www.example.com for more").isEmpty)
    }

    @Test("never resolves an email address")
    func ignoresEmail() {
        // The shared URL pattern matches these; resolving one would be both useless and a
        // small privacy insult.
        #expect(urls("mail me at bob@example.com").isEmpty)
        #expect(urls("mailto:bob@example.com").isEmpty)
    }

    @Test("strips trailing sentence punctuation")
    func stripsPunctuation() {
        #expect(urls("go to https://e.test/page.") == ["https://e.test/page"])
        #expect(urls("really? https://e.test/x!") == ["https://e.test/x"])
        #expect(urls("(https://e.test/y)") == ["https://e.test/y"])
    }

    @Test("keeps a path that legitimately contains punctuation")
    func keepsInnerPunctuation() {
        #expect(urls("https://e.test/a.b.c/d") == ["https://e.test/a.b.c/d"])
    }

    @Test("ends a URL where the LINKIFIER ends it, brackets and all")
    func agreesWithTheLinkifier() {
        // ⚠ Two parsers disagreeing about where a URL stops is the bug. The tappable link is
        // built by `URLMatcher`'s balance-aware trimmer, so stripping ')' unconditionally here
        // resolved a DIFFERENT address than the one in the message: the real page 200s, the
        // clipped one 404s, and that 404 is cached for an hour under a string that appears
        // nowhere in the text. Same helper for both, so they cannot drift.
        let wiki = "https://en.wikipedia.org/wiki/Rust_(programming_language)"
        #expect(urls("see \(wiki)") == [wiki])
        // ...while a URL merely wrapped in brackets still loses them.
        #expect(urls("(https://e.test/y)") == ["https://e.test/y"])
    }

    @Test("never resolves a link hidden behind a spoiler")
    func spoileredLinkIsNeverResolved() {
        // ⚠⚠ The renderer declines to linkify inside a spoiler run precisely so a link cannot
        // leak the hidden content. Resolving one anyway renders the target full-size as a
        // SIBLING of the click-to-reveal box — the spoiler is defeated by the preview, and for
        // an image the payload is on screen before anyone chooses to reveal it. Only inline
        // media need be on.
        let hidden = "\u{3}01,01https://secret.example/leak.png\u{3}"
        #expect(urls(hidden).isEmpty)
        #expect(urls(hidden, media: true, pages: false).isEmpty)
        // A visible link in the same message is unaffected.
        #expect(urls("ok https://e.test/fine.png \(hidden)") == ["https://e.test/fine.png"])
    }

    @Test("still resolves a link in an unrenderable matched pair, which is not a spoiler")
    func unrenderableColourPairIsNotASpoiler() {
        // The other side of the same test: a run whose matched pair is a slot the palette can't
        // paint is NOT hidden, so its links are ordinary links.
        //
        // ⚠ Load-bearing rather than academic. `SpoilerMarkup` closes a spoiler with `\u{3}99,99`
        // when a digit follows it, so the tail of those messages IS a 99,99 run — and skipping it
        // here would silently drop the preview for any URL after such a spoiler. A missing
        // preview traced back to a colour code is not a debugging session anyone should have.
        #expect(urls("\u{3}99,99https://e.test/fine.png") == ["https://e.test/fine.png"])
        #expect(
            urls(SpoilerMarkup.apply(to: "||x||5 then https://e.test/fine.png"))
                == ["https://e.test/fine.png"])
    }

    @Test("strips formatting codes out of the URL rather than resolving them")
    func formattingCodesAreNotPartOfTheAddress() {
        // A colour reset immediately after a link put \u{3} INSIDE the matched token, so the
        // resolver was handed an address with a control character on the end.
        #expect(urls("\u{3}04https://e.test/red.png\u{3} done") == ["https://e.test/red.png"])
    }

    // MARK: - <angle brackets> suppress a preview

    @Test("refuses to resolve a URL the author wrapped in brackets")
    func bracketsSuppress() {
        // RFC 3986 Appendix C's delimiter convention, borrowed from Discord as "link, but no
        // unfurl". It is the only per-link control there is — the two settings are
        // all-or-nothing — so a person sharing a URL they don't want unfolded has exactly this
        // and nothing else.
        #expect(urls("<https://e.test/a.png>").isEmpty)
        #expect(urls("see <https://e.test/article> for more").isEmpty)
    }

    @Test("leaves an unbracketed URL in the same message alone")
    func bracketsArePerOccurrence() {
        #expect(
            urls("<https://e.test/a.png> https://e.test/b.png") == ["https://e.test/b.png"])
    }

    @Test("needs BOTH brackets, so a stray one is not a suppression")
    func halfOpenBracketIsNotTheConvention() {
        // A `<` in prose is ordinary. Treating a half-open bracket as the convention would
        // silently eat previews in messages that never asked for it.
        #expect(urls("<https://e.test/a.png") == ["https://e.test/a.png"])
        #expect(urls("https://e.test/a.png>") == ["https://e.test/a.png"])
    }

    @Test("recognises the brackets even when the URL ends in punctuation")
    func bracketsMeasureTheUntrimmedMatch() {
        // ⚠⚠ The end test measures from the UNTRIMMED match. `trimTrailingPunctuation` eats the
        // `.` here, so a check against the trimmed length lands on `.` instead of `>` and the
        // brackets stop working on exactly the URLs whose ends are ambiguous — which is the case
        // the convention exists for.
        #expect(urls("<https://e.test/wiki/Foo.>").isEmpty)
    }

    @Test("keeps a query string intact")
    func keepsQuery() {
        #expect(urls("https://e.test/s?q=1&r=2") == ["https://e.test/s?q=1&r=2"])
    }

    @Test("handles a message that is nothing but a URL")
    func bareUrl() {
        #expect(urls("https://e.test/only") == ["https://e.test/only"])
    }

    @Test("is fine with empty and nil text")
    func emptyInput() {
        #expect(urls("").isEmpty)
        #expect(urls(nil).isEmpty)
    }

    // MARK: - Limits

    @Test("resolves a repeated link only once")
    func dedupes() {
        #expect(urls("https://e.test/a https://e.test/a https://e.test/a") == ["https://e.test/a"])
    }

    @Test("caps CARDS tightly, because each one costs vertical space")
    func capsCards() {
        let text = (0..<12).map { "https://e.test/\($0)" }.joined(separator: " ")
        #expect(urls(text).count == PreviewSelection.maxCardsPerMessage)
    }

    @Test("lets many images through, because a grid cell costs less than a card")
    func manyImages() {
        // Media renders as a two-column grid, so a fifth image adds half a row rather than a
        // whole picture — nothing like the vertical space a fourth card would want.
        let text = (0..<12).map { "https://e.test/\($0).png" }.joined(separator: " ")
        #expect(urls(text).count == 12)
    }

    @Test("still bounds media, so a spam message is not fifty outbound fetches")
    func mediaBounded() {
        let text = (0..<40).map { "https://e.test/\($0).png" }.joined(separator: " ")
        #expect(urls(text).count == PreviewSelection.maxMediaPerMessage)
    }

    @Test("counts the two caps independently")
    func independentCaps() {
        // One class filling up must not consume the other's budget.
        let pages = (0..<5).map { "https://e.test/page\($0)" }
        let images = (0..<5).map { "https://e.test/img\($0).png" }
        let got = urls((pages + images).joined(separator: " "))
        #expect(got.filter { $0.hasSuffix(".png") }.count == 5)
        #expect(got.filter { !$0.hasSuffix(".png") }.count == PreviewSelection.maxCardsPerMessage)
    }

    @Test("counts the cap after deduping, not before")
    func capCountsAfterDedupe() {
        // Four mentions of one link plus two others should yield three previews, not one —
        // otherwise a message quoting the same URL twice silently loses its other links.
        let text = "https://e.test/a https://e.test/a https://e.test/b https://e.test/c"
        #expect(urls(text) == ["https://e.test/a", "https://e.test/b", "https://e.test/c"])
    }
}

/// The PRIMING policy — which events the server may be asked to fetch on the reader's behalf.
///
/// Mirrors `vue_client/src/utils/previewEvents.test.ts`. Both filters exist to stop an outbound
/// request being made for something nobody will ever see, and both were missing on the iOS
/// reference branch.
@Suite("PreviewSelection — priming policy")
struct PreviewPrimingTests {

    private func message(
        _ text: String, type: EventType = .message, nick: String = "alice"
    ) -> Message {
        Message(id: 1, type: type, nick: nick, text: text, isSelf: false, userhost: "\(nick)!u@h")
    }

    private func urls(
        _ messages: [Message],
        networkId: Int? = 1,
        target: String = "#chan",
        ignores: IgnoreSet = .empty
    ) -> [String] {
        PreviewSelection.urls(
            in: messages, networkId: networkId, target: target, ignores: ignores,
            inlineMedia: true, linkPreviews: true
        )
    }

    @Test("primes the kinds that can actually draw an attachment")
    func onlySpeech() {
        #expect(urls([message("https://e.test/a")]) == ["https://e.test/a"])
        #expect(urls([message("https://e.test/a", type: .action)]) == ["https://e.test/a"])
    }

    @Test("never fetches a quit reason, a topic, or any other narration")
    func noNarration() {
        // ⚠ Part and quit publish their reason as `text`, and topic publishes the topic — so
        // joining a channel whose topic is a URL, or scrolling past
        // `Quit: HexChat https://hexchat.github.io`, made the server fetch a page no render path
        // can display. A history page ships the whole contiguous range with the noise included,
        // which is what made this fire in bulk rather than occasionally.
        for type: EventType in [.quit, .part, .join, .topic, .notice, .system, .motd, .kick] {
            #expect(
                urls([message("https://e.test/a", type: type)]).isEmpty,
                "\(type.rawValue) can't render an attachment, so it must not prime one")
        }
    }

    @Test("ignoring somebody is a veto on the FETCH, not just on the row")
    func ignoredSenderIsNotPrimed() {
        // ⚠⚠ Ignores are applied when the store hands rows to the list, long after priming — so
        // this fetched every link posted by someone the user had explicitly silenced, and the
        // row was then dropped, which is precisely what kept it invisible.
        let ignores = IgnoreSet(global: [IgnoreRule(mask: "spammer", levels: ["ALL"])])
        #expect(urls([message("https://e.test/a", nick: "spammer")], ignores: ignores).isEmpty)
        #expect(
            urls([message("https://e.test/a", nick: "alice")], ignores: ignores)
                == ["https://e.test/a"])
    }

    @Test("honours a rule scoped to one network, and leaves the others alone")
    func ignoreScopeIsRespected() {
        let ignores = IgnoreSet(byNetwork: [1: [IgnoreRule(mask: "bob", levels: ["ALL"])]])
        let line = [message("https://e.test/a", nick: "bob")]
        #expect(urls(line, networkId: 1, ignores: ignores).isEmpty)
        #expect(urls(line, networkId: 2, ignores: ignores) == ["https://e.test/a"])
    }

    @Test("classifies a DM target by all four channel sigils, not just #")
    func dmDerivationUsesEverySigil() {
        // ⚠⚠ The one matcher input derived on the client rather than received on the wire, and
        // therefore the one place iOS can disagree with the server about what a rule covers —
        // which it did, until lurker-ios#98. A PUBLIC-level rule covers `&local` because `&` is
        // a channel; reading it as a DM would leave the fetch un-vetoed here while the row
        // stayed hidden.
        let ignores = IgnoreSet(global: [IgnoreRule(mask: "bob", levels: ["PUBLIC"])])
        let line = [message("https://e.test/a", nick: "bob")]
        for channel in ["#chan", "&local", "+modeless", "!12345chan"] {
            #expect(
                urls(line, target: channel, ignores: ignores).isEmpty,
                "\(channel) is a channel, so a PUBLIC rule vetoes the fetch")
        }
        // ...and a real DM is MSGS, which that rule does not cover.
        #expect(urls(line, target: "bob", ignores: ignores) == ["https://e.test/a"])
    }

    @Test("asks for nothing when both settings are off, whatever the events say")
    func bothOffPrimesNothing() {
        #expect(
            PreviewSelection.urls(
                in: [message("https://e.test/a.png")], networkId: 1, target: "#chan",
                ignores: .empty, inlineMedia: false, linkPreviews: false
            ).isEmpty)
    }
}

@Suite("LinkPreview gating")
struct LinkPreviewGatingTests {

    private func preview(_ kind: PreviewKind, status: LinkPreview.Status = .ok) -> LinkPreview {
        LinkPreview(url: "https://e.test/x", status: status, kind: kind)
    }

    @Test("direct media follows the inline-media setting")
    func mediaFollowsMediaSetting() {
        for kind in [PreviewKind.image, .video, .audio] {
            #expect(preview(kind).isAllowed(inlineMedia: true, linkPreviews: false))
            #expect(!preview(kind).isAllowed(inlineMedia: false, linkPreviews: true))
        }
    }

    @Test("pages follow the link-previews setting")
    func pagesFollowPageSetting() {
        for kind in [PreviewKind.page, .videoEmbed] {
            #expect(preview(kind).isAllowed(inlineMedia: false, linkPreviews: true))
            #expect(!preview(kind).isAllowed(inlineMedia: true, linkPreviews: false))
        }
    }

    @Test("an unavailable preview is never rendered, whatever the settings")
    func unavailableNeverRenders() {
        #expect(!preview(.image, status: .unavailable).isAllowed(inlineMedia: true, linkPreviews: true))
        #expect(!preview(.page, status: .unavailable).isAllowed(inlineMedia: true, linkPreviews: true))
    }

    @Test("the server's answer governs, not the extension that prompted the ask")
    func serverAnswerGoverns() {
        // Asked as a page because the URL had no extension; came back an image. With link
        // previews on and inline media OFF, that must NOT render — otherwise "no inline
        // media" could be talked into showing one.
        let surprise = LinkPreview(url: "https://e.test/no-extension", status: .ok, kind: .image)
        #expect(!surprise.isAllowed(inlineMedia: false, linkPreviews: true))
        #expect(surprise.isAllowed(inlineMedia: true, linkPreviews: false))
    }
}

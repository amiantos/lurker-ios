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

    @Test("inline media selects file links and ignores pages")
    func mediaOnly() {
        #expect(
            urls("https://e.test/a.png https://e.test/article", media: true, pages: false)
                == ["https://e.test/a.png"])
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

    @Test("lets many images through, because a strip costs the same at 2 or at 12")
    func manyImages() {
        // Media renders as one horizontally-scrolling strip of fixed height, so the tenth
        // image costs no more screen than the second.
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

@Suite("MediaStrip row height")
struct MediaStripHeightTests {
    // The row-height RULE is shared with the web client (two heights, chosen by dominant
    // orientation); only the pixel values differ, because a phone has less vertical room to
    // give away. This asserts the rule, which is the part that has to match.
    private func media(_ sizes: [(Int, Int)]) -> [LinkPreview] {
        sizes.enumerated().map { index, size in
            LinkPreview(
                url: "https://e.test/\(index).png", status: .ok, kind: .image,
                thumbWidth: size.0, thumbHeight: size.1
            )
        }
    }

    @Test("a mostly-wide group gets the shorter row, a mostly-tall one the taller row")
    func orientation() {
        #expect(
            MediaStripLayout.height(for: media([(800, 600), (1200, 500)]))
                == MediaStripLayout.landscapeHeight)
        #expect(
            MediaStripLayout.height(for: media([(600, 900), (500, 1000)]))
                == MediaStripLayout.portraitHeight)
    }

    @Test("one tall image does not make a wide group tall")
    func primarilyPortrait() {
        #expect(
            MediaStripLayout.height(for: media([(600, 900), (1200, 500), (1000, 400)]))
                == MediaStripLayout.landscapeHeight)
    }

    @Test("a group with no dimensions falls back to the shorter row")
    func unknownDimensions() {
        let unknown = [LinkPreview(url: "https://e.test/x.png", status: .ok, kind: .image)]
        #expect(MediaStripLayout.height(for: unknown) == MediaStripLayout.landscapeHeight)
    }

    @Test("tile width follows the image's aspect against the row height")
    func itemWidth() {
        let wide = media([(1600, 900)])[0]
        let tall = media([(900, 1600)])[0]
        #expect(
            MediaStripLayout.itemWidth(for: tall, rowHeight: 270)
                < MediaStripLayout.itemWidth(for: wide, rowHeight: 270))
    }

    @Test("a panorama is capped rather than allowed to fill the strip")
    func widthCapped() {
        let panorama = media([(6000, 800)])[0]
        #expect(
            MediaStripLayout.itemWidth(for: panorama, rowHeight: 180)
                == MediaStripLayout.maxItemWidth)
    }

    @Test("no single tile may claim the whole strip")
    func fractionalCap() {
        // ⚠ Measured in the simulator: a flat 300pt cap on a 402pt-wide phone gave the first
        // tile 75% of the row, so a strip of five images read as one image with a sliver beside
        // it — losing the entire signal that there's more than one thing there. The next tile
        // has to peek in at any screen width.
        let wide = media([(1600, 900)])[0]
        for available in [320.0, 402.0, 440.0, 1024.0] as [CGFloat] {
            let width = MediaStripLayout.itemWidth(
                for: wide, rowHeight: 180, availableWidth: available)
            #expect(width <= available * MediaStripLayout.maxItemWidthFraction)
            #expect(width <= MediaStripLayout.maxItemWidth)
        }
    }

    @Test("an unmeasured image gets a landscape-ish tile, not a square one")
    func fallbackAspect() {
        let unknown = LinkPreview(url: "https://e.test/x.png", status: .ok, kind: .image)
        #expect(MediaStripLayout.itemWidth(for: unknown, rowHeight: 180) > 180)
    }
}

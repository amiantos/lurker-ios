// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

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

    @Test("caps a link-spam message")
    func caps() {
        let text = (0..<12).map { "https://e.test/\($0)" }.joined(separator: " ")
        #expect(urls(text).count == PreviewSelection.maxPerMessage)
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

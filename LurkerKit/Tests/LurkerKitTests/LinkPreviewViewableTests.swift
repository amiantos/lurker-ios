// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest

@testable import LurkerKit

/// What the media viewer will agree to present.
///
/// ⚠⚠ These exist because the failure they guard against is SILENT. When the server stopped
/// minting `src` for video and audio, a flat `src != nil` admission test dropped every clip out
/// of the gallery — the tap fell through to its "nothing to present" branch and opened Safari.
/// No crash, no error, nothing in a log: the player, its scrubbing, PiP and AirPlay were all
/// still compiled in and simply stopped being reachable. A feature can be deleted by a predicate.
final class LinkPreviewViewableTests: XCTestCase {
    private func preview(
        kind: PreviewKind, url: String = "https://cdn.example.com/a.mp4", src: String? = nil,
        thumb: String? = nil
    ) -> LinkPreview {
        LinkPreview(url: url, status: .ok, kind: kind, src: src, thumb: thumb)
    }

    // MARK: - Video and audio stream from the origin, so an address is all they need

    func testVideoIsViewableWithNoSrcAtAll() {
        XCTAssertTrue(preview(kind: .video).isViewable)
    }

    func testAudioIsViewableWithNoSrcAtAll() {
        XCTAssertTrue(preview(kind: .audio, url: "https://cdn.example.com/a.mp3").isViewable)
    }

    /// ⚠⚠ This asserted the opposite, on the grounds that "a self-hosted instance on a LAN is not
    /// required to be https". Two things were wrong with that. The address here is not the
    /// instance — since the server stopped minting `src`, it is the origin the link pointed at,
    /// and a LAN instance doesn't make a stranger's host cleartext. And the case it named, a
    /// `.local` host, is the one `NSAllowsLocalNetworking` already permits; what the assertion
    /// actually admitted was PUBLIC cleartext, which App Transport Security then refuses inside
    /// AVFoundation. Admitting it bought a failure the reader can't act on instead of the
    /// browser hand-off, which works.
    func testPlainHttpOriginIsNotViewable() {
        XCTAssertFalse(preview(kind: .video, url: "http://box.local/a.mp4").isViewable)
        XCTAssertFalse(preview(kind: .video, url: "http://cdn.example.com/a.mp4").isViewable)
    }

    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertTrue(preview(kind: .video, url: "HTTPS://cdn.example.com/a.mp4").isViewable)
    }

    /// ⚠ The one that matters for safety. A non-http scheme reaching `AVURLAsset` is an address
    /// we never vetted pointing at something that is not a media fetch.
    func testNonHttpSchemesAreRefused() {
        for url in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:video/mp4;base64,AAAA",
            "ftp://example.com/a.mp4",
        ] {
            XCTAssertFalse(preview(kind: .video, url: url).isViewable, "should refuse \(url)")
        }
    }

    func testUnparseableUrlIsRefused() {
        XCTAssertFalse(preview(kind: .video, url: "").isViewable)
    }

    /// ⚠ A stale `src` must not change the answer. Video is admitted on its ADDRESS, and the
    /// player deliberately ignores `src` even when a descriptor minted before the server change
    /// still carries one — that token now answers 404, so honouring it would be the branch that
    /// reliably fails.
    func testVideoWithLegacySrcIsStillAdmittedOnItsOrigin() {
        XCTAssertTrue(preview(kind: .video, src: "/api/link-preview/media/stale").isViewable)
    }

    // MARK: - Images still come from our proxy, so they still need bytes

    func testImageNeedsSrc() {
        XCTAssertFalse(preview(kind: .image, url: "https://cdn.example.com/a.png").isViewable)
        XCTAssertTrue(
            preview(kind: .image, url: "https://cdn.example.com/a.png", src: "/api/x").isViewable)
    }

    // MARK: - Cards are not viewer pages

    func testPagesAreNeverViewable() {
        for kind in [PreviewKind.page, .videoEmbed] {
            XCTAssertFalse(preview(kind: kind, url: "https://example.com/post").isViewable)
            XCTAssertFalse(preview(kind: kind, src: "/api/x").isViewable)
        }
    }

    // MARK: - What a row DRAWS, which is a different question from what the viewer plays

    /// The whole point of the poster: a clip stops being a grey box in the timeline. This is the
    /// same shape of predicate as `isViewable` above, so it gets the same guard — the failure
    /// mode is once again silent, a picture that simply never appears.
    func testVideoDrawsItsPoster() {
        XCTAssertEqual(
            preview(kind: .video, thumb: "/api/link-preview/poster/tok").inlinePicture,
            "/api/link-preview/poster/tok")
    }

    func testAudioDrawsItsPoster() {
        XCTAssertEqual(
            preview(kind: .audio, url: "https://cdn.example.com/a.mp3", thumb: "/api/p").inlinePicture,
            "/api/p")
    }

    /// A posterless clip has nothing to draw and says so, rather than reaching for the field that
    /// happens to be populated. The card falls back to its glyph.
    func testPosterlessClipDrawsNothing() {
        XCTAssertNil(preview(kind: .video).inlinePicture)
    }

    /// ⚠⚠ The stale-`src` trap again, on the drawing side this time. A descriptor minted before
    /// the server stopped relaying video can still be in a running client's store; drawing from
    /// its token means a 404 and a permanently-empty box, so the clip branch must never look at
    /// `src` — not even when there is no poster and it is the only thing there.
    func testClipNeverDrawsFromALegacySrc() {
        XCTAssertNil(preview(kind: .video, src: "/api/link-preview/media/stale").inlinePicture)
    }

    func testImageDrawsFromItsProxiedBytes() {
        XCTAssertEqual(
            preview(kind: .image, url: "https://cdn.example.com/a.png", src: "/api/x",
                    thumb: "/api/never").inlinePicture,
            "/api/x")
    }

    /// ⚠ A card draws its picture itself, beside its text and with its own shape rule, so it is
    /// not one of these. This is the test that stops the property being read as "any picture".
    func testACardsThumbnailIsNotAnInlinePicture() {
        for kind in [PreviewKind.page, .videoEmbed] {
            XCTAssertNil(
                preview(kind: kind, url: "https://example.com/post", thumb: "/api/x").inlinePicture,
                "a \(kind.rawValue) card draws its own thumbnail")
        }
    }

    // MARK: - Whether the thing on screen IS what the address points to

    /// ⚠⚠ The invariant: nothing is hidden without something rendered in its place. Every case
    /// below is a message whose text would silently lose a URL if this answered wrong.
    func testAPosterStandsInForItsVideo() {
        XCTAssertTrue(preview(kind: .video, thumb: "/api/link-preview/poster/tok").standsInForItsURL)
    }

    func testAPosterlessClipStandsInForNothing() {
        XCTAssertFalse(preview(kind: .video).standsInForItsURL)
        XCTAssertFalse(preview(kind: .video, src: "/api/link-preview/media/stale").standsInForItsURL)
    }

    /// ⚠⚠ Cover art is a picture ABOUT the track, not the track — the one place this parts
    /// company with `inlinePicture`, which happily draws it. Hiding an mp3's address left album
    /// art and a waveform glyph, with no filename and nothing to copy.
    func testCoverArtDoesNotStandInForItsAudio() {
        let mp3 = preview(kind: .audio, url: "https://cdn.example.com/a.mp3", thumb: "/api/p")
        XCTAssertFalse(mp3.standsInForItsURL)
        XCTAssertEqual(mp3.inlinePicture, "/api/p", "it still DRAWS the art")
    }

    func testAnImageStandsInForItselfOnlyOnceItHasBytes() {
        let url = "https://cdn.example.com/a.png"
        XCTAssertFalse(preview(kind: .image, url: url).standsInForItsURL)
        XCTAssertTrue(preview(kind: .image, url: url, src: "/api/x").standsInForItsURL)
    }

    func testACardNeverTakesItsLinkAway() {
        for kind in [PreviewKind.page, .videoEmbed] {
            XCTAssertFalse(
                preview(kind: kind, url: "https://example.com/post", src: "/api/x", thumb: "/api/y")
                    .standsInForItsURL, "a \(kind.rawValue) card keeps its URL")
        }
    }
}

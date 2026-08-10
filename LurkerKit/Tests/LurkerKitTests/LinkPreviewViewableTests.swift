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
        kind: PreviewKind, url: String = "https://cdn.example.com/a.mp4", src: String? = nil
    ) -> LinkPreview {
        LinkPreview(url: url, status: .ok, kind: kind, src: src)
    }

    // MARK: - Video and audio stream from the origin, so an address is all they need

    func testVideoIsViewableWithNoSrcAtAll() {
        XCTAssertTrue(preview(kind: .video).isViewable)
    }

    func testAudioIsViewableWithNoSrcAtAll() {
        XCTAssertTrue(preview(kind: .audio, url: "https://cdn.example.com/a.mp3").isViewable)
    }

    func testPlainHttpOriginIsViewable() {
        // A self-hosted instance on a LAN is not required to be https, and AVURLAsset opens
        // either. Refusing http here would make the player unreachable on exactly those setups.
        XCTAssertTrue(preview(kind: .video, url: "http://box.local/a.mp4").isViewable)
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
}

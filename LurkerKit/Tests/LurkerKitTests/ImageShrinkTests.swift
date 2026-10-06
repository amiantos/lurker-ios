// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// Pre-shrinking static images to the server's advertised longest edge (#155, the iOS half of
/// lurker#872): the rule that decides, and how the number reaches the store.
///
/// As with the upload cap, "the server didn't say" and "the server said a number" are
/// different states — and here the silence has no fallback at all.
@Suite("Image shrink")
@MainActor
struct ImageShrinkTests {

    private func source(
        _ width: Int, _ height: Int, frames: Int = 1, type: String = "public.jpeg",
        alpha: Bool = false
    ) -> ImageShrink.Source {
        ImageShrink.Source(
            pixelWidth: width, pixelHeight: height, frameCount: frames, typeIdentifier: type,
            hasAlpha: alpha
        )
    }

    // MARK: - The rule

    @Test("a photo past the advertised edge is shrunk to it, in its own format")
    func aBigPhotoIsShrunk() {
        #expect(ImageShrink.plan(source(8064, 6048), maxStaticImageDimension: 2048)
            == .shrink(maxPixelSize: 2048, format: .jpeg))
        // Portrait: it's the LONGEST edge, whichever way round.
        #expect(ImageShrink.plan(source(3024, 4032, type: "public.png"), maxStaticImageDimension: 2048)
            == .shrink(maxPixelSize: 2048, format: .png))
    }

    @Test("an image already within the edge is left alone")
    func aSmallImageIsLeftAlone() {
        #expect(ImageShrink.plan(source(2048, 1536), maxStaticImageDimension: 2048) == .leave)
        #expect(ImageShrink.plan(source(640, 480), maxStaticImageDimension: 2048) == .leave)
    }

    @Test("⚠⚠ no advertised dimension means no shrink — never a guessed 2048")
    func silenceShrinksNothing() {
        // An instance older than lurker#872, or the window before the snapshot. A guess would
        // halve a photo on an instance that keeps 4096, and the user would never know.
        #expect(ImageShrink.plan(source(8064, 6048), maxStaticImageDimension: nil) == .leave)
    }

    @Test("⚠⚠ an animation goes up verbatim, however big")
    func animationsPassThrough() {
        // The server skips the resize for these. A redraw would keep frame one and drop the
        // rest without an error — the trap the frame count exists for.
        for type in ["com.compuserve.gif", "public.png", "org.webmproject.webp"] {
            #expect(ImageShrink.plan(source(4000, 4000, frames: 24, type: type),
                                     maxStaticImageDimension: 2048) == .leave, "\(type)")
        }
    }

    @Test("⚠ a JPEG with extra images is still a photo, not an animation")
    func multiPictureJPEGIsShrunk() {
        // An MPO, or a JPEG carrying an HDR gain map: ImageIO counts the MPF images, the
        // server's decoder sees one page and resizes it. Leaving it alone would upload the
        // full original for nothing — silently, which is why it's worth a test.
        #expect(ImageShrink.plan(source(8064, 6048, frames: 2), maxStaticImageDimension: 2048)
            == .shrink(maxPixelSize: 2048, format: .jpeg))
    }

    @Test("⚠ only a non-JPEG with several images moves (sweep L13)")
    func theAnimationRule() {
        // An Ultra HDR photo from a Pixel or Samsung reads as two images: the photo and its gain
        // map. Badged and played, it flickered between the two.
        #expect(!ImageShrink.isAnimation(frameCount: 2, typeIdentifier: "public.jpeg"))
        #expect(ImageShrink.isAnimation(frameCount: 12, typeIdentifier: "com.compuserve.gif"))
        #expect(ImageShrink.isAnimation(frameCount: 12, typeIdentifier: "org.webmproject.webp"))
        #expect(ImageShrink.isAnimation(frameCount: 12, typeIdentifier: "public.png"))
        // ImageIO couldn't name the type: the count decides, as it always did.
        #expect(ImageShrink.isAnimation(frameCount: 12, typeIdentifier: nil))
        #expect(!ImageShrink.isAnimation(frameCount: 1, typeIdentifier: "com.compuserve.gif"))
    }

    @Test("a shrink past the decode budget leaves the shrinking to the server")
    func aHugeDecodeIsLeftToTheServer() {
        // 12000×9000 to an 8192 edge is 8192×6144 — ~200 MB of bitmap. The server can shrink it;
        // a jetsam can't be undone.
        #expect(ImageShrink.plan(source(12000, 9000), maxStaticImageDimension: 8192) == .leave)
        // The same photo to a 4096 edge fits, as does a long panorama to 8192.
        #expect(ImageShrink.plan(source(12000, 9000), maxStaticImageDimension: 4096)
            == .shrink(maxPixelSize: 4096, format: .jpeg))
        #expect(ImageShrink.plan(source(20000, 4000), maxStaticImageDimension: 8192)
            == .shrink(maxPixelSize: 8192, format: .jpeg))
    }

    @Test("a static GIF, by contrast, is just an image")
    func aStaticGIFIsShrunk() {
        #expect(ImageShrink.plan(source(4000, 3000, type: "com.compuserve.gif"),
                                 maxStaticImageDimension: 2048)
            == .shrink(maxPixelSize: 2048, format: .jpeg))
    }

    @Test("a format we don't write becomes JPEG, or PNG when it can be transparent")
    func otherFormatsBecomeOrdinary() {
        // ProRAW / DNG — the headline case: ~100 MB of RAW for a 2048px result.
        #expect(ImageShrink.plan(source(8064, 6048, type: "com.adobe.raw-image"),
                                 maxStaticImageDimension: 2048)
            == .shrink(maxPixelSize: 2048, format: .jpeg))
        // Transparency survives: a TIFF or WebP with alpha is not flattened onto black.
        #expect(ImageShrink.plan(source(5000, 5000, type: "public.tiff", alpha: true),
                                 maxStaticImageDimension: 2048)
            == .shrink(maxPixelSize: 2048, format: .png))
    }

    @Test("a JPEG stays a JPEG and a PNG a PNG, alpha or not")
    func jpegAndPNGKeepTheirFormat() {
        #expect(ImageShrink.output(for: source(1, 1, type: "public.png", alpha: false)) == .png)
        #expect(ImageShrink.output(for: source(1, 1, type: "public.jpeg", alpha: true)) == .jpeg)
    }

    @Test("every HEIC is converted, as before — the dimension only lets it go smaller")
    func heicIsAlwaysConverted() {
        // lurker#626: some iPhone HEICs 415 in the server's libheif, so they never go up as-is.
        let heic = source(4032, 3024, type: "public.heic")
        #expect(ImageShrink.plan(heic, maxStaticImageDimension: nil)
            == .convert(maxPixelSize: ImageShrink.heicDecodeCeiling, format: .jpeg))
        #expect(ImageShrink.plan(heic, maxStaticImageDimension: 2048)
            == .convert(maxPixelSize: 2048, format: .jpeg))
        // A server that keeps more than the decode ceiling doesn't lift it: the ceiling is
        // what keeps a 48 MP decode from becoming a jetsam.
        #expect(ImageShrink.plan(heic, maxStaticImageDimension: 8192)
            == .convert(maxPixelSize: ImageShrink.heicDecodeCeiling, format: .jpeg))
        // Even when it already fits: the conversion is about decodability, not size.
        #expect(ImageShrink.plan(source(640, 480, type: "public.heif"), maxStaticImageDimension: 2048)
            == .convert(maxPixelSize: 2048, format: .jpeg))
        // JPEG even with alpha: a conversion has no size check to fall back on, and a 4096px
        // photo as PNG could run into the upload cap where the JPEG never did.
        #expect(ImageShrink.plan(source(4032, 3024, type: "public.heic", alpha: true),
                                 maxStaticImageDimension: nil)
            == .convert(maxPixelSize: ImageShrink.heicDecodeCeiling, format: .jpeg))
    }

    @Test("an image ImageIO couldn't measure is left alone")
    func unmeasuredIsLeftAlone() {
        #expect(ImageShrink.plan(source(0, 0), maxStaticImageDimension: 2048) == .leave)
    }

    // MARK: - Reading it off the wire

    @Test("the snapshot's dimension is parsed, beside the cap")
    func snapshotCarriesTheDimension() {
        let frame = FrameParser.parseWs(
            #"{"kind":"snapshot","networks":[],"globalIgnores":[],"maxUploadBytes":26214400,"maxStaticImageDimension":2048}"#
        )
        guard case let .snapshot(_, _, limits, _) = frame else {
            Issue.record("expected a snapshot, got \(frame)")
            return
        }
        #expect(limits == UploadLimits(maxUploadBytes: 26_214_400, maxStaticImageDimension: 2048))
    }

    @Test("a snapshot from a server too old to advertise it says nothing")
    func anOldSnapshotSaysNothing() {
        let frame = FrameParser.parseWs(
            #"{"kind":"snapshot","networks":[],"globalIgnores":[],"maxUploadBytes":26214400}"#
        )
        guard case let .snapshot(_, _, limits, _) = frame else {
            Issue.record("expected a snapshot, got \(frame)")
            return
        }
        #expect(limits.maxStaticImageDimension == nil)
        #expect(limits.maxUploadBytes == 26_214_400, "the cap is independent of it")
    }

    @Test("a non-positive dimension is read as no answer")
    func nonsenseIsNotAnAnswer() {
        for value in ["0", "-1"] {
            let frame = FrameParser.parseWs(
                #"{"kind":"snapshot","networks":[],"globalIgnores":[],"maxStaticImageDimension":"#
                    + value + "}"
            )
            guard case let .snapshot(_, _, limits, _) = frame else {
                Issue.record("expected a snapshot")
                return
            }
            #expect(limits.maxStaticImageDimension == nil, "\(value) pixels is not an image")
        }
    }

    @Test("the settings frame carries the dimension when the user changed it")
    func settingsFrameCarriesTheDimension() {
        let frame = FrameParser.parseWs(
            #"{"kind":"settings","changes":{"uploads.image.max_dimension":1024},"maxUploadBytes":12582912,"maxStaticImageDimension":1024}"#
        )
        guard case let .settingsChanged(_, limits) = frame else {
            Issue.record("expected a settings frame, got \(frame)")
            return
        }
        #expect(limits.maxStaticImageDimension == 1024)
    }

    // MARK: - Reaching the store

    @Test("the snapshot seeds the dimension, and a snapshot without one clears it")
    func snapshotSeedsAndClears() {
        var state = LurkerStore.reduce(
            ChatState(),
            .snapshot([], globalIgnores: [], uploadLimits: UploadLimits(maxStaticImageDimension: 2048))
        )
        #expect(state.maxStaticImageDimension == 2048)
        // The refresh point: a reconnect to an instance that no longer says must not keep
        // shrinking to the last server's number.
        state = LurkerStore.reduce(state, .snapshot([], globalIgnores: [], uploadLimits: .unstated))
        #expect(state.maxStaticImageDimension == nil)
    }

    @Test("a settings frame that carries a dimension updates it")
    func aSettingsFrameUpdatesIt() {
        var state = LurkerStore.reduce(
            ChatState(),
            .snapshot([], globalIgnores: [], uploadLimits: UploadLimits(maxStaticImageDimension: 2048))
        )
        state = LurkerStore.reduce(
            state,
            .settingsChanged(
                ["uploads.image.max_dimension": .int(4096)],
                uploadLimits: UploadLimits(maxUploadBytes: 52_428_800, maxStaticImageDimension: 4096)
            )
        )
        #expect(state.maxStaticImageDimension == 4096)
        #expect(state.maxUploadBytes == 52_428_800)
    }

    @Test("⚠⚠ a settings frame about anything else must not clear the dimension")
    func anUnrelatedSettingsFrameLeavesItAlone() {
        var state = LurkerStore.reduce(
            ChatState(),
            .snapshot([], globalIgnores: [], uploadLimits: UploadLimits(
                maxUploadBytes: 209_715_200, maxStaticImageDimension: 2048))
        )
        state = LurkerStore.reduce(
            state, .settingsChanged(["chat.consolidate_joins": .bool(true)], uploadLimits: .unstated))
        #expect(state.maxStaticImageDimension == 2048)
        #expect(state.maxUploadBytes == 209_715_200)
    }

    @Test("a fresh state has no dimension")
    func aFreshStateHasNone() {
        #expect(ChatState().maxStaticImageDimension == nil)
    }
}

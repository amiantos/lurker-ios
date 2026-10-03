// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Whether to redraw an image on the device before uploading it, and how (#155).
///
/// The server downscales a static image to its longest-edge limit and re-encodes it, so a 48 MP
/// photo is ~100 MB on the wire to produce a ~300 KB file. Once the server advertises that limit
/// (`maxStaticImageDimension`, lurker#872) we can drop the pixels it would have thrown away before
/// spending the user's data on them.
///
/// This is only the decision. Measuring the source and doing the redraw is the app's job
/// (`ImageConverter`), because that is ImageIO; keeping the rule here keeps it testable and
/// keeps it portable to a platform with a different decoder.
///
/// ⚠⚠ **We shrink; the server re-encodes.** The output is a still-ordinary JPEG or PNG at high
/// quality, never the server's final format: the format policy, the quality setting and the
/// metadata scrub belong to the server and its operator, and doing that job here with worse
/// tools would silently override their configuration.
public enum ImageShrink {

    /// What ImageIO measured about the picked file.
    public struct Source: Sendable, Equatable {
        /// As stored — before EXIF orientation. Only the longest edge matters, and rotation
        /// doesn't change which edge that is.
        public var pixelWidth: Int
        public var pixelHeight: Int
        /// Images in the container (`CGImageSourceGetCount`). More than one is an animation
        /// (GIF, APNG, animated WebP) — except in a JPEG, see `plan`.
        public var frameCount: Int
        /// ImageIO's type for the bytes (`CGImageSourceGetType`), e.g. `public.jpeg`. Read from
        /// the file itself, never from its extension or the picker's claim.
        public var typeIdentifier: String
        public var hasAlpha: Bool

        public init(
            pixelWidth: Int, pixelHeight: Int, frameCount: Int, typeIdentifier: String,
            hasAlpha: Bool
        ) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.frameCount = frameCount
            self.typeIdentifier = typeIdentifier
            self.hasAlpha = hasAlpha
        }
    }

    /// The two formats a redraw writes. Both are ones the server's decoder reads without
    /// complaint, which is the whole requirement.
    public enum Format: Sendable, Equatable {
        case jpeg
        case png

        public var typeIdentifier: String {
            switch self {
            case .jpeg: "public.jpeg"
            case .png: "public.png"
            }
        }

        public var mime: String {
            switch self {
            case .jpeg: "image/jpeg"
            case .png: "image/png"
            }
        }

        public var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            }
        }
    }

    public enum Plan: Sendable, Equatable {
        /// Upload the original bytes.
        case leave
        /// Redraw to fit `maxPixelSize` on the longest edge because it saves bytes. If the
        /// result comes out no smaller than the original, upload the original instead — the
        /// server would have shrunk it anyway, so nothing is lost but the attempt.
        case shrink(maxPixelSize: Int, format: Format)
        /// Redraw whatever the size: the server can't decode the original at all (lurker#626).
        case convert(maxPixelSize: Int, format: Format)
    }

    /// The bound on a HEIC conversion when the server hasn't asked for less. It caps the
    /// decode: a 48 MP HEIC as a bitmap is ~190 MB, a jetsam risk on a pressured device, while
    /// 4096 is ~64 MB and still past what the server keeps by default.
    public static let heicDecodeCeiling = 4096

    /// The most pixels a shrink will decode to — the same ~64 MB of bitmap the HEIC ceiling
    /// allows. Past it the original goes up and the server shrinks it: that costs the user
    /// bandwidth, where decoding a 12000×9000 image to an 8192 edge (~200 MB) could cost them
    /// the app.
    public static let shrinkPixelBudget = heicDecodeCeiling * heicDecodeCeiling

    public static func plan(_ source: Source, maxStaticImageDimension: Int?) -> Plan {
        let longestEdge = max(source.pixelWidth, source.pixelHeight)
        guard longestEdge > 0 else { return .leave }

        // Some iPhone HEICs carry more `iref` references than the server's libheif allows and
        // come back 415 (lurker#626), so every HEIC is converted to JPEG, as it always has
        // been — the advertised dimension only lets the conversion go smaller. Always JPEG,
        // even with alpha: the conversion has no size check to fall back on, and a 4096px
        // photo as PNG is tens of MB. Ahead of the frame check because that's what the
        // conversion always did; Photos doesn't produce animated HEIC (that's `public.heics`).
        if Self.isHEIC(source.typeIdentifier) {
            let bound = min(maxStaticImageDimension ?? heicDecodeCeiling, heicDecodeCeiling)
            return .convert(maxPixelSize: bound, format: .jpeg)
        }

        // ⚠⚠ An animation goes up verbatim. The server skips the resize for it, so it keeps
        // every frame — and a redraw here would flatten it to the first one, with no error.
        //
        // ⚠ But a JPEG with more than one image is not an animation. An MPO (stereo cameras)
        // or a JPEG carrying an HDR gain map stores its extra images in an MPF segment, which
        // ImageIO counts and the server's decoder doesn't — to sharp it is one page, resized
        // like any photo. Skipping it would quietly upload the full original.
        let animated = source.frameCount > 1 && source.typeIdentifier != Format.jpeg.typeIdentifier
        guard !animated else { return .leave }

        // ⚠⚠ No dimension, no shrink. The server didn't say what it keeps, so nothing tells us
        // which pixels are waste; a guessed 2048 would cost a user on a 4096 instance half
        // their resolution without a word.
        guard let maxStaticImageDimension, longestEdge > maxStaticImageDimension else {
            return .leave
        }

        // Past the budget, let the server do it (see `shrinkPixelBudget`).
        let scale = Double(maxStaticImageDimension) / Double(longestEdge)
        let pixels = Double(source.pixelWidth) * scale * Double(source.pixelHeight) * scale
        guard pixels <= Double(shrinkPixelBudget) else { return .leave }

        return .shrink(maxPixelSize: maxStaticImageDimension, format: output(for: source))
    }

    /// JPEG and PNG keep their own format. Anything else — RAW/DNG, TIFF, a static GIF or
    /// WebP — becomes PNG when it can be transparent, so transparency survives, and JPEG
    /// otherwise, because a photo as PNG would be several times the bytes this exists to save.
    static func output(for source: Source) -> Format {
        switch source.typeIdentifier {
        case Format.jpeg.typeIdentifier: .jpeg
        case Format.png.typeIdentifier: .png
        default: source.hasAlpha ? .png : .jpeg
        }
    }

    static func isHEIC(_ typeIdentifier: String) -> Bool {
        typeIdentifier == "public.heic" || typeIdentifier == "public.heif"
    }
}

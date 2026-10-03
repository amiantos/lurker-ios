// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import ImageIO
import LurkerKit
import UniformTypeIdentifiers

/// Redraws a picked image before it is uploaded, when `ImageShrink.plan` says to (#14, #155).
///
/// Two reasons, one redraw:
///
/// - **Shrink.** The server keeps a static image only up to its advertised longest edge
///   (`maxStaticImageDimension`, lurker#872) and throws the rest away, so a 48 MP photo would be
///   ~100 MB on the wire for a ~300 KB result. We drop those pixels first.
/// - **Convert.** The server optimizes images with sharp (libvips → libheif). libheif enforces
///   a security limit on the number of references in a HEIC's `iref` box — default 16 — and
///   some iPhone HEICs blow past it (HDR gain maps, depth, and other computational-photography
///   derivatives each add references), so the upload comes back `415 "Number of references in
///   iref box … exceeds the security limits"`. sharp doesn't expose that limit (lurker#626), so
///   Apple's decoder, which has no such cap, transcodes every HEIC first.
///
/// The server re-encodes regardless, so the extra hop costs ~nothing in quality. The redraw
/// also drops the original's metadata (GPS included) and bakes its EXIF orientation into the
/// pixels, so the result is upright without it.
///
/// `nonisolated` because the work happens on a detached task: under the target's default
/// main-actor isolation it would otherwise be hopping back to the main thread to decode.
nonisolated enum ImageConverter {

    /// A redrawn image in a temp file the caller owns and must delete.
    struct Converted {
        let url: URL
        let format: ImageShrink.Format
    }

    /// The redrawn image, or nil to mean "upload the original untouched" — which is also what a
    /// failure returns: better to try the original than to block the upload outright. Runs off
    /// the main actor; decoding a photo is real work.
    ///
    /// A cancel reaches the redraw, which checks it between the decode and the encode — ImageIO
    /// can't be interrupted mid-decode, but a RAW's encode needn't follow a tap on Cancel.
    static func prepare(source: URL, maxStaticImageDimension: Int?) async -> Converted? {
        let task = Task.detached(priority: .userInitiated) {
            redraw(source: source, maxStaticImageDimension: maxStaticImageDimension)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func redraw(source: URL, maxStaticImageDimension: Int?) -> Converted? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(src) as String?,
              // ⚠ ImageIO opens more than images — a PDF from the Files picker among them — and
              // rasterizing a document would be a silent, lossy surprise. Only an image is ours.
              UTType(type)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let measured = ImageShrink.Source(
            pixelWidth: width,
            pixelHeight: height,
            frameCount: CGImageSourceGetCount(src),
            typeIdentifier: type,
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        )
        let maxPixelSize: Int
        let format: ImageShrink.Format
        let onlyIfSmaller: Bool
        switch ImageShrink.plan(measured, maxStaticImageDimension: maxStaticImageDimension) {
        case .leave:
            return nil
        case .shrink(let size, let output):
            (maxPixelSize, format, onlyIfSmaller) = (size, output, true)
        case .convert(let size, let output):
            (maxPixelSize, format, onlyIfSmaller) = (size, output, false)
        }

        // Decode straight to the target size rather than rasterizing the full image and scaling
        // it: ImageIO subsamples while it decodes, so a 48 MP original never exists as a bitmap.
        // `FromImageAlways` ignores a small embedded preview; `WithTransform` applies the EXIF
        // orientation, since the metadata that carried it doesn't survive the redraw.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
              !Task.isCancelled
        else { return nil }

        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lurker-img-\(UUID().uuidString).\(format.fileExtension)")
        guard let writer = CGImageDestinationCreateWithURL(
            dest as CFURL, format.typeIdentifier as CFString, 1, nil
        ) else { return nil }
        // High, not the server's quality: this is an intermediate the server decodes and
        // re-encodes at the quality it was configured with. Ignored for PNG.
        let encode: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(writer, image, encode as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }

        // A shrink exists to save bytes. One that didn't (a tiny, heavily compressed JPEG
        // redrawn at high quality can grow) is dropped, and the server does the shrinking.
        if onlyIfSmaller, let before = fileSize(source), let after = fileSize(dest), after >= before {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        return Converted(url: dest, format: format)
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}

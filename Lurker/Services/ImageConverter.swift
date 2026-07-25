// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Normalizes an image the server's decoder can't read into one it can (#14).
///
/// The server optimizes images with sharp (libvips → libheif). libheif enforces a security
/// limit on the number of references in a HEIC's `iref` box — default 16 — and some iPhone
/// HEICs blow past it (HDR gain maps, depth, and other computational-photography derivatives
/// each add references), so the upload comes back `415 "Number of references in iref box …
/// exceeds the security limits"`. sharp doesn't expose that limit, so we sidestep it: Apple's
/// own decoder has no such cap, so we transcode the HEIC to JPEG on-device and upload that.
/// The server re-encodes images to WebP regardless, so the extra hop costs ~nothing in
/// quality — and it permanently insulates iOS from this whole class of server decode failure.
enum ImageConverter {

    /// If `source` is HEIC/HEIF, transcode it to a JPEG temp file and return that URL (the
    /// caller owns it and must delete it); otherwise return nil to mean "upload the original
    /// untouched." A conversion failure also returns nil — better to try the original than to
    /// block the upload outright. Runs off the main actor; decoding a photo is real work.
    static func jpegIfProblematicHEIC(source: URL, mime: String) async -> URL? {
        let ext = source.pathExtension.lowercased()
        let isHEIC = mime == "image/heic" || mime == "image/heif" || ext == "heic" || ext == "heif"
        guard isHEIC else { return nil }

        return await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
            // Decode straight to a bounded size via ImageIO instead of rasterizing the full
            // image: a 48 MP HEIC as a UIImage is ~190 MB of bitmap, a jetsam risk on a
            // pressured device. The server downsizes to ~2048px anyway, so 4096 is ample
            // headroom while capping the decode at ~64 MB. `WithTransform` bakes in the EXIF
            // orientation so the result is upright.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
                  let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
            else { return nil }
            let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lurker-img-\(UUID().uuidString).jpg")
            do {
                try data.write(to: dest)
                return dest
            } catch {
                return nil
            }
        }.value
    }
}

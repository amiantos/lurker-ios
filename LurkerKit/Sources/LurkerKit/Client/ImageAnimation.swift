// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Whether a picture plays: the question a link preview asks before it badges an image as an
/// animation and plays it in the viewer.
///
/// ⚠ More images than one is not the answer. ImageIO counts every image a container holds, and
/// most containers that hold several are stills: a JPEG carrying an HDR gain map (Pixel and
/// Samsung Ultra HDR, iPhone HDR exports) or a stereo MPO, a multi-page TIFF, an ICO's sizes, an
/// HEIC collection. Played as frames, an Ultra HDR photo flickered between itself and its
/// greyscale gain map (sweep L13). So only the formats that animate count, by the type ImageIO
/// reads: a GIF, an APNG and an HEIC sequence were checked against ImageIO (a three-image HEIC
/// reads as `public.heic`, an HEIC sequence as `public.heics`); WebP and AVIF sequences are by
/// their registered types.
///
/// Not the upload's rule (`ImageShrink`), which asks a different question — what the server's
/// decoder will leave unresized — and answers it differently.
public enum ImageAnimation {
    /// The type identifiers that can hold an animation.
    static let animatableTypes: Set<String> = [
        "com.compuserve.gif",
        "public.png", // APNG
        "org.webmproject.webp",
        "public.heics",
        "public.avis",
    ]

    /// Whether an image ImageIO reads as `frameCount` images of type `typeIdentifier` plays.
    public static func plays(frameCount: Int, typeIdentifier: String?) -> Bool {
        guard frameCount > 1, let typeIdentifier else { return false }
        return animatableTypes.contains(typeIdentifier)
    }
}

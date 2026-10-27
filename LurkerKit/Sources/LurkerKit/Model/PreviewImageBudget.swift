// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// How much of a preview image the app will decode.
///
/// The relay streams origin bytes unresized under an 8 MB byte cap, and bytes say nothing about
/// pixels: a uniform-colour PNG whose canvas is 20,000 on a side compresses to a few hundred KB
/// and decodes to 1.6 GB, which is jetsam for every reader whose client paints it — and, since
/// a still is painted during backlog restore, jetsam again on relaunch while that row is in the
/// visible backlog. Any channel peer can post such a link. So a still is judged by its DECLARED
/// canvas, read from the container's header before a pixel is decoded, and what passes is
/// decoded to a bounded edge, the way an animation's frames already were.
///
/// This is only the rule. The header read and the downsampled decode are ImageIO and live in
/// the app (`PreviewImageLoader`), as `ImageShrink`'s redraw lives in `ImageConverter`.
public enum PreviewImageBudget {
    /// Pixels a still may declare and still be decoded. 50 MP clears a phone's 48 MP frame
    /// (8064×6048, a 3–6 MB HEIC or JPEG, so under the relay's byte cap) and most panoramas,
    /// because a refusal is a blank tile with no fallback and must stay rare. The bound still
    /// matters even though what passes is downsampled on the way in: ImageIO's thumbnail
    /// decode is bounded, not free — measured on the host, a 49 MP PNG peaked at ~105 MB
    /// resident against ~210 MB for the full decode, a 24 MP PNG or JPEG at ~70 MB, and the
    /// header read itself at ~11 MB. Decodes run one at a time (`PreviewImageLoader`), so that
    /// peak is the app's, not one row's.
    public static let maxPixels = 50_000_000

    /// Longest edge a passing still is decoded to: twice the widest preview column at 3× (a
    /// lone image across a phone), and the viewer's full iPad width at 2×. A 2048² bitmap is
    /// 16 MB where a 48 MP photo was 190 MB — the old path's cost for a perfectly ordinary
    /// link, against a 32 MB decoded-image cache. ⚠ The viewer shows this same bitmap, so a
    /// zoom past 2× on a very large photo is soft; that is the trade, and it is the one the
    /// animation path already made at 720.
    public static let maxPixelSize = 2048

    /// Whether a still declaring this canvas may be decoded at all.
    public static func admits(pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        // Division, not a product: a lying header can declare two dimensions whose product
        // overflows `Int`, and an overflow trap would be a crash of our own making.
        return pixelHeight <= maxPixels / pixelWidth
    }
}

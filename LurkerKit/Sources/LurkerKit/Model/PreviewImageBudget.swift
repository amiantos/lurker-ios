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
    /// Pixels a still may declare and still be decoded. 24 MP is twice a phone's everyday 12 MP
    /// frame and covers a 6000×4000 camera file; a 48 MP shot is a 10–20 MB JPEG that the relay's
    /// 8 MB byte cap refuses before this rule sees it. The bound matters even though what passes
    /// is downsampled on the way in: ImageIO's thumbnail decode of a PNG is bounded, not free —
    /// measured on the host, a 49 MP PNG peaked at ~105 MB resident against ~210 MB for the
    /// full decode, and a 24 MP PNG or JPEG at ~70 MB, with the header read itself at ~11 MB.
    /// Past this the still is simply not shown.
    public static let maxPixels = 24_000_000

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

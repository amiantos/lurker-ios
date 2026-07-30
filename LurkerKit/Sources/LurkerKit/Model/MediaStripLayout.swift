// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import CoreGraphics

/// How a row of two-or-more images/videos is sized.
///
/// Lives in LurkerKit rather than beside the view so it can be tested without UIKit — the rule
/// is the part worth testing, and a copy of it in a test file would have tested the copy.
public enum MediaStripLayout {

    /// The two possible row heights.
    ///
    /// Exactly two, following Slack, and that's the point rather than a shortcut: a message list
    /// with a small KNOWN set of attachment heights can be measured correctly on its first pass,
    /// because the height comes from the server's dimensions and is settled before a single byte
    /// of image data arrives.
    ///
    /// The values differ from the web client's 200/300 deliberately — a phone has less vertical
    /// room to give away. It's the RULE that has to match between the clients, not the pixels.
    public static let landscapeHeight: CGFloat = 180
    public static let portraitHeight: CGFloat = 270

    /// Absolute ceiling on one tile's width.
    public static let maxItemWidth: CGFloat = 300

    /// The most of the strip's width one tile may claim.
    ///
    /// ⚠ Measured on a phone: a flat 300pt cap on a 402pt-wide screen gives the first tile 75%
    /// of the row, so a strip of five images looks like one image with a sliver beside it — the
    /// entire signal that there's more than one thing here is lost. A fraction guarantees the
    /// next tile always peeks in and the strip reads as a strip, at any screen width.
    public static let maxItemWidthFraction: CGFloat = 0.62

    /// Fallback aspect for an image the server couldn't measure.
    ///
    /// 4:3 rather than square: an unknown image is far likelier to be a landscape photo or a
    /// screenshot than a perfect square.
    public static let fallbackAspect: CGFloat = 4.0 / 3.0

    /// Row height for a group, from its dominant orientation.
    ///
    /// "Primarily portrait" rather than "any portrait": one tall image among four wide ones
    /// shouldn't make the whole row tall.
    public static func height(for previews: [LinkPreview]) -> CGFloat {
        let portrait = previews.filter { ($0.thumbHeight ?? 0) > ($0.thumbWidth ?? 0) }.count
        return portrait * 2 > previews.count ? portraitHeight : landscapeHeight
    }

    /// Tile width for one preview at a given row height, capped.
    ///
    /// `availableWidth` is the strip's own width; pass 0 when it isn't known yet and only the
    /// absolute ceiling applies. A panorama is cropped rather than allowed to fill the strip —
    /// the point of a strip is that you can see there's more than one thing in it.
    public static func itemWidth(
        for preview: LinkPreview, rowHeight: CGFloat, availableWidth: CGFloat = 0
    ) -> CGFloat {
        let aspect: CGFloat
        if let w = preview.thumbWidth, let h = preview.thumbHeight, w > 0, h > 0 {
            aspect = CGFloat(w) / CGFloat(h)
        } else {
            aspect = fallbackAspect
        }
        var cap = maxItemWidth
        if availableWidth > 0 {
            cap = min(cap, availableWidth * maxItemWidthFraction)
        }
        return min(rowHeight * aspect, cap)
    }
}

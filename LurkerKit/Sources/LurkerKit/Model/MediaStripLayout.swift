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

    /// How wide one tile may get. A panorama is cropped rather than allowed to fill the strip —
    /// the point of a strip is that you can see there's more than one thing in it.
    public static let maxItemWidth: CGFloat = 300

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
    public static func itemWidth(for preview: LinkPreview, rowHeight: CGFloat) -> CGFloat {
        let aspect: CGFloat
        if let w = preview.thumbWidth, let h = preview.thumbHeight, w > 0, h > 0 {
            aspect = CGFloat(w) / CGFloat(h)
        } else {
            aspect = fallbackAspect
        }
        return min(rowHeight * aspect, maxItemWidth)
    }
}

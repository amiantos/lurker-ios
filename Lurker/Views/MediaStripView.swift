// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Two or more images/videos in one message, as a single horizontally-scrolling row.
///
/// The web client's treatment, ported so the two clients look like one product. Three portrait
/// screenshots stacked is most of a phone screen of somebody else's message; as a strip it's
/// one glance and a swipe.
///
/// The sizing rule lives in `MediaStripLayout` (LurkerKit), so it can be tested without UIKit.
/// Exactly two possible row heights is the point rather than a shortcut — see there.
final class MediaStripView: UIView {

    private static let spacing: CGFloat = 4
    private static let corner: CGFloat = 8
    /// The fade's width at each end.
    private static let fadeWidth: CGFloat = 40

    private let scrollView = UIScrollView()
    private let row = UIStackView()

    /// Fades the strip's content at an edge that can still move.
    ///
    /// ⚠ Masks THIS view, never the scroll view. For a `UIScrollView`, `bounds.origin` *is* the
    /// content offset — the layer's coordinate space moves as you drag — so a mask on its layer
    /// travels with the content and has to be re-positioned on every single scroll event. That
    /// was the first version, and it behaved exactly as you'd expect: the fade slid around under
    /// the drag and never settled at the edges. This view's bounds don't move, so the mask is
    /// positioned once per layout and simply stays put.
    ///
    /// A mask rather than a gradient laid on top, for the same reason as on the web: an overlay
    /// would have to know the background colour, and that's the list background normally but the
    /// highlight wash on a matched row — two values to keep in sync for no gain.
    private let fade = CAGradientLayer()

    private var urls: [String] = []
    private var onOpen: ((URL) -> Void)?
    private var heightConstraint: NSLayoutConstraint!
    /// Held so tile widths can be recomputed when the strip's own width changes — they're capped
    /// as a fraction of it, and it isn't known when the tiles are built.
    private var items: [LinkPreview] = []
    private var itemWidths: [NSLayoutConstraint] = []
    private var lastLaidOutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        // Deliberately NOT `decelerationRate = .fast`. An earlier version set it with a comment
        // claiming it made flicks land on an image; it does no such thing — it just makes every
        // flick stop abruptly. Landing on a tile is `scrollViewWillEndDragging`'s job, below.
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        row.axis = .horizontal
        row.spacing = Self.spacing
        row.alignment = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        scrollView.addSubview(row)

        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fade

        heightConstraint = heightAnchor.constraint(
            equalToConstant: MediaStripLayout.landscapeHeight)
        NSLayoutConstraint.activate([
            heightConstraint,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not from a nib") }

    /// Drop the tiles, so a recycled cell doesn't hold decoded images the NSCache is trying to
    /// evict. The view itself is retained by its owner and reconfigured on demand.
    func releaseImages() {
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        items = []
        itemWidths = []
        urls = []
        lastLaidOutWidth = 0
    }

    func configure(
        previews: [LinkPreview], model: ChatViewModel, onOpen: @escaping (URL) -> Void
    ) {
        self.onOpen = onOpen
        urls = previews.map(\.url)
        items = previews
        itemWidths = []
        lastLaidOutWidth = 0
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let rowHeight = MediaStripLayout.height(for: previews)
        heightConstraint.constant = rowHeight

        for (index, preview) in previews.enumerated() {
            row.addArrangedSubview(item(preview, index: index, height: rowHeight, model: model))
        }
        // A recycled cell must not inherit the last message's scroll position.
        scrollView.contentOffset = .zero
        setNeedsLayout()
    }

    /// One tile. Width follows the image's own aspect ratio against the row's fixed height, so
    /// widths vary and the strip reads as a strip rather than as a grid of letterboxed cells.
    private func item(
        _ preview: LinkPreview, index: Int, height: CGFloat, model: ChatViewModel
    ) -> UIView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = Self.corner
        imageView.backgroundColor = .secondarySystemFill
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .button
        imageView.accessibilityLabel = preview.kind == .video ? "Video" : "Image"

        // Width from the SERVER's dimensions, so the tile is right before any bytes arrive. The
        // fractional cap needs our own width, which isn't resolved yet — layoutSubviews revises
        // these once it is.
        let width = MediaStripLayout.itemWidth(
            for: preview, rowHeight: height, availableWidth: bounds.width)
        let constraint = imageView.widthAnchor.constraint(equalToConstant: width)
        constraint.isActive = true
        itemWidths.append(constraint)

        // ⚠ ONLY for images. The server puts the proxied CONTENT in `src` for image, video AND
        // audio — so loading `src` unconditionally meant a video tile pulled up to 8 MB of MP4
        // through the authenticated proxy, handed it to `UIImage(data:)`, got nil, and stayed
        // grey anyway. Two video links on cellular was 16 MB for two grey squares.
        // MessageAttachmentsView.mediaView had this right; the strip didn't.
        if preview.kind == .image, let path = preview.src {
            PreviewImageLoader.shared.load(path: path, using: model) { [weak imageView] image in
                imageView?.image = image
            }
        }

        // Video tiles carry a play badge over the poster and hand off on tap, like the single
        // case — an AVPlayer per tile in a scrolling list is a memory problem.
        if preview.kind == .video {
            let badge = UIImageView(image: UIImage(systemName: "play.circle.fill"))
            badge.tintColor = .white
            badge.layer.shadowOpacity = 0.35
            badge.layer.shadowRadius = 6
            badge.layer.shadowOffset = .zero
            badge.translatesAutoresizingMaskIntoConstraints = false
            imageView.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                badge.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 40),
                badge.heightAnchor.constraint(equalToConstant: 40),
            ])
        }

        // A tap must not swallow a drag. `cancelsTouchesInView = false` plus the recognizer only
        // firing on a completed tap means a swipe that starts on a tile still scrolls the strip.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        imageView.addGestureRecognizer(tap)
        imageView.tag = index
        return imageView
    }

    @objc private func tapped(_ sender: UITapGestureRecognizer) {
        guard let index = sender.view?.tag, urls.indices.contains(index),
            let url = URL(string: urls[index])
        else { return }
        onOpen?(url)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Tile widths are capped as a fraction of the strip's width, which isn't known when the
        // tiles are built — so they're revised the first time we have a real width, and again on
        // rotation. Guarded on a change so this isn't a layout feedback loop.
        if bounds.width > 0, bounds.width != lastLaidOutWidth {
            lastLaidOutWidth = bounds.width
            let rowHeight = heightConstraint.constant
            for (constraint, preview) in zip(itemWidths, items) {
                constraint.constant = MediaStripLayout.itemWidth(
                    for: preview, rowHeight: rowHeight, availableWidth: bounds.width)
            }
        }

        // This view's bounds, which don't move when the content scrolls.
        fade.frame = bounds
        // ⚠ Force the scroll view's own layout FIRST. `contentSize` is resolved during its layout
        // pass, which runs after ours — so reading it here without this gives 0 on the first pass,
        // `canScrollRight` comes out false, and the fade never appears at all. That's exactly what
        // the simulator showed: tiles hard-clipped at the screen edge with no gradient.
        scrollView.layoutIfNeeded()
        updateFade()
    }

    /// Fade only an edge that can actually move.
    ///
    /// A permanent fade lies in both directions: it implies more content when the strip is
    /// fully scrolled, and dims the first image for no reason when there's nothing to the left.
    /// Colours only — the frame is layout's business, and recomputing it here is what made the
    /// first version drift.
    private func updateFade() {
        let maxOffset = scrollView.contentSize.width - scrollView.bounds.width
        // A point of slack at each end: sub-pixel offsets and rubber-band overscroll otherwise
        // flicker the fade on and off right at the extremes.
        let canScrollLeft = scrollView.contentOffset.x > 1
        let canScrollRight = scrollView.contentOffset.x < maxOffset - 1
        let opaque = UIColor.black.cgColor
        let clear = UIColor.clear.cgColor

        // No implicit animation: these are driven from scroll events, and a half-second colour
        // crossfade per event is both wrong and visible.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.colors = [
            canScrollLeft ? clear : opaque,
            opaque,
            opaque,
            canScrollRight ? clear : opaque,
        ]
        let width = max(bounds.width, 1)
        let stop = min(Self.fadeWidth / width, 0.5)
        fade.locations = [0, NSNumber(value: stop), NSNumber(value: 1 - stop), 1]
        CATransaction.commit()
    }

    /// Where each tile starts, in content coordinates.
    private func tileOffsets() -> [CGFloat] {
        var out: [CGFloat] = []
        var x: CGFloat = 0
        for view in row.arrangedSubviews {
            out.append(x)
            x += view.bounds.width + Self.spacing
        }
        return out
    }
}

extension MediaStripView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFade()
    }

    /// Land on a tile edge rather than halfway across an image.
    ///
    /// Done here rather than with `isPagingEnabled` (tiles are different widths, so a page is
    /// the wrong unit) and rather than by changing the deceleration rate (which doesn't snap to
    /// anything, it just stops sooner).
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let offsets = tileOffsets()
        guard !offsets.isEmpty else { return }
        let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let proposed = targetContentOffset.pointee.x
        // Don't fight the ends: at either extreme the natural resting place IS the edge, and
        // snapping to a tile there would leave a sliver of dead space.
        guard proposed > 0, proposed < maxOffset else { return }

        let nearest = offsets.min(by: { abs($0 - proposed) < abs($1 - proposed) }) ?? proposed
        targetContentOffset.pointee.x = min(max(0, nearest), maxOffset)
    }
}

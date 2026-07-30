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
    /// Masks the scroll view so its content dissolves at an edge that can still move.
    ///
    /// A mask rather than a gradient laid on top, for the same reason as on the web: an overlay
    /// would have to know the background colour, and that's the list background normally but the
    /// highlight wash on a matched row — two values to keep in sync for no gain.
    private let fade = CAGradientLayer()
    private var urls: [String] = []
    private var onOpen: ((URL) -> Void)?
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        // Snap so a flick lands on an image rather than halfway across one.
        scrollView.decelerationRate = .fast
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
        scrollView.layer.mask = fade

        heightConstraint = heightAnchor.constraint(equalToConstant: MediaStripLayout.landscapeHeight)
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

    func configure(
        previews: [LinkPreview], model: ChatViewModel, onOpen: @escaping (URL) -> Void
    ) {
        self.onOpen = onOpen
        urls = previews.map(\.url)
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let rowHeight = MediaStripLayout.height(for: previews)
        heightConstraint.constant = rowHeight

        for (index, preview) in previews.enumerated() {
            row.addArrangedSubview(item(preview, index: index, height: rowHeight, model: model))
        }
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

        // Width from the SERVER's dimensions, so the tile is right before any bytes arrive.
        let width = MediaStripLayout.itemWidth(for: preview, rowHeight: height)
        imageView.widthAnchor.constraint(equalToConstant: width).isActive = true

        if let path = preview.src {
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

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
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
        fade.frame = scrollView.bounds
        updateFade()
    }

    /// Fade only an edge that can actually move.
    ///
    /// A permanent fade lies in both directions: it implies more content when the strip is
    /// fully scrolled, and dims the first image for no reason when there's nothing to the left.
    private func updateFade() {
        let maxOffset = scrollView.contentSize.width - scrollView.bounds.width
        let canScrollLeft = scrollView.contentOffset.x > 1
        let canScrollRight = scrollView.contentOffset.x < maxOffset - 1
        let opaque = UIColor.black.cgColor
        let clear = UIColor.clear.cgColor

        fade.colors = [
            canScrollLeft ? clear : opaque,
            opaque,
            opaque,
            canScrollRight ? clear : opaque,
        ]
        let width = max(scrollView.bounds.width, 1)
        let stop = Self.fadeWidth / width
        fade.locations = [0, NSNumber(value: stop), NSNumber(value: 1 - stop), 1]
    }
}

extension MediaStripView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFade()
    }
}

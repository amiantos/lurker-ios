// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Inline media and link preview cards, stacked under a message body.
///
/// Slack's treatment rather than Discord's — a thin accent rule and restrained text, not a
/// large colourful engagement card. The message list is a dense log, and a preview should
/// read as a guest in it.
///
/// **Fixed heights, deliberately.** Every attachment this draws has a height that is known
/// the moment the *metadata* arrives, before any image bytes do: an inline image gets a
/// fixed-height aspect-fill container, a card's thumbnail is a fixed square, a video thumb is
/// 16:9. That's a real constraint on the design, and it buys the thing that matters most in a
/// scrolling list: an image finishing its download never changes a row's height, so the
/// content under your thumb never jumps. Reflowing on image load is the standard way this
/// feature ships badly.
///
/// The row still has to re-lay-out once, when the metadata lands and an attachment appears at
/// all — that's `LinkPreviewStore.onUpdate`, which the chat screen turns into a reload.
final class MessageAttachmentsView: UIStackView {

    /// Full-width media. Tall enough to be worth showing, short enough that one screenshot
    /// doesn't evict the conversation from the screen.
    private static let mediaHeight: CGFloat = 200
    private static let thumbSide: CGFloat = 64
    private static let corner: CGFloat = 8

    /// Opens a URL. Held rather than hardcoded so a future in-app viewer is a wiring change.
    var onOpen: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 6
        alignment = .fill
        isLayoutMarginsRelativeArrangement = true
        layoutMargins = UIEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not from a nib") }

    /// Draw the previews for one message. Passing an empty array collapses the view entirely,
    /// which is the common case and has to stay cheap — most messages have no links.
    func configure(previews: [LinkPreview], model: ChatViewModel) {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        isHidden = previews.isEmpty
        guard !previews.isEmpty else { return }

        for preview in previews {
            switch preview.kind {
            case .image, .video, .audio:
                addArrangedSubview(mediaView(preview, model: model))
            case .page, .videoEmbed:
                addArrangedSubview(cardView(preview, model: model))
            }
        }
    }

    // MARK: - Direct media

    /// No card, no chrome — just the thing. A frame around an image is furniture around
    /// content.
    private func mediaView(_ preview: LinkPreview, model: ChatViewModel) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemFill
        container.layer.cornerRadius = Self.corner
        container.clipsToBounds = true
        container.heightAnchor.constraint(equalToConstant: Self.mediaHeight).isActive = true

        // Video and audio show their poster/placeholder here and hand off on tap. Playing
        // media inline in a table cell is an AVPlayer per row and a memory problem; the
        // system player is one tap away and is what the platform's users expect.
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        if preview.kind == .image, let path = preview.src {
            apply(path: path, to: imageView, model: model)
            imageView.accessibilityLabel = "Image"
        } else {
            let glyph = UIImageView(
                image: UIImage(systemName: preview.kind == .video ? "play.circle.fill" : "waveform")
            )
            glyph.tintColor = .secondaryLabel
            glyph.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                glyph.widthAnchor.constraint(equalToConstant: 44),
                glyph.heightAnchor.constraint(equalToConstant: 44),
            ])
            container.accessibilityLabel = preview.kind == .video ? "Video" : "Audio"
        }

        container.isAccessibilityElement = true
        container.accessibilityTraits = .button
        attachTap(to: container, opening: preview.url)
        return container
    }

    // MARK: - Cards

    private func cardView(_ preview: LinkPreview, model: ChatViewModel) -> UIView {
        let row = UIStackView()
        row.axis = preview.kind == .videoEmbed ? .vertical : .horizontal
        row.spacing = 8
        row.alignment = preview.kind == .videoEmbed ? .fill : .top

        let text = UIStackView()
        text.axis = .vertical
        text.spacing = 1

        if let site = preview.siteName {
            let byline = preview.author.map { "\(site) · \($0)" } ?? site
            text.addArrangedSubview(label(byline, font: .preferredFont(forTextStyle: .caption1),
                                          color: .secondaryLabel, lines: 1))
        }
        if let title = preview.title {
            text.addArrangedSubview(label(title, font: .preferredFont(forTextStyle: .subheadline),
                                          color: .label, lines: 2, weight: .semibold))
        }
        if let description = preview.description {
            text.addArrangedSubview(label(description, font: .preferredFont(forTextStyle: .footnote),
                                          color: .secondaryLabel, lines: 2))
        }

        if preview.kind == .videoEmbed, let path = preview.thumb {
            // A video reduced to a 64pt square is pointless, so the thumbnail is promoted to
            // full-width 16:9 with a play badge.
            row.addArrangedSubview(text)
            row.addArrangedSubview(videoThumb(path, model: model))
        } else {
            row.addArrangedSubview(text)
            if let path = preview.thumb {
                let thumb = UIImageView()
                thumb.contentMode = .scaleAspectFill
                thumb.clipsToBounds = true
                thumb.layer.cornerRadius = 4
                thumb.backgroundColor = .secondarySystemFill
                NSLayoutConstraint.activate([
                    thumb.widthAnchor.constraint(equalToConstant: Self.thumbSide),
                    thumb.heightAnchor.constraint(equalToConstant: Self.thumbSide),
                ])
                apply(path: path, to: thumb, model: model)
                row.addArrangedSubview(thumb)
            }
        }

        // The Slack signature: a thin rule down the left. Deliberately a neutral separator
        // colour rather than a per-site accent — extracting a dominant colour per domain is a
        // lot of machinery whose only effect is to make the timeline louder.
        let wrapper = UIView()
        let rule = UIView()
        rule.backgroundColor = .separator
        rule.layer.cornerRadius = 1.5
        rule.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(rule)
        wrapper.addSubview(row)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            rule.topAnchor.constraint(equalTo: wrapper.topAnchor),
            rule.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 3),
            row.leadingAnchor.constraint(equalTo: rule.trailingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -2),
        ])

        wrapper.isAccessibilityElement = true
        wrapper.accessibilityTraits = .link
        wrapper.accessibilityLabel = [preview.siteName, preview.title, preview.description]
            .compactMap { $0 }.joined(separator: ", ")
        attachTap(to: wrapper, opening: preview.url)
        return wrapper
    }

    /// The play facade for a video page.
    ///
    /// The thumbnail is proxied through our own server like every other preview image, so not
    /// even the *thumbnail* request reaches Google — which matters more than it sounds, since a
    /// channel with fifty YouTube links in scrollback would otherwise hand Google fifty
    /// impressions of you for videos you never watched.
    ///
    /// Tapping opens the URL, which on iOS means the YouTube app if it's installed and Safari
    /// otherwise. Deliberately NOT a `WKWebView` embed like the web client's iframe: a web view
    /// living inside a scrolling table cell is a memory problem and a worse experience, and
    /// the OS handoff is what an iOS user expects anyway.
    private func videoThumb(_ path: String, model: ChatViewModel) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemFill
        container.layer.cornerRadius = Self.corner
        container.clipsToBounds = true

        let thumb = UIImageView()
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(thumb)

        let badge = UIImageView(image: UIImage(systemName: "play.circle.fill"))
        badge.tintColor = .white
        badge.layer.shadowOpacity = 0.35
        badge.layer.shadowRadius = 6
        badge.layer.shadowOffset = .zero
        badge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badge)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalTo: container.widthAnchor, multiplier: 9.0 / 16.0),
            thumb.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            thumb.topAnchor.constraint(equalTo: container.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            badge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 48),
            badge.heightAnchor.constraint(equalToConstant: 48),
        ])
        apply(path: path, to: thumb, model: model)
        return container
    }

    // MARK: - Plumbing

    /// Put the image into the view as soon as it exists.
    ///
    /// Assigned DIRECTLY rather than by asking the table to reload the row, and that's the
    /// payoff for every attachment here having a height fixed by its metadata: an image
    /// arriving cannot change a row's height, so there is nothing to remeasure. The reload
    /// path this replaced was both unnecessary and unreliable — a load finishing while the row
    /// was off-screen, or mid-scroll, delivered to nothing.
    ///
    /// `[weak imageView]` is the reuse guard. `configure` rebuilds its subviews, so a recycled
    /// cell's old image views are already detached and deallocated by the time a stale
    /// callback fires — it finds nil and does nothing, instead of painting one row's image
    /// into another.
    private func apply(path: String, to imageView: UIImageView, model: ChatViewModel) {
        PreviewImageLoader.shared.load(path: path, using: model) { [weak imageView] image in
            imageView?.image = image
        }
    }

    private func label(
        _ text: String, font: UIFont, color: UIColor, lines: Int,
        weight: UIFont.Weight? = nil
    ) -> UILabel {
        let view = UILabel()
        view.text = text
        view.font = weight.map { font.withWeight($0) } ?? font
        view.textColor = color
        view.numberOfLines = lines
        view.adjustsFontForContentSizeCategory = true
        // Spoken via the container's own label instead; addressable here it'd be said twice.
        view.isAccessibilityElement = false
        return view
    }

    private func attachTap(to view: UIView, opening url: String) {
        guard let parsed = URL(string: url) else { return }
        let tap = TapOpening(url: parsed) { [weak self] target in self?.onOpen?(target) }
        view.addGestureRecognizer(tap.recognizer)
        // The recognizer holds no strong reference back to its target, so the box has to live
        // as long as the view does.
        objc_setAssociatedObject(view, &TapOpening.key, tap, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        view.isUserInteractionEnabled = true
    }
}

/// A tap recognizer plus the URL it opens, kept together so the pair can be associated with a
/// view and outlive the call that made it.
private final class TapOpening: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0

    let recognizer = UITapGestureRecognizer()
    private let url: URL
    private let action: (URL) -> Void

    init(url: URL, action: @escaping (URL) -> Void) {
        self.url = url
        self.action = action
        super.init()
        recognizer.addTarget(self, action: #selector(fire))
    }

    @objc private func fire() { action(url) }
}

extension UIFont {
    fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

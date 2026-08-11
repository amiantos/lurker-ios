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
    /// Bounds on a lone image's box, which is shaped by the server's dimensions rather than
    /// fixed — a portrait screenshot cropped into a landscape letterbox is unreadable.
    private static let loneMinHeight: CGFloat = 120
    private static let loneMaxHeight: CGFloat = 280
    private static let thumbSide: CGFloat = 64
    private static let corner: CGFloat = 8

    /// One mosaic row. Every group is a whole number of these, so a message's attachment block
    /// has a height known from the COUNT alone — nothing here reads an image's dimensions.
    private static let mosaicRowHeight: CGFloat = 160
    private static let mosaicGap: CGFloat = 4

    /// The band a hero card's picture sits in, as a constant.
    ///
    /// ⚠⚠ 1200/630 is a CONVENTION, and this is deliberately not computed from the declared
    /// pair. Those are numbers a stranger asserted about a file we have not measured; sizing the
    /// box from them puts row height at the mercy of someone else's markup, and measuring the
    /// bytes instead would make layout depend on the download. The declared shape only picks
    /// BETWEEN layouts, so a wrong pick is a letterboxed logo rather than a broken row.
    private static let heroAspect: CGFloat = 1200.0 / 630.0

    /// Below this ratio a card's picture takes the 64pt chip instead of the hero band.
    ///
    /// ⚠⚠ Measured against live markup, twice. reddit (256x256) and Ars Technica (512x512) are
    /// LOGOS and want the chip; Wikipedia (869x1200) is portrait and a hero band would crop its
    /// subject out; GitHub (1200x600) and most editorial sites want the band. The threshold sits
    /// just under 4:3, so a conventional photo is a hero and anything approaching square is not.
    ///
    /// ⚠⚠ HERO IS THE DEFAULT when nothing is declared — that population is mostly editorial.
    /// The cost is a letterboxed logo, which aspect-fit makes survivable.
    ///
    /// ⚠⚠ `twitter:card` is NOT consulted and must not be. It is stated INTENT and it disagrees
    /// with the author's own picture in exactly the direction that produces the bad crop: Ars
    /// Technica declares `summary_large_image` beside that 512x512 logo.
    private static let chipMaxRatio: CGFloat = 1.3

    /// Opens a URL. Held rather than hardcoded so a future in-app viewer is a wiring change.
    var onOpen: ((URL) -> Void)?

    /// Open the message's pictures full-screen, positioned on one of them.
    ///
    /// ⚠ The whole message's images, not the tapped one alone, and that is what makes the
    /// mosaic's cropping safe: a cell fills and clips so the group's height can come from the
    /// COUNT alone, and every one of those pictures is reachable uncropped from here.
    ///
    /// Nil on screens with nothing to present from — the highlights feed, the layout probes —
    /// where a tap falls back to opening the address.
    var onOpenGallery: (([LinkPreview], Int) -> Void)?

    /// Set per configure, so a tap knows what it belongs among.
    ///
    /// ⚠ Every DIRECT MEDIA item in the message, in the order it was posted — pictures, video
    /// and audio alike, not just the images the mosaic drew. They share a viewer because they
    /// share a question ("show me this properly"), and a message that mixes a screenshot and a
    /// clip should let the reader swipe between them rather than making the clip a different
    /// kind of thing.
    ///
    /// ⚠⚠ The admission test is `LinkPreview.isViewable`, which answers PER KIND because the two
    /// get their bytes from different places now. It lives on the model rather than here: it is
    /// a fact about a preview, not about this view, and the app target has no test bundle — in
    /// LurkerKit it can be asserted, and the regression it guards against was invisible without
    /// a test (no crash, no error, just a feature that stopped being reachable).
    private var galleryImages: [LinkPreview] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 6
        alignment = .fill
        // Margins are set by the cell, which knows the body's indent for the current Dynamic
        // Type size — see CompactCell.showAttachments.
        isLayoutMarginsRelativeArrangement = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not from a nib") }

    /// Release every attachment view. Called for EVERY row, so a recycled cell doesn't keep the
    /// previous message's decoded images alive for its whole lifetime.
    func clear() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        isHidden = true
    }

    /// Draw the previews for one message. Passing an empty array collapses the view entirely,
    /// which is the common case and has to stay cheap — most messages have no links.
    func configure(previews: [LinkPreview], model: ChatViewModel) {
        clear()
        isHidden = previews.isEmpty
        guard !previews.isEmpty else { return }

        // ⚠ IMAGES only. A player cropped into a grid cell is not a player — its controls are
        // the part that gets cut — so video and audio stack full width, where their transport
        // has room. That is what audio has always done here.
        let images = previews.filter { $0.kind == .image }
        galleryImages = previews.filter(\.isViewable)
        if images.count > 1 {
            addArrangedSubview(mosaic(images, model: model))
        }

        let inMosaic = images.count > 1 ? Set(images.map(\.url)) : []
        for preview in previews where !inMosaic.contains(preview.url) {
            switch preview.kind {
            case .image, .video, .audio:
                addArrangedSubview(mediaView(preview, model: model))
            case .page, .videoEmbed:
                addArrangedSubview(cardView(preview, model: model))
            }
        }
    }


    /// A height an attachment ASKS for, one notch below required.
    ///
    /// ⚠⚠ Never required, and this is a rule about what may be lost rather than a layout tweak.
    /// A message's text resists vertical compression at 750 by default; a required height here
    /// outranks it, so any pass that gives the cell less room than its content wants collapses
    /// the SENTENCE and leaves the picture untouched — a message silently missing its last
    /// lines, which is what happened. At 999 the decoration yields first. A slightly short
    /// image is recoverable by looking at it; a lost line of what somebody said is not.
    private static func yielding(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        constraint.priority = UILayoutPriority(999)
        return constraint
    }

    // MARK: - The mosaic

    /// Two or more images as a two-column grid.
    ///
    /// ⚠⚠ This replaced a horizontally-scrolling filmstrip, and the reason is the interaction
    /// rather than the look: a sideways scroller inside a vertically-scrolling table is a
    /// gesture conflict, a diagonal drag has to be arbitrated, and whichever way it goes is the
    /// way the reader didn't mean. It also hid content behind a measured fade — two of the
    /// nastiest bugs in this whole port lived in that measurement.
    ///
    /// It keeps the property the strip existed for: **nothing here reads an image's
    /// dimensions**, so the grid is laid out correctly before a single byte arrives, and the
    /// block's height is a function of the COUNT alone. Cropping is what buys that.
    ///
    /// The shape rule, for any count: **even → all pairs; odd → the three-up block first, then
    /// pairs.** So 3 is a full-height picture beside two stacked, 4 is 2x2, 5 is the three-up
    /// plus a pair, 7 is the three-up plus two pairs. One rule, no holes at any count, and the
    /// odd block LEADS — a trailing full-width tile crops a landscape photo hard and makes the
    /// last picture the subject of the message.
    ///
    /// ⚠⚠ Uncapped, with no `+N` badge. The cap's only justification was that one message must
    /// not take over the screen, and `PreviewSelection.maxMediaPerMessage` already bounds that.
    /// A badge would have been a promise: on the web any tile opens a lightbox over every image,
    /// and iOS has no media viewer — a tap opens Safari — so `+N` would advertise pictures
    /// nothing could reach.
    private func mosaic(_ images: [LinkPreview], model: ChatViewModel) -> UIView {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = Self.mosaicGap
        column.alignment = .fill

        var index = 0
        if images.count.isMultiple(of: 2) == false, images.count >= 3 {
            column.addArrangedSubview(
                threeUpBlock(images[0], images[1], images[2], model: model))
            index = 3
        }
        // Whatever the three-up block didn't take is even by construction.
        while index + 1 < images.count {
            column.addArrangedSubview(pairRow(images[index], images[index + 1], model: model))
            index += 2
        }
        return column
    }

    /// A full-height picture beside two stacked ones — Discord's arrangement for three.
    ///
    /// It is what gives an odd count a shape rather than a gap: a 2x2 grid with three items
    /// leaves a hole, and stretching the third across the bottom makes it the subject.
    private func threeUpBlock(
        _ tall: LinkPreview, _ top: LinkPreview, _ bottom: LinkPreview, model: ChatViewModel
    ) -> UIView {
        let stacked = UIStackView(arrangedSubviews: [
            tile(top, model: model), tile(bottom, model: model),
        ])
        stacked.axis = .vertical
        stacked.spacing = Self.mosaicGap
        stacked.distribution = .fillEqually

        let row = UIStackView(arrangedSubviews: [tile(tall, model: model), stacked])
        row.axis = .horizontal
        row.spacing = Self.mosaicGap
        row.distribution = .fillEqually
        Self.yielding(
            row.heightAnchor.constraint(
                equalToConstant: Self.mosaicRowHeight * 2 + Self.mosaicGap)
        ).isActive = true
        return row
    }

    private func pairRow(_ left: LinkPreview, _ right: LinkPreview, model: ChatViewModel) -> UIView {
        let row = UIStackView(arrangedSubviews: [
            tile(left, model: model), tile(right, model: model),
        ])
        row.axis = .horizontal
        row.spacing = Self.mosaicGap
        row.distribution = .fillEqually
        Self.yielding(row.heightAnchor.constraint(equalToConstant: Self.mosaicRowHeight))
            .isActive = true
        return row
    }

    /// One cell of the grid. Fills and crops, because every cell is the same size whatever the
    /// picture is — which is the whole source of the block's byte-independence.
    private func tile(_ preview: LinkPreview, model: ChatViewModel) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemFill
        container.layer.cornerRadius = Self.corner
        container.clipsToBounds = true

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
        container.isAccessibilityElement = true
        container.accessibilityTraits = .button
        container.accessibilityLabel = "Image"
        if let path = preview.src {
            apply(path: path, to: imageView, model: model)
            attachPlayback(
                to: container, imageView: imageView, path: path, url: preview.url, model: model)
        } else {
            attachTap(to: container, opening: preview.url)
        }
        return container
    }

    // MARK: - Direct media

    /// No card, no chrome — just the thing. A frame around an image is furniture around
    /// content.
    private func mediaView(_ preview: LinkPreview, model: ChatViewModel) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemFill
        container.layer.cornerRadius = Self.corner
        container.clipsToBounds = true

        // The picture this box draws — `src` for an image, the decoded POSTER for a clip. The
        // rule lives on the model, with the tests, for the same reason `isViewable` does: it is
        // a predicate whose failure is a thing that silently never appears. See `inlinePicture`.
        let picture = preview.inlinePicture

        // ⚠⚠ A box before the bytes, always. The height comes from the server's dimensions or
        // from a fixed fallback — never from the image, which would mean every picture growing
        // its row at decode time, under the reader's thumb. A lone image is shaped rather than
        // fixed because it is the one case where a flat height is actively wrong: a portrait
        // screenshot cropped into a landscape letterbox is unreadable, and unlike a mosaic tile
        // there is no sibling making the crop legible as a deliberate arrangement.
        //
        // ⚠ A POSTER is shaped by the same rule, and the case for it is stronger: for these rows
        // the declared pair describes the frame we decoded rather than something a stranger's
        // markup asserted, and phone video is overwhelmingly portrait — the population a flat
        // landscape box crops worst. A clip with NO poster keeps the fixed height: there is no
        // picture whose shape could be honoured.
        if preview.kind == .image || picture != nil, let width = preview.thumbWidth,
            let height = preview.thumbHeight, width > 0, height > 0
        {
            let ratio = CGFloat(width) / CGFloat(height)
            let shaped = container.heightAnchor.constraint(
                equalTo: container.widthAnchor, multiplier: 1 / ratio)
            // Below required, so the bounds below win rather than fighting it.
            shaped.priority = .defaultHigh
            NSLayoutConstraint.activate([
                shaped,
                Self.yielding(
                    container.heightAnchor.constraint(
                        greaterThanOrEqualToConstant: Self.loneMinHeight)),
                Self.yielding(
                    container.heightAnchor.constraint(
                        lessThanOrEqualToConstant: Self.loneMaxHeight)),
            ])
        } else {
            Self.yielding(container.heightAnchor.constraint(equalToConstant: Self.mediaHeight))
                .isActive = true
        }

        // Set when this is an image with bytes, so the tap can offer playback if it animates.
        var animatablePath: String?

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

        // ⚠ Per KIND, with no default. `kind == .video ? play : waveform` was fine while only
        // clips reached the glyph; once an image can too — a stored descriptor with no `src`,
        // which this file is otherwise careful about — a default puts the WRONG symbol on the
        // odd one out. A still we can't draw is a missing picture, not something to press play
        // on, and a play button over it advertises a viewer that `isViewable` will refuse.
        let symbol: String
        switch preview.kind {
        case .video: symbol = "play.circle.fill"
        case .audio: symbol = "waveform"
        case .image, .page, .videoEmbed: symbol = "photo"
        }
        if preview.kind == .image, let path = picture {
            apply(path: path, to: imageView, model: model)
            animatablePath = path
        } else {
            // A glyph that says what this is. WHAT IT ENDS UP SITTING ON decides how it looks:
            // over a poster it is paint on a picture and needs the white-and-shadow treatment
            // every other overlay badge uses, and on an empty box it wants the muted, unemphatic
            // tint of a placeholder. A secondary-label symbol over a photograph reads as neither.
            //
            // ⚠⚠ It starts muted and is promoted WHEN THE BYTES LAND, not when the descriptor
            // merely promises them. A poster is the one preview image with no origin to re-fetch
            // from, so `thumb` can point at an evicted cache entry and 404 — the server calls a
            // posterless render a supported state — and styling from the promise painted white
            // glyph on pale grey, in light mode, permanently. Free of layout consequence for the
            // same reason `attachPlayback`'s badge is: the box was sized from the descriptor and
            // a badge is paint over it.
            let glyph = UIImageView(image: UIImage(systemName: symbol))
            glyph.tintColor = .secondaryLabel
            glyph.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                glyph.widthAnchor.constraint(equalToConstant: 44),
                glyph.heightAnchor.constraint(equalToConstant: 44),
            ])
            if let path = picture {
                apply(path: path, to: imageView, model: model) { [weak glyph] in
                    guard let glyph else { return }
                    Self.styleAsOverlay(glyph)
                }
            }
        }

        container.isAccessibilityElement = true
        container.accessibilityTraits = .button
        // ⚠ On the CONTAINER, which is the accessibility element — a label on the image view
        // inside it is swallowed whole, and an inline image was announced as an unnamed "button"
        // for exactly that reason. `attachPlayback` upgrades this to "Animation" if the bytes
        // turn out to move.
        switch preview.kind {
        case .video: container.accessibilityLabel = "Video"
        case .audio: container.accessibilityLabel = "Audio"
        case .image, .page, .videoEmbed: container.accessibilityLabel = "Image"
        }
        if let animatablePath {
            attachPlayback(
                to: container, imageView: imageView, path: animatablePath, url: preview.url,
                model: model)
        } else {
            // Video and audio: the viewer plays them. This is the case that was a hand-off to
            // Safari, and the objection to inline playback never applied to it — one AVPlayer in
            // a screen the reader deliberately opened is not one per row.
            attachGalleryTap(to: container, url: preview.url)
        }
        return container
    }

    // MARK: - Cards

    /// Which shape a card's picture takes — or that it has none.
    ///
    /// See `chipMaxRatio` for the measurements and for why `twitter:card` is not consulted.
    private enum CardShape {
        case none
        case chip
        case hero
    }

    private static func shape(for preview: LinkPreview) -> CardShape {
        guard preview.thumb != nil else { return .none }
        guard let width = preview.thumbWidth, let height = preview.thumbHeight,
            width > 0, height > 0
        else { return .hero }
        return CGFloat(width) / CGFloat(height) < chipMaxRatio ? .chip : .hero
    }

    private func cardView(_ preview: LinkPreview, model: ChatViewModel) -> UIView {
        let shape = Self.shape(for: preview)
        // A hero band and a video facade both put the picture UNDER the text, full width; a chip
        // sits beside it. That is the whole structural difference between the two cards.
        let stacksVertically = preview.kind == .videoEmbed || shape == .hero

        let row = UIStackView()
        row.axis = stacksVertically ? .vertical : .horizontal
        row.spacing = 8
        row.alignment = stacksVertically ? .fill : .top

        let text = UIStackView()
        text.axis = .vertical
        // Line-to-line air. At 1 the byline, title and description read as one dense block —
        // three different things at three different weights, with nothing between them saying so.
        text.spacing = 4
        // ⚠ Trailing inset on the TEXT, not on its row. A hero band is text's sibling here, and
        // insetting the row would pull the picture off the card's edge with it — the web keeps
        // the hero flush to both edges deliberately and narrows the CARD instead. So the words
        // get the margin and the picture keeps the full width.
        text.isLayoutMarginsRelativeArrangement = true
        text.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: 0, bottom: 0, trailing: 8)

        if let site = preview.siteName {
            let byline = preview.author.map { "\(site) · \($0)" } ?? site
            text.addArrangedSubview(label(byline, font: .preferredFont(forTextStyle: .caption1),
                                          color: .secondaryLabel, lines: 1))
        }
        // ⚠⚠ The heading falls back title → siteName → hostname, and the fallback is
        // load-bearing rather than defensive. The server returns `ok` on a title OR an image, so
        // titleless cards are ordinary — an og:image with no og:title, a description-only page,
        // the deliberately-degraded video record. Gating on `title` rendered each of them with
        // no anchor at all: a preview that goes nowhere and reads to VoiceOver as an empty box.
        // `siteName` is the right rung because the server guarantees it
        // (providerName || og:site_name || hostname).
        if let heading = preview.title ?? preview.siteName ?? URL(string: preview.url)?.host {
            text.addArrangedSubview(label(heading, font: .preferredFont(forTextStyle: .subheadline),
                                          color: .label, lines: 2, weight: .semibold))
        }
        if let description = preview.description {
            text.addArrangedSubview(label(description, font: .preferredFont(forTextStyle: .footnote),
                                          color: .secondaryLabel, lines: 3))
        }

        row.addArrangedSubview(text)
        if preview.kind == .videoEmbed, let path = preview.thumb {
            // A video reduced to a 64pt square is pointless, so the thumbnail is promoted to
            // full-width 16:9 with a play badge.
            row.addArrangedSubview(videoThumb(path, model: model))
        } else if let path = preview.thumb {
            switch shape {
            case .hero:
                row.addArrangedSubview(heroBand(path, model: model))
            case .chip:
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
            case .none:
                break
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
            row.leadingAnchor.constraint(equalTo: rule.trailingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            // The rule runs the full height of the card, so this is the gap between it and the
            // first line rather than the card's outer padding — at 2 the text sat hard against
            // the top of its own accent.
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -6),
        ])

        wrapper.isAccessibilityElement = true
        wrapper.accessibilityTraits = .link
        wrapper.accessibilityLabel = [preview.siteName, preview.title, preview.description]
            .compactMap { $0 }.joined(separator: ", ")
        attachTap(to: wrapper, opening: preview.url)
        return wrapper
    }

    /// A card's picture as a full-width band under its text — Discord's large embed.
    ///
    /// ⚠ Aspect FIT, not fill. 1200x630 is a convention rather than a rule, so a 4:3 or a square
    /// picture routinely lands in this box; filling would crop the subject out of exactly the
    /// images whose declared shape put them here by default. Letterboxing a logo is the cost of
    /// the hero being the default, and it was taken knowingly.
    private func heroBand(_ path: String, model: ChatViewModel) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemFill
        container.layer.cornerRadius = Self.corner
        container.clipsToBounds = true

        let image = UIImageView()
        image.contentMode = .scaleAspectFit
        image.clipsToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(image)
        NSLayoutConstraint.activate([
            Self.yielding(
                container.heightAnchor.constraint(
                    equalTo: container.widthAnchor, multiplier: 1 / Self.heroAspect)),
            image.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            image.topAnchor.constraint(equalTo: container.topAnchor),
            image.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        apply(path: path, to: image, model: model)
        return container
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

        let badge = Self.overlayBadge("play.circle.fill")
        container.addSubview(badge)

        NSLayoutConstraint.activate([
            Self.yielding(
                container.heightAnchor.constraint(
                    equalTo: container.widthAnchor, multiplier: 9.0 / 16.0)),
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

    /// A glyph meant to sit ON a picture rather than in an empty box.
    ///
    /// The caller owns the size and the constraints; the badge is never a control (the whole tile
    /// is), so it carries no traits of its own.
    private static func overlayBadge(_ symbol: String) -> UIImageView {
        let badge = UIImageView(image: UIImage(systemName: symbol))
        badge.translatesAutoresizingMaskIntoConstraints = false
        styleAsOverlay(badge)
        return badge
    }

    /// White with a soft shadow rather than a tinted symbol, because a glyph on top of a picture
    /// has to stay legible over whatever frame is underneath — a snow scene and a night shot
    /// both. Applied separately from construction so a glyph that only MIGHT get a picture can
    /// wait until the bytes actually land before it takes the treatment.
    private static func styleAsOverlay(_ badge: UIImageView) {
        badge.tintColor = .white
        badge.layer.shadowOpacity = 0.35
        badge.layer.shadowRadius = 6
        badge.layer.shadowOffset = .zero
    }

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
    /// `onArrival` runs only when bytes were decoded — the loader is silent on a failure — so it
    /// is the hook for anything that must not be done on a descriptor's promise alone.
    private func apply(
        path: String, to imageView: UIImageView, model: ChatViewModel,
        onArrival: (() -> Void)? = nil
    ) {
        PreviewImageLoader.shared.load(path: path, using: model) { [weak imageView] image in
            imageView?.image = image
            onArrival?()
        }
    }

    // MARK: - Animations play on request

    /// Put a play badge on an animated image, and make the tap start it rather than leave.
    ///
    /// ⚠⚠ Deliberately NOT autoplay, which is what "support GIFs" usually means. A page of
    /// scrollback with a dozen animations is a dozen full frame-sets decoded and a dozen
    /// timers running whether or not anybody is watching one — the memory and the battery both
    /// go, and the list becomes visually noisy in a way a log should not be. Opt-in costs one
    /// tap and gives the reader the choice.
    ///
    /// ⚠ The badge cannot be decided up front: whether a file animates is known only once its
    /// bytes have been decoded, and `image/webp` says nothing either way. So it appears when
    /// the still arrives. That is free of layout consequence — the box was already sized from
    /// the metadata, and a badge is paint over it.
    ///
    /// ⚠ Playback stops when the cell is recycled, and that is wanted rather than tolerated:
    /// the frames are released with it, so scrolling away from an animation reclaims its
    /// memory. Unlike a revealed spoiler, nobody expects a GIF to still be running when they
    /// scroll back to it.
    private func attachPlayback(
        to container: UIView, imageView: UIImageView, path: String, url: String,
        model: ChatViewModel
    ) {
        let badge = Self.overlayBadge("play.circle.fill")
        badge.isHidden = true
        container.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 40),
            badge.heightAnchor.constraint(equalToConstant: 40),
        ])

        // ⚠ The badge says "this moves", nothing more. Whether a file animates is known only
        // once its bytes are decoded — `image/webp` says nothing either way — so it appears when
        // the still lands, which costs no layout: the box was sized from the descriptor and a
        // badge is paint over it.
        PreviewImageLoader.shared.load(path: path, using: model) { [weak badge, weak container] _ in
            let animated = PreviewImageLoader.shared.isAnimated(path)
            badge?.isHidden = !animated
            if animated { container?.accessibilityLabel = "Animation" }
        }

        // ⚠⚠ Playing INLINE was tried and abandoned: a mosaic tile is 160pt and cropped, and a
        // lone image is capped in a phone-width column, so a GIF played in place ran inside a
        // box smaller than itself. Tapping opens the viewer instead, where it plays at its own
        // size — which is also where a cropped tile becomes recoverable and where the other
        // pictures in the message are reachable. One gesture, one meaning.
        attachGalleryTap(to: container, url: url)
    }

    /// Tap → the viewer, positioned on this picture; or the address, if nothing can present.
    private func attachGalleryTap(to view: UIView, url: String) {
        let tap = TapPlaying(url: url) { [weak self] in
            guard let self else { return }
            if let onOpenGallery, let at = galleryImages.firstIndex(where: { $0.url == url }) {
                onOpenGallery(galleryImages, at)
                return
            }
            if let parsed = URL(string: url) { onOpen?(parsed) }
        }
        view.addGestureRecognizer(tap.recognizer)
        objc_setAssociatedObject(view, &TapOpening.key, tap, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        view.isUserInteractionEnabled = true
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

/// A tap that decides what it means when it fires, for an image that may turn out to animate.
private final class TapPlaying: NSObject {
    let recognizer = UITapGestureRecognizer()
    private let url: String
    private let action: () -> Void

    init(url: String, action: @escaping () -> Void) {
        self.url = url
        self.action = action
        super.init()
        recognizer.addTarget(self, action: #selector(fire))
    }

    @objc private func fire() { action() }
}

extension UIFont {
    fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

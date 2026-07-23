// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// A cell that keeps its timestamp parked off the right edge until the list is dragged
/// left, the way Messages does it.
///
/// The time is worth almost nothing almost all of the time — you want it for one message,
/// occasionally — so it costs nothing at rest and is a drag away when it doesn't.
protocol TimestampRevealing: UITableViewCell {
    /// Slide the timestamp in by `offset` points. 0 parks it back off-screen.
    func setReveal(_ offset: CGFloat)
}

enum TimestampReveal {
    /// How far the list slides. Enough to clear a `10:00 PM`, and no further — this is a
    /// peek, not a second column.
    static let maxOffset: CGFloat = 76
}

/// A message rendered as a chat bubble: our own tinted and trailing, everyone else's
/// filled and leading.
///
/// A run of messages is captioned once, by the nick above its first bubble — and not at
/// all when the run is ours, where the side and the tint already say who sent it. Bubbles
/// encode a two-party "me vs them" axis, and IRC has neither two parties nor avatars to
/// lean on, so captioning every line would roughly double the list's height to say the
/// same thing.
final class BubbleCell: UITableViewCell, TimestampRevealing {
    static let reuseID = "bubble"

    private let column = UIStackView()
    private let nickLabel = UILabel()
    private let bubble = UIView()
    private let messageText = UITextView()
    private let revealTime = UILabel()

    private var columnTop: NSLayoutConstraint!
    private var columnBottom: NSLayoutConstraint!
    /// Whether this run gives way to the timestamp — see `setReveal`.
    private var slidesAside = false

    /// How much of the width a bubble may take before wrapping. The rest is the gutter
    /// that makes the leading/trailing axis legible at a glance.
    private static let maxWidthFraction: CGFloat = 0.78
    private static let wideRadius: CGFloat = 18
    /// The radius on the run-facing side of a bubble that has a neighbor. Not zero —
    /// square corners read as a rendering bug rather than as grouping.
    private static let tightRadius: CGFloat = 5

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        // Parks the timestamp: it's laid out past the trailing edge and only exists on
        // screen once the drag pulls it in.
        contentView.clipsToBounds = true

        nickLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
        nickLabel.adjustsFontForContentSizeCategory = true
        nickLabel.lineBreakMode = .byTruncatingTail
        // The nick is spoken as part of the message's own label, which is the one that has
        // to exist — it's also where the timestamp goes, since VoiceOver has no drag to
        // make. Left addressable, it would be announced twice.
        nickLabel.isAccessibilityElement = false

        // One font size app-wide; it recedes on color, the same way `MessageRenderer`
        // stamps full-width lines.
        revealTime.font = .preferredFont(forTextStyle: .subheadline)
        revealTime.textColor = .tertiaryLabel
        revealTime.adjustsFontForContentSizeCategory = true
        revealTime.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(revealTime)

        messageText.isEditable = false
        messageText.isScrollEnabled = false
        messageText.isSelectable = true // required for tappable links (also enables copy)
        messageText.backgroundColor = .clear
        messageText.textContainerInset = UIEdgeInsets(top: 7, left: 11, bottom: 7, right: 11)
        messageText.textContainer.lineFragmentPadding = 0
        // Let the bubble's max-width constraint win and force a wrap, instead of the text
        // view insisting on its one-line intrinsic width.
        messageText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageText.translatesAutoresizingMaskIntoConstraints = false

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(messageText)

        column.axis = .vertical
        // The nick needs air under it — set tight against its bubble it reads as part of
        // the message rather than a label for the run.
        column.spacing = 6
        column.addArrangedSubview(nickLabel)
        column.addArrangedSubview(bubble)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)

        let margins = contentView.layoutMarginsGuide
        columnTop = column.topAnchor.constraint(equalTo: contentView.topAnchor)
        columnBottom = column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        NSLayoutConstraint.activate([
            messageText.topAnchor.constraint(equalTo: bubble.topAnchor),
            messageText.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            messageText.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            messageText.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),

            bubble.widthAnchor.constraint(
                lessThanOrEqualTo: contentView.widthAnchor, multiplier: Self.maxWidthFraction
            ),

            // Just past the trailing edge, so it's invisible until dragged in, and level
            // with the bubble it belongs to rather than the row.
            revealTime.leadingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 12),
            revealTime.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),

            columnTop,
            columnBottom,
            column.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// `networkName` captions the lines that have no nick — a system line names the network
    /// it's about, server text names the server it came from.
    ///
    /// `showsHighlight` gates the warm matched-line wash. On by default for the message list,
    /// where the wash marks the one highlighted line among many. A results list (recent
    /// highlights, later search/bookmarks) turns it off: there every row matched, so the wash
    /// is a monotone wall that only erases the side/fill distinction — the screen title
    /// already says they're all highlights.
    func configure(
        _ message: Message, position: RunPosition, networkName: String? = nil,
        highlighter: NickHighlighter? = nil, showsHighlight: Bool = true
    ) {
        let isSelf = message.isSelf
        column.alignment = isSelf ? .trailing : .leading
        slidesAside = isSelf

        // Our own runs need no nick — the side and the tint already say who sent it. Runs
        // break on type, so a caption covers the whole run.
        let caption = MessageRenderer.caption(message, networkName: networkName)
        nickLabel.isHidden = isSelf || !position.isFirst || caption == nil
        nickLabel.text = caption
        nickLabel.textColor = MessageRenderer.captionColor(message, networkName: networkName)
        // Per message, not per run: once you've gone looking for a time, you want the one
        // for the line you're looking at.
        revealTime.text = MessageRenderer.timestamp(message.date)

        // A matched line wins the fill regardless of side: the warm wash is the whole point,
        // and a highlight in your own message (a rule firing on something you said) is worth
        // the same mark as one in someone else's. Mirrors the web, which tints `.line.highlight`
        // without regard to author.
        bubble.backgroundColor = (showsHighlight && message.matched)
            ? Palette.highlightBubble
            : (isSelf ? Palette.outgoingBubble : Palette.incomingBubble)
        bubble.cornerConfiguration = Self.corners(isSelf: isSelf, position: position)
        messageText.attributedText = MessageRenderer.renderBubble(message, highlighter: highlighter)
        // A link is body-colored with a soft underline — matching the web client, whose
        // `--link` defaults to the foreground with a 40%-opacity underline. The accent was
        // wrong for this: it's the app's voice (send button, own-nick), not the sender's,
        // and a pink link inside someone's message read as ours.
        messageText.linkTextAttributes = [
            .foregroundColor: UIColor.label,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: UIColor.label.withAlphaComponent(0.4),
        ]

        // Open a gap around a run and hold the messages inside one tight together, so a run
        // reads as a block with space either side rather than as part of the next one.
        columnTop.constant = position.isFirst ? 8 : 1
        columnBottom.constant = position.isLast ? -6 : -1

        isAccessibilityElement = false
        // VoiceOver has no drag to make, so the time goes in the label rather than behind a
        // gesture it can't perform.
        messageText.accessibilityLabel = [caption, message.text, revealTime.text]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// Only our own runs give way.
    ///
    /// They sit against the trailing margin — exactly where the timestamp is arriving — so
    /// they have to move. Everyone else's already have that gutter free: their bubbles are
    /// capped well short of it, so the timestamp slides into empty space. Sliding them
    /// anyway would push their text and nick straight off the *leading* edge, since they're
    /// flush against it.
    func setReveal(_ offset: CGFloat) {
        column.transform = CGAffineTransform(translationX: slidesAside ? -offset : 0, y: 0)
        revealTime.transform = CGAffineTransform(translationX: -offset, y: 0)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // A cell recycled mid-drag would otherwise come back still slid over.
        setReveal(0)
        // Cancel an in-flight jump flash (#42) and clear its wash, so a cell recycled mid-pulse
        // doesn't carry the warm background onto an unrelated message.
        contentView.layer.removeAllAnimations()
        contentView.backgroundColor = .clear
    }

    /// Round the outside of a run and tighten the side it's stacked along, so a run reads
    /// as one block. `cornerConfiguration` is iOS 26's — the deployment target is 26.0, so
    /// there's no fallback path to keep.
    private static func corners(isSelf: Bool, position: RunPosition) -> UICornerConfiguration {
        let top: CGFloat = position.isFirst ? wideRadius : tightRadius
        let bottom: CGFloat = position.isLast ? wideRadius : tightRadius
        return .corners(
            topLeftRadius: .fixed(isSelf ? wideRadius : top),
            topRightRadius: .fixed(isSelf ? top : wideRadius),
            bottomLeftRadius: .fixed(isSelf ? wideRadius : bottom),
            bottomRightRadius: .fixed(isSelf ? bottom : wideRadius)
        )
    }
}

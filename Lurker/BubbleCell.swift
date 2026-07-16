// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// A message rendered as a chat bubble: our own tinted and trailing, everyone else's
/// filled and leading.
///
/// The nick label and timestamp are per-*run*, not per-message — the nick shows once at
/// the top of a run and the time once at the bottom. That's what keeps a channel readable:
/// bubbles encode a two-party "me vs them" axis, and IRC has neither two parties nor
/// avatars to lean on, so without runs every line would need its own nick header and the
/// list would roughly double in height to say the same thing.
final class BubbleCell: UITableViewCell {
    static let reuseID = "bubble"

    private let column = UIStackView()
    private let nickLabel = UILabel()
    private let bubble = UIView()
    private let messageText = UITextView()
    private let timeLabel = UILabel()

    private var bubbleTop: NSLayoutConstraint!

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

        nickLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
        nickLabel.adjustsFontForContentSizeCategory = true

        timeLabel.font = .preferredFont(forTextStyle: .caption2)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.adjustsFontForContentSizeCategory = true

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
        column.spacing = 2
        column.addArrangedSubview(nickLabel)
        column.addArrangedSubview(bubble)
        column.addArrangedSubview(timeLabel)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)

        let margins = contentView.layoutMarginsGuide
        bubbleTop = column.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            messageText.topAnchor.constraint(equalTo: bubble.topAnchor),
            messageText.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            messageText.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            messageText.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),

            bubble.widthAnchor.constraint(
                lessThanOrEqualTo: contentView.widthAnchor, multiplier: Self.maxWidthFraction
            ),

            bubbleTop,
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
            column.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    func configure(_ message: Message, position: RunPosition) {
        let isSelf = message.isSelf
        column.alignment = isSelf ? .trailing : .leading

        // Our own bubble needs no nick — the side and the tint already say who sent it.
        let showsNick = position.isFirst && !isSelf
        nickLabel.isHidden = !showsNick
        nickLabel.text = message.nick
        nickLabel.textColor = MessageRenderer.nickColor(message)

        timeLabel.isHidden = !position.isLast
        timeLabel.text = MessageRenderer.timestamp(message.date)

        bubble.backgroundColor = isSelf ? Palette.outgoingBubble : Palette.incomingBubble
        bubble.cornerConfiguration = Self.corners(isSelf: isSelf, position: position)
        messageText.attributedText = MessageRenderer.renderBubble(message)
        // On a tinted bubble the default link color is close to the fill; white keeps it
        // readable, and the underline still marks it as a link.
        messageText.linkTextAttributes = [
            .foregroundColor: isSelf ? UIColor.white : UIColor.tintColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        // Open a gap before a new run, and hold the messages inside one tight together.
        bubbleTop.constant = position.isFirst ? 8 : 1

        isAccessibilityElement = false
        messageText.accessibilityLabel = [message.nick, message.text]
            .compactMap { $0 }
            .joined(separator: ", ")
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

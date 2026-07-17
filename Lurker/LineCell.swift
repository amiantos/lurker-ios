// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// A full-width line, for the events that aren't dialogue: `/me` actions, notices, and the
/// system buffer's own output. These carry their own inline prefix ("* nick waves",
/// "-nick-", a network name) and read as narration about the room rather than speech in
/// it, so they stay lines while messages become bubbles.
///
/// Backed by a `UITextView` rather than a label so auto-linked URLs are actually tappable
/// (a `UILabel` ignores `.link` interaction) and text is selectable to copy. Non-editable
/// and non-scrolling so it behaves like a self-sizing label.
final class LineCell: UITableViewCell {
    static let reuseID = "line"

    private let messageText = UITextView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        messageText.isEditable = false
        messageText.isScrollEnabled = false
        messageText.isSelectable = true // required for tappable links (also enables copy)
        messageText.backgroundColor = .clear
        messageText.textColor = .label // dynamic fallback for any run without an explicit color
        messageText.textContainerInset = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        messageText.textContainer.lineFragmentPadding = 0
        messageText.linkTextAttributes = [
            .foregroundColor: UIColor.tintColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        messageText.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(messageText)
        NSLayoutConstraint.activate([
            messageText.topAnchor.constraint(equalTo: contentView.topAnchor),
            messageText.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            messageText.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            messageText.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    func configure(_ attributed: NSAttributedString) {
        messageText.attributedText = attributed
    }
}

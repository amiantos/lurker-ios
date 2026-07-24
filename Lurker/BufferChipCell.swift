// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// A capsule pill showing the unread count, tinted red when the buffer holds a highlight.
///
/// Shared by the roster list rows (as a trailing accessory) and the grid chips (as a laid-out
/// subview), so the same signal is the same shape in both places. It sizes itself from its
/// text — `intrinsicContentSize` pads the count and forces a minimum square so a single digit
/// still reads as a pill, and `layoutSubviews` rounds to a capsule at whatever height it ends
/// up — which is what lets it drop into an Auto Layout stack and a UIKit accessory slot alike.
func makeUnreadBadge(unread: Int, highlights: Int) -> UILabel? {
    guard unread > 0 else { return nil }
    let label = BufferBadgeLabel()
    label.text = "\(unread)"
    label.font = .preferredFont(forTextStyle: .caption1)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .white
    // A highlight is the loud red; an ordinary unread is a neutral gray. `.systemGray` reads
    // too light under white text, and it's already the darkest of the systemGray family, so
    // this is a purpose-built gray: dark enough for white either way, a shade lighter in dark
    // mode so it still lifts off the near-black cell rather than sinking into it.
    let neutral = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.42, alpha: 1)
            : UIColor(white: 0.36, alpha: 1)
    }
    label.backgroundColor = highlights > 0 ? .systemRed : neutral
    label.textAlignment = .center
    return label
}

/// A count label that draws itself as a capsule. Padding comes from `intrinsicContentSize`
/// widening past the text (the centered text then floats in the middle), not from insetting
/// `drawText`, which clips under Dynamic Type.
final class BufferBadgeLabel: UILabel {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.masksToBounds = true
    }

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        let height = base.height + 4
        return CGSize(width: max(base.width + 12, height), height: height)
    }

    // `UICellAccessory.customView` sizes its view with `sizeThatFits`, and `UILabel`'s default
    // returns the *tight* text size — ignoring the padding above, which lives only in
    // `intrinsicContentSize`. Without this the accessory pill collapses to the digit while the
    // Auto-Layout-sized chip pill (which reads `intrinsicContentSize`) stays padded. Agreeing
    // the two keeps the capsule identical wherever it's placed.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }
}

/// A buffer as a compact card, for the Favorites and Recent grids.
///
/// The grids are shortcuts, not the roster — a place to fit twice as many of the handful you
/// keep coming back to into the same vertical space, two across. So this is denser than a list
/// row and it looks like a card rather than a row: a filled, rounded tile that reads as "tap
/// target" at a glance, distinct from the grouped rows below it that carry swipe actions.
///
/// Density is layout, not type size — one font size app-wide. The name is weight, the network
/// is color, and the pill is the same one the rows use.
final class BufferChipCell: UICollectionViewCell {
    private let card = UIView()
    private let nameLabel = UILabel()
    private let networkLabel = UILabel()
    private let badgeContainer = UIView()
    /// A small presence dot, shown only on friend chips (nil presence hides it and collapses
    /// its slot, so ordinary Favorites/Recent chips are unchanged).
    private let presenceDot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        presenceDot.translatesAutoresizingMaskIntoConstraints = false
        presenceDot.layer.cornerRadius = 5
        presenceDot.setContentHuggingPriority(.required, for: .horizontal)
        presenceDot.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            presenceDot.widthAnchor.constraint(equalToConstant: 10),
            presenceDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        // Semibold at the body size, scaled by the body metric so it still tracks Dynamic Type.
        let base = UIFont.systemFont(ofSize: 17, weight: .semibold)
        nameLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail

        networkLabel.font = .preferredFont(forTextStyle: .body)
        networkLabel.adjustsFontForContentSizeCategory = true
        networkLabel.textColor = .secondaryLabel
        networkLabel.lineBreakMode = .byTruncatingTail

        let textStack = UIStackView(arrangedSubviews: [nameLabel, networkLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        textStack.alignment = .leading

        // The pill hugs its content and refuses to compress, so the name truncates before it.
        badgeContainer.setContentHuggingPriority(.required, for: .horizontal)
        badgeContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [presenceDot, textStack, badgeContainer])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            // Content stays clear of the card edges by at least 8, and the card floors at 64.
            // Together with the section's estimated group height this self-sizes: the card is
            // 64 at normal text and grows past it when the stack needs more, instead of the
            // text clipping inside a hard 64.
            row.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 8),
            row.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -8),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])

        // One element, not three: the whole card is a single button so VoiceOver reads
        // "#general, libera, 3 unread" and activates the tap, rather than landing on the name,
        // the network, and the badge one at a time. The label is synthesized in `configure`.
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// `presence` is set only for friend chips; nil leaves the chip exactly as a
    /// Favorites/Recent card (no dot). The dot color reads "is this friend reachable right
    /// now": green online, orange away, muted grey offline/unknown — deliberately understated
    /// for offline (the common case) rather than the web's red, which reads as an alert on iOS.
    func configure(name: String, network: String?, unread: Int, highlights: Int, presence: FriendPresence? = nil) {
        nameLabel.text = name
        networkLabel.text = network
        // Hidden rather than blank so the name centers in the card when there's no network.
        networkLabel.isHidden = network == nil

        presenceDot.isHidden = presence == nil
        if let presence { presenceDot.backgroundColor = Self.presenceColor(presence) }

        badgeContainer.subviews.forEach { $0.removeFromSuperview() }
        if let pill = makeUnreadBadge(unread: unread, highlights: highlights) {
            pill.translatesAutoresizingMaskIntoConstraints = false
            badgeContainer.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor),
                pill.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor),
                pill.topAnchor.constraint(equalTo: badgeContainer.topAnchor),
                pill.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor),
            ])
            badgeContainer.isHidden = false
        } else {
            badgeContainer.isHidden = true
        }

        var summary = network.map { "\(name), \($0)" } ?? name
        if let presence { summary += ", \(Self.presenceLabel(presence))" }
        if unread > 0 {
            summary += highlights > 0 ? ", \(unread) unread, mentioned" : ", \(unread) unread"
        }
        accessibilityLabel = summary
    }

    private static func presenceColor(_ presence: FriendPresence) -> UIColor {
        switch presence {
        case .online: return .systemGreen
        case .away: return .systemOrange
        case .offline: return .tertiaryLabel
        case .unknown: return .quaternaryLabel
        }
    }

    private static func presenceLabel(_ presence: FriendPresence) -> String {
        switch presence {
        case .online: return "online"
        case .away: return "away"
        case .offline: return "offline"
        case .unknown: return "status unknown"
        }
    }
}

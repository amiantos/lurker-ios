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

/// A buffer as a compact card, for the Friends, Favorites and Recent grids.
///
/// The grids are shortcuts, not the roster — a place to fit twice as many of the handful you
/// keep coming back to into the same vertical space, two across. So this is denser than a list
/// row and it looks like a card rather than a row: a filled, rounded tile that reads as "tap
/// target" at a glance, distinct from the grouped rows below it that carry swipe actions.
///
/// Density is layout, not type size — one font size app-wide. The name is weight, the network
/// hint is color, and the pill is the same one the rows use.
///
/// **One line, not two.** The card used to print the network name under every name, which
/// spent the taller half of a chip restating something that is the same for every chip on a
/// single-network instance and, on a multi-network one, is only ever *load-bearing* when two
/// chips collide. So the network appears as a short `li` hint after the name, on the rows
/// that actually need it (`NetworkAbbreviation`), and the chip is a name and a badge
/// otherwise. The accessibility label still names the network in full for every chip — the
/// hint is a visual shorthand, and losing the network entirely to a screen reader would be a
/// regression rather than a simplification.
///
/// The card lost a third of its height with the second line: it was 64 to fit two lines of
/// body text, and a one-line card that kept that height is a card mostly made of padding.
/// 44 is the floor rather than 42-and-change, because the whole card is the tap target and
/// 44×44 is the HIG minimum — a shortcut grid you hit without looking is the last place to
/// shave a touch target. It still grows past 44 at accessibility text sizes.
final class BufferChipCell: UICollectionViewCell {
    private let card = UIView()
    private let nameLabel = UILabel()
    private let networkHintLabel = UILabel()
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

        // Same size as the name — one font size app-wide, so the hint demotes itself with
        // color and weight alone, exactly as the web's `.net-hint` does.
        networkHintLabel.font = .preferredFont(forTextStyle: .body)
        networkHintLabel.adjustsFontForContentSizeCategory = true
        networkHintLabel.textColor = .secondaryLabel

        // The hint holds its size and the NAME truncates, which is the opposite of what a
        // single attributed label would do (a tail ellipsis eats the trailing hint first).
        // That would drop the disambiguator at exactly the width where two long names have
        // truncated to the same pixels — the one case it exists for. The web accepts the
        // ellipsis because a sidebar row is far wider than half a phone.
        //
        // 999, not `.required`: the hint must outrank the name, but it must still lose to the
        // card's own edges. A hint is usually 1-2 characters, but `NetworkAbbreviation` falls
        // back to the WHOLE network name when no prefix can separate two networks (two
        // connections both named `Libera.Chat`, or `irc` beside `ircnet`) — and a required
        // 88pt hint plus a required unread pill exceeds a chip's inner width on a small
        // phone, as does an ordinary 2-character hint at AX4/AX5. At `.required` that's an
        // unsatisfiable constraint set: Auto Layout breaks one of the card's edge pins and
        // the label draws outside the card, over the chip beside it. At 999 the hint simply
        // truncates last, which is the graceful version of the same priority.
        networkHintLabel.setContentHuggingPriority(.required, for: .horizontal)
        networkHintLabel.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A trailing spacer, because a horizontal stack distributes its slack by hugging
        // priority and *something* has to take it. Without this the name label — the lowest
        // hugging priority of the three — stretches to fill the card and renders its text
        // left-aligned inside that wider box, stranding the hint against the card's right
        // edge with a gap where the name used to end. The hint has to sit against the name:
        // it's a suffix to it, not a second column. (The vertical stack this replaced didn't
        // need one — a vertical stack's `alignment` handles the cross axis, so `.leading`
        // was enough.) Lowest hugging of all, so it and not a label yields the space.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // `.center`, not `.firstBaseline`, even though this is a row of text: both labels
        // scale off the SAME body metric at the same point size (only their weight differs),
        // so their boxes are identical heights and centering puts the baselines in exactly
        // the same place — while `.firstBaseline` would also have to align the spacer, which
        // has no text and therefore no baseline but its own top edge.
        let textStack = UIStackView(arrangedSubviews: [nameLabel, networkHintLabel, spacer])
        textStack.axis = .horizontal
        textStack.spacing = 4
        textStack.alignment = .center

        // The pill hugs its content and refuses to compress, so the name truncates before it.
        badgeContainer.setContentHuggingPriority(.required, for: .horizontal)
        badgeContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The presence dot shares the trailing slot with the unread pill (only one shows at a
        // time), so it sits where the count would — a friend's status and their unread badge
        // occupy the same corner rather than the dot crowding the name on the left.
        let row = UIStackView(arrangedSubviews: [textStack, badgeContainer, presenceDot])
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
            // Content stays clear of the card edges by at least 6, and the card floors at 44.
            // Together with the section's estimated group height this self-sizes: the card is
            // 44 at normal text and grows past it when the stack needs more, instead of the
            // text clipping inside a hard 44. The inset came down with the height — 8 above
            // and below one line of body text is what made a 44 card feel tight where it made
            // a 64 one feel deliberate.
            row.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 6),
            row.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -6),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        // One element, not three: the whole card is a single button so VoiceOver reads
        // "#general, libera, 3 unread" and activates the tap, rather than landing on the name,
        // the network, and the badge one at a time. The label is synthesized in `configure`.
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// The shape a drag lifts and lands (#53) — the card's rounded silhouette, not the cell's
    /// square bounding box.
    ///
    /// The cell owns this for the same reason `MessageBodyHosting` owns its hit-testing: only
    /// it knows where its visible body sits inside the row.
    ///
    /// `backgroundColor` has to be set as well as `visiblePath`, and to `.clear` specifically:
    /// the property is `null_resettable`, so leaving it nil means *the system default fill*,
    /// not transparency — and the four corner nubs that fall outside the rounded path would be
    /// painted with it for the length of the drag.
    ///
    /// The path draws circular corners where the card draws continuous ones (`cornerCurve`),
    /// because `UIBezierPath(roundedRect:cornerRadius:)` is the only public way to build one
    /// and it makes quarter-circles. At 12pt the difference is a fraction of a point and it
    /// only shows while a chip is in the air; approximating a squircle by hand would be a
    /// visibly worse trade.
    var dragPreviewParameters: UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(
            roundedRect: card.frame, cornerRadius: card.layer.cornerRadius
        )
        parameters.backgroundColor = .clear
        return parameters
    }

    /// `presence` is set only for friend chips; nil leaves the chip exactly as a
    /// Favorites/Recent card (no dot). The dot color reads "is this friend reachable right
    /// now": green online, orange away, muted grey offline/unknown — deliberately understated
    /// for offline (the common case) rather than the web's red, which reads as an alert on iOS.
    ///
    /// `networkName` is the full name and is always passed — it's what the accessibility label
    /// reads. `networkHint` is the short `/li` form and is set only where two chips would
    /// otherwise be identical; nil hides the label and collapses its slot, which on a
    /// single-network instance is every chip.
    func configure(
        name: String,
        networkName: String?,
        networkHint: String? = nil,
        unread: Int,
        highlights: Int,
        presence: FriendPresence? = nil
    ) {
        nameLabel.text = name
        networkHintLabel.text = networkHint
        networkHintLabel.isHidden = networkHint == nil

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
            // The unread count takes the trailing slot; the dot yields to it.
            presenceDot.isHidden = true
        } else {
            badgeContainer.isHidden = true
            presenceDot.isHidden = presence == nil
            if let presence { presenceDot.backgroundColor = Self.presenceColor(presence) }
        }

        // The FULL network name, on every chip, hint or no hint: the hint is a visual
        // shorthand for a collision you can see, and "which network is this" is a question a
        // screen-reader user can't answer by glancing at the chip beside it.
        var summary = networkName.map { "\(name), \($0)" } ?? name
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

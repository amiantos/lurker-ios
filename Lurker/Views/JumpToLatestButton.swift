// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The way back down: a floating glass chevron that returns the conversation to its newest
/// message, shown only while the reader is up in history. The badge counts what has arrived
/// below since they scrolled away — the same down-arrow-with-a-count pill Messages, Slack and
/// Discord float over their logs. The pill itself is `GlassPillButton`; this adds the badge.
final class JumpToLatestButton: GlassPillButton {
    private let badge = UILabel()
    private let badgeBackground = UIView()

    private static let badgeHeight: CGFloat = 18

    init() {
        super.init(systemName: "chevron.down", accessibilityLabel: "Jump to latest")

        // The count rides the pill's top-trailing shoulder, half on and half off, the way a tab
        // bar badges its items. Accent-filled: this is the one place the accent is right — it's
        // the app saying "there's more", not a sender's content. The pill's glass is pinned to
        // this view's edges, so anchoring to self's trailing/top is the pill's shoulder.
        badgeBackground.backgroundColor = .tintColor
        badgeBackground.layer.cornerRadius = Self.badgeHeight / 2
        badgeBackground.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .preferredFont(forTextStyle: .caption2).bold
        badge.textColor = .white
        badge.textAlignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        // The count already speaks through the button's accessibilityValue; left as elements of
        // their own, the badge views would announce it a second time as a separate focus stop.
        badge.isAccessibilityElement = false
        badgeBackground.isAccessibilityElement = false

        badgeBackground.addSubview(badge)
        addSubview(badgeBackground)

        NSLayoutConstraint.activate([
            badgeBackground.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badgeBackground.centerYAnchor.constraint(equalTo: topAnchor, constant: 2),
            badgeBackground.heightAnchor.constraint(equalToConstant: Self.badgeHeight),
            badgeBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.badgeHeight),

            badge.leadingAnchor.constraint(equalTo: badgeBackground.leadingAnchor, constant: 5),
            badge.trailingAnchor.constraint(equalTo: badgeBackground.trailingAnchor, constant: -5),
            badge.centerYAnchor.constraint(equalTo: badgeBackground.centerYAnchor),
        ])

        setNewCount(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// The badge. Zero hides it — the pill alone just means "you're not at the bottom"; the count
    /// only appears when something has actually arrived down there.
    func setNewCount(_ count: Int) {
        badgeBackground.isHidden = count <= 0
        badge.text = count > 99 ? "99+" : String(count)
        setAccessibilityValue(count > 0 ? "\(count) new message\(count == 1 ? "" : "s")" : nil)
    }
}

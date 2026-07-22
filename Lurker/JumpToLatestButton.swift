// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The way back down: a floating glass chevron that returns the conversation to its
/// newest message, shown only while the reader is up in history. The badge counts what
/// has arrived below since they scrolled away — the same down-arrow-with-a-count pill
/// Messages, Slack and Discord float over their logs.
///
/// Same construction as the composer's round pills — a `UIGlassEffect` wrapper around a
/// plain button — so the two read as one family of floating controls. Not part of the
/// composer's glass *container*, though: this pill stands alone above the conversation,
/// and joining the group would bleed its glass toward the bar it's deliberately clear of.
final class JumpToLatestButton: UIView {
    var onTap: (() -> Void)?

    private let glass = UIVisualEffectView()
    private let button = UIButton(type: .system)
    private let badge = UILabel()
    private let badgeBackground = UIView()
    /// Width/height, kept so a Dynamic Type change can re-match the composer's pills.
    private var pillSizeConstraints: [NSLayoutConstraint] = []

    private static let badgeHeight: CGFloat = 18

    override init(frame: CGRect) {
        super.init(frame: frame)

        let effect = UIGlassEffect()
        effect.isInteractive = true
        glass.effect = effect
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false

        // The send button's own glyph metric, so the two circles a few points apart draw
        // their symbols at the same visual weight.
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "chevron.down")
        config.preferredSymbolConfigurationForImage = ComposerBar.glyph
        config.baseForegroundColor = .label
        button.configuration = config
        button.accessibilityLabel = "Jump to latest"
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        // The count rides the pill's top-trailing shoulder, half on and half off, the way
        // a tab bar badges its items. Accent-filled: this is the one place the accent is
        // right — it's the app saying "there's more", not a sender's content.
        badgeBackground.backgroundColor = .tintColor
        badgeBackground.layer.cornerRadius = Self.badgeHeight / 2
        badgeBackground.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .preferredFont(forTextStyle: .caption2).bold
        badge.textColor = .white
        badge.textAlignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false

        glass.contentView.addSubview(button)
        addSubview(glass)
        badgeBackground.addSubview(badge)
        addSubview(badgeBackground)

        // The send button's exact diameter — it sits directly below this pill, and
        // matching it is what makes the two read as one family (see `collapsedHeight`).
        let pill = ComposerBar.collapsedHeight
        pillSizeConstraints = [
            glass.widthAnchor.constraint(equalToConstant: pill),
            glass.heightAnchor.constraint(equalToConstant: pill),
        ]
        NSLayoutConstraint.activate(pillSizeConstraints + [
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),

            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),

            badgeBackground.centerXAnchor.constraint(equalTo: glass.trailingAnchor, constant: -6),
            badgeBackground.centerYAnchor.constraint(equalTo: glass.topAnchor, constant: 2),
            badgeBackground.heightAnchor.constraint(equalToConstant: Self.badgeHeight),
            badgeBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.badgeHeight),

            badge.leadingAnchor.constraint(equalTo: badgeBackground.leadingAnchor, constant: 5),
            badge.trailingAnchor.constraint(equalTo: badgeBackground.trailingAnchor, constant: -5),
            badge.centerYAnchor.constraint(equalTo: badgeBackground.centerYAnchor),
        ])

        // Track Dynamic Type the way the composer's pills do (`updateMetrics`), so the
        // two stay the same size through a text-size change, not just at launch.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (pill: JumpToLatestButton, _) in
            pill.pillSizeConstraints.forEach { $0.constant = ComposerBar.collapsedHeight }
        }

        // Starts hidden; `setVisible` fades it in the first time the reader scrolls up.
        alpha = 0
        isUserInteractionEnabled = false
        setNewCount(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// The badge. Zero hides it — the pill alone just means "you're not at the bottom";
    /// the count only appears when something has actually arrived down there.
    func setNewCount(_ count: Int) {
        badgeBackground.isHidden = count <= 0
        badge.text = count > 99 ? "99+" : String(count)
        button.accessibilityValue = count > 0
            ? "\(count) new message\(count == 1 ? "" : "s")"
            : nil
    }

    /// Fade + a small settle, and the touch target goes with the visibility — an invisible
    /// button must not eat taps meant for the messages under it.
    func setVisible(_ visible: Bool, animated: Bool) {
        guard visible != isUserInteractionEnabled else { return }
        isUserInteractionEnabled = visible
        let changes = {
            self.alpha = visible ? 1 : 0
            self.transform = visible ? .identity : CGAffineTransform(scaleX: 0.85, y: 0.85)
        }
        guard animated else { return changes() }
        UIView.animate(
            withDuration: 0.25, delay: 0,
            usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: changes
        )
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The way back UP: a floating glass chevron that jumps to the first unread message, shown
/// when a buffer opened with unreads sitting above the reader (#45). The twin of
/// `JumpToLatestButton` — same `UIGlassEffect` pill in the same bottom-trailing slot — but
/// pointing up, and the two never show at once: the up-chevron means "you're at the latest,
/// go back to your first unread", the down-chevron means "you're up in history, return to
/// live". One position, the arrow says which way.
///
/// No badge: like the web client's own jump-to-unread affordance, it just says there's unread
/// above — the number a jump-to-latest pill badges (new-while-away) has no counterpart here.
final class JumpToUnreadButton: UIView {
    var onTap: (() -> Void)?

    private let glass = UIVisualEffectView()
    private let button = UIButton(type: .system)
    /// Width/height, kept so a Dynamic Type change can re-match the composer's pills.
    private var pillSizeConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)

        let effect = UIGlassEffect()
        effect.isInteractive = true
        glass.effect = effect
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false

        // The send button's glyph metric, so this circle draws its chevron at the same visual
        // weight as the jump-to-latest pill a few points away (they share the slot).
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "chevron.up")
        config.preferredSymbolConfigurationForImage = ComposerBar.glyph
        config.baseForegroundColor = .label
        button.configuration = config
        button.accessibilityLabel = "Jump to first unread"
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        glass.contentView.addSubview(button)
        addSubview(glass)

        // The send button's exact diameter, matching `JumpToLatestButton`, so whichever pill
        // is showing occupies the identical footprint.
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
        ])

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (pill: JumpToUnreadButton, _) in
            pill.pillSizeConstraints.forEach { $0.constant = ComposerBar.collapsedHeight }
        }

        // Starts hidden; `setVisible` fades it in the first time it's warranted.
        alpha = 0
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Fade + a small settle, and the touch target goes with the visibility — an invisible
    /// pill must not eat taps meant for the messages under it. Mirrors `JumpToLatestButton`.
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

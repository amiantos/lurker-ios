// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The shared body of the floating glass pills that hover over the conversation — the
/// jump-to-latest and jump-to-first-unread controls (#42, #45). A `UIGlassEffect` capsule
/// sized to the composer's send button, holding a single SF Symbol button, that fades its
/// visibility (and its touch target) in and out. Subclasses supply the glyph and add anything
/// extra on top (the latest pill's unread badge); everything else lives here so the family
/// stays visually and behaviourally in lockstep.
class GlassPillButton: UIView {
    var onTap: (() -> Void)?

    private let glass = UIVisualEffectView()
    private let button = UIButton(type: .system)
    /// Width/height, kept so a Dynamic Type change can re-match the composer's pills.
    private var pillSizeConstraints: [NSLayoutConstraint] = []

    init(systemName: String, accessibilityLabel: String) {
        super.init(frame: .zero)

        let effect = UIGlassEffect()
        effect.isInteractive = true
        glass.effect = effect
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false

        // The send button's glyph metric, so pills a few points apart draw their symbols at the
        // same visual weight.
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)
        config.preferredSymbolConfigurationForImage = ComposerBar.glyph
        config.baseForegroundColor = .label
        button.configuration = config
        button.accessibilityLabel = accessibilityLabel
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        glass.contentView.addSubview(button)
        addSubview(glass)

        // The send button's exact diameter, so every pill in the family occupies one footprint.
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

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (pill: GlassPillButton, _) in
            pill.pillSizeConstraints.forEach { $0.constant = ComposerBar.collapsedHeight }
        }

        // Starts hidden; `setVisible` fades it in the first time it's warranted.
        alpha = 0
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// A supplementary VoiceOver value on the button (the latest pill's "N new messages").
    func setAccessibilityValue(_ value: String?) {
        button.accessibilityValue = value
    }

    /// Fade + a small settle, and the touch target goes with the visibility — an invisible pill
    /// must not eat taps meant for the messages under it.
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

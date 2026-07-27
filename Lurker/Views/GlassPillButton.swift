// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// A round glass pill floating in the conversation's bottom-trailing corner: a capsule sized to
/// the composer's send button, holding a single SF Symbol button. Subclasses supply the glyph and
/// add anything extra on top (the latest pill's unread badge); the capsule, the fade and the
/// touch-target coupling come from `FloatingGlassControl`.
class GlassPillButton: FloatingGlassControl {
    private let button = UIButton(type: .system)
    /// Width/height, kept so a Dynamic Type change can re-match the composer's pills.
    private var pillSizeConstraints: [NSLayoutConstraint] = []

    init(systemName: String, accessibilityLabel: String) {
        super.init(frame: .zero)

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

        // The send button's exact diameter, so every pill in the family occupies one footprint.
        let pill = ComposerBar.collapsedHeight
        pillSizeConstraints = [
            glass.widthAnchor.constraint(equalToConstant: pill),
            glass.heightAnchor.constraint(equalToConstant: pill),
        ]
        NSLayoutConstraint.activate(pillSizeConstraints + [
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (pill: GlassPillButton, _) in
            pill.pillSizeConstraints.forEach { $0.constant = ComposerBar.collapsedHeight }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// A supplementary VoiceOver value on the button (the latest pill's "N new messages").
    func setAccessibilityValue(_ value: String?) {
        button.accessibilityValue = value
    }
}

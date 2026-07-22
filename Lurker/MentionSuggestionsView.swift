// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The @‑mention suggestions: up to four nicks floating above the composer as separate
/// glass pills, most recent speaker at the top. Discrete pills rather than one panel —
/// everything down at the composer is already a family of floating glass capsules, and
/// a flat list box would be the one flat thing among them.
///
/// Dumb by design: the owner computes candidates (`NickCompletion`) and hands them to
/// `show`; this view only draws pills and reports taps.
final class MentionSuggestionsView: UIView {
    var onPick: ((String) -> Void)?

    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Rebuild the pills. Empty hides the strip. Rebuilt wholesale rather than diffed —
    /// it's at most four small views, and a keystroke replaces the whole answer anyway.
    func show(_ nicks: [String]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for nick in nicks {
            stack.addArrangedSubview(pill(for: nick))
        }
        isHidden = nicks.isEmpty
    }

    /// One nick as a tappable glass capsule, in the nick's own palette color — the same
    /// identity signal the conversation above uses.
    private func pill(for nick: String) -> UIView {
        let glass = UIVisualEffectView()
        let effect = UIGlassEffect()
        effect.isInteractive = true
        glass.effect = effect
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.plain()
        config.title = nick
        config.baseForegroundColor = MessageRenderer.hashedColor(nick)
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
            return attrs
        }
        let button = UIButton(configuration: config)
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.accessibilityLabel = "Mention \(nick)"
        button.addAction(UIAction { [weak self] _ in self?.onPick?(nick) }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        glass.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])
        return glass
    }
}

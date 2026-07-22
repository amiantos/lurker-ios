// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// One floating pill's worth of content: what it says, what it inserts, its color, and its
/// spoken label. A nick and a command and a channel are all one shape on screen — a glass
/// capsule — differing only in tint and in what a tap inserts, so they share this model
/// rather than three parallel views.
struct Suggestion: Equatable {
    let title: String
    let value: String
    let color: UIColor
    let accessibility: String

    /// A command: shown with its slash, tinted the app accent to read as an action, and
    /// inserted by canonical name (the composer adds the slash and trailing space).
    static func command(_ spec: CommandSpec) -> Suggestion {
        Suggestion(title: "/\(spec.name)", value: spec.name, color: .tintColor,
                   accessibility: "Command \(spec.name), \(spec.summary)")
    }

    /// A channel: shown and inserted verbatim, in neutral label color.
    static func channel(_ name: String) -> Suggestion {
        Suggestion(title: name, value: name, color: .label, accessibility: "Channel \(name)")
    }

    /// A nick: in the nick's own palette color — the same identity signal the conversation
    /// above uses.
    static func nick(_ nick: String) -> Suggestion {
        Suggestion(title: nick, value: nick, color: MessageRenderer.hashedColor(nick),
                   accessibility: "Insert \(nick)")
    }
}

/// The completion suggestions: up to four options floating above the composer as separate
/// glass pills, best candidate at the bottom — likelihood equals proximity to the field, so
/// the pill you almost certainly want is the shortest reach. (Discord stacks its panel the
/// other way, but a panel has a selection cursor; loose pills don't.) Discrete pills rather
/// than one panel — everything down at the composer is already a family of floating glass
/// capsules, and a flat list box would be the one flat thing among them.
///
/// Dumb by design: the owner computes the suggestions (a command, channel, or nick strip) and
/// hands them to `show`; this view only draws pills and reports taps.
final class SuggestionsView: UIView {
    var onPick: ((Suggestion) -> Void)?

    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        // Centered, not leading-aligned: the pills hang in the middle of the screen over
        // the field, so each is a thumb's reach from either hand rather than a stretch
        // to the left edge — and mixed-width titles read as one centered group.
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Rebuild the pills from a best-first list; the reversal here is what puts the best
    /// candidate nearest the composer. Empty hides the strip. Rebuilt wholesale rather
    /// than diffed — it's at most four small views, and a keystroke replaces the whole
    /// answer anyway.
    func show(_ suggestions: [Suggestion]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for suggestion in suggestions.reversed() {
            stack.addArrangedSubview(pill(for: suggestion))
        }
        isHidden = suggestions.isEmpty
    }

    /// One suggestion as a tappable glass capsule, in its own color.
    private func pill(for suggestion: Suggestion) -> UIView {
        let glass = UIVisualEffectView()
        let effect = UIGlassEffect()
        effect.isInteractive = true
        glass.effect = effect
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.plain()
        config.title = suggestion.title
        config.baseForegroundColor = suggestion.color
        // Generous on purpose: these are one-shot tap targets mid-typing, not persistent
        // chrome — roughly the composer pills' height, with wider shoulders for the thumb.
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
            return attrs
        }
        let button = UIButton(configuration: config)
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.accessibilityLabel = suggestion.accessibility
        button.addAction(UIAction { [weak self] _ in self?.onPick?(suggestion) }, for: .touchUpInside)
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

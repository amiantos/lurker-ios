// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The way back UP: a glass capsule that drops down from under the nav bar to say there are
/// unread messages above the reader, and jumps to the first of them when tapped (#45).
///
/// It lives at the *top* because that's where it's taking you. It used to share the
/// bottom-trailing slot with `JumpToLatestButton` — one footprint, the arrow saying which way —
/// which cost it two things: an up-chevron pinned to the bottom of the screen is a small mental
/// inversion every time, and with the compact message list (#73) every row runs the full width,
/// so the pill sat squarely on the newest message's text. On its own edge it reads as what it is
/// — the "unread above" banner Slack and Discord float at the top of a channel — and the two
/// controls stop being mutually exclusive: unread above and live traffic below is a real state,
/// and now both can be offered at once.
///
/// No count. Opening a buffer marks it read, so the live unread count is zero by the first frame;
/// what keeps this on screen is the latched divider being off-screen (see `updateFloatingPills`).
/// A number here would read `0` or stale.
final class UnreadBanner: FloatingGlassControl {
    private let button = UIButton(type: .system)

    /// Tucked up under the nav bar while hidden, so it slides down into the gap between the title
    /// pill and the conversation — the same entrance `ConnectionBanner` makes from the same slot.
    override var hiddenTransform: CGAffineTransform { CGAffineTransform(translationX: 0, y: -12) }

    init() {
        super.init(frame: .zero)

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "chevron.up")
        config.imagePlacement = .leading
        config.imagePadding = 6
        config.title = "Unread messages"
        // `.label`, and the same subheadline the connection banner sets: these two capsules take
        // turns in one slot, so they have to be the same object in different words.
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 16)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
            return attributes
        }
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .subheadline, scale: .small
        )
        button.configuration = config
        // The words are the label; VoiceOver gets the action instead, since tapping is the whole
        // point and "unread messages" alone doesn't say a tap does anything.
        button.accessibilityLabel = "Jump to first unread"
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        glass.contentView.addSubview(button)

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])

        // A configuration's font is resolved when the configuration updates, and a content-size
        // change is one of the things that triggers an update — but only if the button is asked.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (banner: UnreadBanner, _) in
            banner.button.setNeedsUpdateConfiguration()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }
}

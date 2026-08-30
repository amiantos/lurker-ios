// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// A brief glass capsule that says something happened and then gets out of the way — "Link
/// Copied" after tapping an upload (#138) being the first of them.
///
/// **For actions whose whole result is invisible.** Copying to the pasteboard changes nothing on
/// screen, so without a word for it a tap is indistinguishable from a missed touch, and the reader
/// taps again. It is deliberately not an alert: an alert demands a dismissal for something that
/// needs no decision, and the second tap of "copy, OK, copy, OK" is pure tax.
///
/// A `FloatingGlassControl` like the jump pill and the unread banner, so the app has one floating
/// vocabulary rather than a bespoke overlay per screen.
final class ToastView: FloatingGlassControl {

    /// How long the message stays up once it has arrived. Long enough to read three words at a
    /// glance, short enough that it is gone before it becomes something to dismiss.
    private static let holdSeconds: TimeInterval = 1.2

    /// The toast currently up, if any. One at a time: rapid taps REPLACE rather than stack, or a
    /// column of identical capsules climbs the screen for something that happened once per tap.
    private static weak var current: ToastView?

    /// Put `message` up over `host`, just above whatever the bottom safe area is holding.
    ///
    /// ⚠ Announced to VoiceOver as well as drawn. A purely visual confirmation is no confirmation
    /// at all for a reader who cannot see it, and this is the only feedback the action has.
    static func show(_ message: String, symbol: String, over host: UIView) {
        current?.dismissNow()

        let toast = ToastView(message: message, symbol: symbol)
        toast.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            // Above the search field rather than over it — the bottom bar is part of the safe
            // area, so this clears whatever the screen happens to be carrying down there.
            toast.bottomAnchor.constraint(
                equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 24),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -24),
        ])
        current = toast

        // The same light tap the rest of the app uses to acknowledge a gesture. It is also the
        // only feedback the action has with the screen in a pocket-height glance.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: message)

        host.layoutIfNeeded()
        toast.setVisible(true, animated: true)
        // A `Task` rather than a `DispatchWorkItem`, matching the debounces elsewhere in the app:
        // it is main-actor by default here, and cancelling it is how a replacing toast stops this
        // one's fade landing on top of it.
        toast.life = Task { [weak toast] in
            try? await Task.sleep(for: .seconds(holdSeconds))
            guard !Task.isCancelled, let toast else { return }
            toast.setVisible(false, animated: true)
            // Removed AFTER the fade, not on the next show: a stranded transparent view over the
            // grid is invisible right up until something changes its alpha. (It takes no touches
            // either way — see `point(inside:)` — so this is tidiness, not a hit-testing fix.)
            try? await Task.sleep(for: .seconds(0.3))
            toast.removeFromSuperview()
        }
    }

    private var life: Task<Void, Never>?

    private init(message: String, symbol: String) {
        super.init(frame: .zero)

        let glyph = UIImageView(image: UIImage(systemName: symbol))
        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = .label
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = message
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label

        let row = UIStackView(arrangedSubviews: [glyph, label])
        row.axis = .horizontal
        row.spacing = 7
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -16),
        ])

        // ⚠ NOT an accessibility element. VoiceOver hit-testing goes by accessibility frames, not
        // by `point(inside:)`, so an element here would be a thing to swipe onto that vanishes a
        // second later mid-focus. The message reaches that reader as the announcement `show` posts
        // — which is a transient notification, which is what this is.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// ⚠⚠ A toast NEVER takes a touch. `FloatingGlassControl.setVisible` turns interaction on with
    /// visibility, which is right for the pills it was written for and wrong here: this capsule
    /// floats over a grid the reader is still using, and swallowing a tap on the tile underneath
    /// it — for a view that is about to disappear on its own — would be the worst kind of missed
    /// touch. Refused at the hit test rather than by leaving the flag off, so the base's own
    /// visibility bookkeeping still works.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    /// Take it down at once, without the fade — for the toast being replaced by the next one.
    private func dismissNow() {
        life?.cancel()
        removeFromSuperview()
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The shared body of the controls that float over the conversation — the jump-to-latest pill in
/// the bottom-trailing corner (#42), the unread banner under the nav bar (#45). A `UIGlassEffect`
/// capsule pinned to this view's edges for subclasses to fill, plus the one behaviour they all
/// have to get right: visibility and the touch target move *together*, so a faded-out control
/// never eats a tap meant for the messages scrolling underneath it.
///
/// Shape and content are the subclass's business — a round icon pill and a wide labelled banner
/// are the same control family in everything but silhouette.
class FloatingGlassControl: UIView {
    var onTap: (() -> Void)?

    /// Where subclasses hang their content.
    let glass = UIVisualEffectView()

    /// The resting transform while hidden — what the show animation springs *from*, and settles
    /// back to on the way out. The corner pills scale down in place; the banner tucks itself up
    /// under the nav bar instead, so it drops into view rather than fading in flat.
    var hiddenTransform: CGAffineTransform { CGAffineTransform(scaleX: 0.85, y: 0.85) }

    override init(frame: CGRect) {
        super.init(frame: frame)

        let effect = UIGlassEffect()
        effect.isInteractive = true
        glass.effect = effect
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Starts hidden; `setVisible` brings it in the first time it's warranted.
        alpha = 0
        transform = hiddenTransform
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Fade + a small settle, and the touch target goes with the visibility.
    func setVisible(_ visible: Bool, animated: Bool) {
        guard visible != isUserInteractionEnabled else { return }
        isUserInteractionEnabled = visible
        let changes = {
            self.alpha = visible ? 1 : 0
            self.transform = visible ? .identity : self.hiddenTransform
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

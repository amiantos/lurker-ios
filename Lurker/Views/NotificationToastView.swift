// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The buffer list's in-app notification: a glass capsule along the bottom saying what the chat
/// screen's status row would — "bob: are you around?" in the message list's face — and going to
/// the line when tapped. The list has no composer to carry a status row, so it floats instead.
///
/// Unlike `ToastView` it takes a touch, since going there is the point of it; it's up for a few
/// seconds at a time (`StatusToastPresenter`), and the row it covers is still a scroll away.
final class NotificationToastView: FloatingGlassControl {
    private let label = UILabel()

    /// Rises into place from just below, rather than settling in place like the corner pills.
    override var hiddenTransform: CGAffineTransform { CGAffineTransform(translationX: 0, y: 12) }

    override init(frame: CGRect) {
        super.init(frame: frame)

        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -16),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Opens the conversation."
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Show `toast`, or fade out at nil. The text stays through the fade.
    func render(_ toast: StatusToast?) {
        if let toast {
            // Re-read each time: the compact face doesn't follow Dynamic Type on its own.
            let text = toast.attributedText(font: MessageRenderer.compactFont(compatibleWith: traitCollection))
            label.attributedText = text
            accessibilityLabel = text.string
        }
        // Not a thing to swipe onto while faded out.
        accessibilityElementsHidden = toast == nil
        setVisible(toast != nil, animated: true)
    }

    @objc private func tapped() { onTap?() }
}

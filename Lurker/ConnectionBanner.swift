// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The loud counterpart to the title pill's status dot: a floating glass capsule that drops
/// down from under the nav bar to say, in words, when the connection is unhappy — "No
/// internet connection", "Connecting…", "Reconnecting…". The dot is always-on ambient and
/// easy to miss; this appears only when something is wrong, and a chat app that hides its
/// connection state is worse than one missing features (#19).
///
/// Built from the same `UIGlassEffect` capsule as the jump pill and the composer's buttons,
/// so it reads as one family of floating controls. It never eats touches — the conversation
/// scrolls under it — and it debounces: a state has to persist past a short grace before it
/// shows, so the ~1s connect on a normal launch doesn't flash a "Connecting…" pill on every
/// cold start, and a wifi micro-drop doesn't blink the banner.
final class ConnectionBanner: UIView {

    private let glass = UIVisualEffectView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let dot = UIView()
    private let label = UILabel()

    /// The state currently being shown (or scheduled to show). `.hidden` means the banner
    /// is — or is on its way to — gone.
    private var state: ConnectionBannerState = .hidden
    private var pendingShow: DispatchWorkItem?

    /// How long a non-hidden state must persist before the banner appears. Long enough to
    /// swallow a normal launch's connect and a brief blip; short enough that a real outage
    /// is named almost at once.
    private static let grace: TimeInterval = 0.6
    private static let dotSize: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)

        let effect = UIGlassEffect()
        glass.effect = effect
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        dot.layer.cornerRadius = Self.dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false

        // `.label`, not the severity color: amber/red text on glass reads as low-contrast,
        // and the leading dot/spinner already carries the severity. The words just have to
        // be legible.
        label.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
        label.textColor = .label
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [spinner, dot, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        glass.contentView.addSubview(stack)
        addSubview(glass)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),

            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
        ])

        // A status readout, not a control: announce it, but never intercept a touch meant
        // for the messages scrolling underneath.
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently

        // Starts gone: hidden from layout so it reserves no space, and see-through so the
        // first real state animates in from nothing.
        alpha = 0
        isHidden = true
        transform = Self.tuckedUp
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Drive the banner from a resolved `ConnectionBannerState`. Hidden hides at once;
    /// anything else appears only after the grace, so transient states never flash.
    func update(_ state: ConnectionBannerState) {
        guard state != self.state else { return }
        self.state = state

        guard state != .hidden else {
            pendingShow?.cancel()
            pendingShow = nil
            animateOut()
            return
        }

        // Already on screen (or on its way off) → restyle in place. If a fade-out was in
        // flight — connected, then a flap dropped us again inside the 0.25s — its model
        // alpha is already 0, so pull it back in; otherwise the banner would sit configured
        // but invisible, because the out-animation's completion declined to hide it.
        if !isHidden {
            configure(for: state)
            if alpha < 1 { animateIn() }
            return
        }
        guard pendingShow == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state != .hidden else { return }
            self.pendingShow = nil
            self.configure(for: self.state)
            self.animateIn()
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: work)
    }

    private func configure(for state: ConnectionBannerState) {
        switch state {
        case .hidden:
            return
        case .connecting:
            label.text = "Connecting…"
        case .reconnecting:
            label.text = "Reconnecting…"
        case .offline:
            label.text = "No internet connection"
        }
        // Working states spin (amber, "still trying"); offline shows a settled red dot —
        // there's nothing in flight until the user brings a path back.
        if state.isWorking {
            spinner.color = Palette.warn
            spinner.startAnimating()
            dot.isHidden = true
        } else {
            spinner.stopAnimating()
            dot.backgroundColor = Palette.bad
            dot.isHidden = false
        }
        accessibilityLabel = label.text
    }

    private func animateIn() {
        isHidden = false
        UIView.animate(
            withDuration: 0.3, delay: 0,
            usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
            options: [.beginFromCurrentState]
        ) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    private func animateOut() {
        guard !isHidden else { return }
        UIView.animate(
            withDuration: 0.25, delay: 0,
            options: [.beginFromCurrentState]
        ) {
            self.alpha = 0
            self.transform = Self.tuckedUp
        } completion: { _ in
            // Only actually hide if nothing asked us back on-screen mid-animation.
            if self.state == .hidden {
                self.isHidden = true
                self.spinner.stopAnimating()
            }
        }
    }

    /// The off-screen resting transform: nudged up under the nav bar so it slides down into
    /// place rather than fading in flat.
    private static let tuckedUp = CGAffineTransform(translationX: 0, y: -12)
}

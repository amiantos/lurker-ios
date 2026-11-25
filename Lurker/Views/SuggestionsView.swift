// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import OSLog
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
    static func nick(_ nick: String, displayName: String? = nil) -> Suggestion {
        // With a display name (lurker#1203) the chip says both — the name you recognise and the
        // nick a pick inserts, as the web's picker shows the name with the nick in a badge. A chip
        // reading only "Brad Root" that types `amiantos` would be a chip that lies about its tap.
        Suggestion(
            title: displayName.map { "\($0) · \(nick)" } ?? nick,
            value: nick, color: MessageRenderer.hashedColor(nick),
            accessibility: displayName.map { "Insert \(nick), \($0)" } ?? "Insert \(nick)"
        )
    }
}

/// The completion suggestions: a horizontal row of plain chips in the composer's status row,
/// best candidate first (leading), scrolling sideways when there are more than fit. Plain
/// rather than glass — they live inside the composer's slab, and glass inside glass doesn't
/// sample.
///
/// Dumb by design: the owner computes the suggestions (a command, channel, or nick strip) and
/// hands them to `show`; this view only draws chips and reports taps.
final class SuggestionsView: UIView {
    var onPick: ((Suggestion) -> Void)?
    /// A finger went down on a chip, and came off it again (picked or not). The composer holds
    /// the keyboard off the text between the two — see `ComposerBar.beginChipPress`.
    var onPressBegan: (() -> Void)?
    var onPressEnded: (() -> Void)?
    /// Whether a chip is under a finger right now, and the list that arrived meanwhile.
    private var pressed = false
    private var waiting: [Suggestion]?
    /// The chips as drawn, in order, so a touch seen at the window can be matched to one.
    private var shown: [Suggestion] = []
    /// A touch that went down on a chip, as the window saw it — see `windowWillSend`.
    private var watched: (touch: UITouch, suggestion: Suggestion, start: CGPoint)?
    /// Set when a chip's own tap was delivered, so the window's copy of it isn't picked twice.
    private var delivered = false
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lurker", category: "completion")
    /// Fired when the row appears or goes, so the composer can swap its status content.
    var onVisibilityChange: (() -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    /// The widest a chip draws before its title truncates, so one long nick can't take the row.
    private static let maxChipWidth: CGFloat = 240
    private static let chipInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.contentInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        isHidden = true
        // The row's top corners are the slab's, and a chip scrolled to either end poked out
        // past the curve. Clipped to the same corners here; `cornerRadius` is the owner's to set.
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Rebuild the chips from a best-first list. Empty hides the row. Rebuilt wholesale rather
    /// than diffed — it's a handful of small views, and a keystroke replaces the whole answer
    /// anyway.
    func show(_ suggestions: [Suggestion]) {
        // Not out from under a finger: rebuilding removes the chip being pressed, and its tap
        // with it. The list is drawn when the finger lifts.
        guard !pressed else {
            waiting = suggestions
            return
        }
        let wasHidden = isHidden
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for suggestion in suggestions {
            stack.addArrangedSubview(chip(for: suggestion))
        }
        shown = suggestions
        scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: 0)
        isHidden = suggestions.isEmpty
        if wasHidden != isHidden { onVisibilityChange?() }
    }

    // MARK: - Taps the system took

    override func didMoveToWindow() {
        super.didMoveToWindow()
        (window as? TouchWatchingWindow)?.addTouchWatcher(self)
    }

    /// The suggestion whose chip — at the row's full height, as its own target is — holds `point`.
    private func suggestion(at point: CGPoint) -> Suggestion? {
        guard !isHidden, bounds.contains(point) else { return nil }
        for (index, chip) in stack.arrangedSubviews.enumerated() where index < shown.count {
            let frame = chip.convert(chip.bounds, to: self)
            if point.x >= frame.minX - stack.spacing / 2, point.x <= frame.maxX + stack.spacing / 2 {
                return shown[index]
            }
        }
        return nil
    }

    private func pressEnded() {
        guard pressed else { return }
        pressed = false
        onPressEnded?()
        if let waiting {
            self.waiting = nil
            show(waiting)
        }
    }

    /// One suggestion as a tappable chip: its title in its own color on a faint fill.
    ///
    /// ⚠ Its width is stated, measured from its own title — not left to the stack. Left to the
    /// stack, the chips were reported all as wide as the longest one, so a single long nick made
    /// them all long. What in the layout did that was not found; stating the width means it no
    /// longer matters.
    private func chip(for suggestion: Suggestion) -> UIView {
        let font = MessageRenderer.compactFont(compatibleWith: traitCollection)
        var config = UIButton.Configuration.plain()
        config.title = suggestion.title
        config.titleLineBreakMode = .byTruncatingTail
        config.baseForegroundColor = suggestion.color
        config.background.backgroundColor = .tertiarySystemFill
        config.cornerStyle = .capsule
        config.contentInsets = Self.chipInsets
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = font
            return attrs
        }
        let button = RowHeightHitButton(configuration: config)
        button.horizontalOutset = stack.spacing / 2
        button.accessibilityLabel = suggestion.accessibility
        button.addAction(UIAction { [weak self] _ in
            // Usually the window saw this touch first and began the press; not twice, or the
            // field would be held as it is now, which may already be the corrected one.
            guard let self, !pressed else { return }
            pressed = true
            onPressBegan?()
        }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in
            self?.delivered = true
            self?.onPick?(suggestion)
        }, for: .touchUpInside)
        // After the pick, which is registered first: the pick reads the text the press protected.
        button.addAction(UIAction { [weak self] _ in self?.pressEnded() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let title = ceil((suggestion.title as NSString).size(withAttributes: [.font: font]).width)
        let width = min(title + Self.chipInsets.leading + Self.chipInsets.trailing, Self.maxChipWidth)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }
}

/// A button that takes touches across the full height of the row it sits in, though it draws
/// smaller: the status row's chips and its reply ✕ are drawn at the one-line text's size, but a
/// target that short is easy to miss. Its container must span the row, or touches beyond the
/// container never reach it.
final class RowHeightHitButton: UIButton {
    /// Extra width taken on each side — half the gap to a neighbour, so two never overlap.
    var horizontalOutset: CGFloat = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let rowHeight = superview?.bounds.height ?? bounds.height
        let vertical = max(0, (rowHeight - bounds.height) / 2)
        return bounds.insetBy(dx: -horizontalOutset, dy: -vertical).contains(point)
    }
}

extension CGRect {
    /// This rect grown about its centre until it is at least `minimum` on each side — the least
    /// a finger needs (lurker#1401). A side already that long is left alone.
    func reaching(_ minimum: CGFloat = 44) -> CGRect {
        insetBy(dx: min(0, (width - minimum) / 2), dy: min(0, (height - minimum) / 2))
    }
}

/// A button whose target is a finger's reach though it draws smaller: the composer's send
/// circle (lurker#1401). The reach has to stay inside the button's ancestors, or the touch is
/// never handed down to it.
final class ReachingButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.reaching().contains(point)
    }
}

extension SuggestionsView: WindowTouchWatcher {
    /// Every touch in the window, before it is handed out — `TouchWatchingWindow` says why.
    ///
    /// A touch that goes down on a chip and comes up, or is cancelled, without having moved is
    /// a tap on that chip, whether or not the system let the chip have it. The press is begun
    /// here too, so the composer holds the field before the keyboard applies its correction.
    /// The pick waits a turn of the run loop: a tap the chip did get has made it by then
    /// (`delivered`), and this copy stands down.
    func windowWillSend(_ touches: Set<UITouch>) {
        for touch in touches {
            let point = touch.location(in: self)
            switch touch.phase {
            case .began:
                guard watched == nil, let suggestion = suggestion(at: point) else { continue }
                watched = (touch, suggestion, point)
                delivered = false
                if !pressed {
                    pressed = true
                    onPressBegan?()
                }
            case .ended, .cancelled:
                guard let watched, watched.touch === touch else { continue }
                self.watched = nil
                let moved = hypot(point.x - watched.start.x, point.y - watched.start.y)
                let phase = touch.phase == .ended ? "ended" : "cancelled"
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Moved: a scroll of the row, not a tap.
                    if !delivered, moved < 10 {
                        Self.log.debug("a chip tap the chip never got (\(phase)); picked from the window")
                        onPick?(watched.suggestion)
                    }
                    delivered = false
                    pressEnded()
                }
            default:
                break
            }
        }
    }
}

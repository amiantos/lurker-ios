// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The message composer, in the shape Messages uses: a glass field that grows with the
/// text, flanked by a paperclip and a round send button. It floats over the conversation
/// rather than sitting on an opaque bar — the same iOS 26 glass the title pill and nav bar
/// use — so the messages scroll *under* it and off the bottom of the screen.
///
/// The three pieces live in one `UIGlassContainerEffect`, which gives them a shared
/// sampling region: at rest they read as three separate pills, but interacting with one
/// bleeds its glass toward its neighbors instead of each sitting in its own sealed pane.
/// That grouping is why the field and buttons are each a `UIVisualEffectView` with its own
/// `UIGlassEffect` rather than glass-configured `UIButton`s — a glass button doesn't join
/// the container.
///
/// A `UITextView`, not a `UITextField`, for two reasons the redesign turns on: it grows to
/// several lines, and Return inserts a newline. Sending is the button's job alone now — a
/// hardware/space Return no longer fires it — so a multi-line message is something you can
/// actually type.
final class ComposerBar: UIView {

    /// Called with the trimmed text when the send button is tapped. The bar does not clear
    /// itself — the owner does, once the send is accepted, via `clear()`.
    var onSend: ((String) -> Void)?

    /// Tapped the paperclip. Unset for now — the attach button reserves its place in the
    /// layout ahead of the image-upload feature, and does nothing until this is wired.
    var onAttach: (() -> Void)?

    /// Fired when the intrinsic height changes (a line added or removed), so the owner can
    /// re-inset the conversation under the grown bar.
    var onHeightChange: (() -> Void)?

    var placeholder: String = "" {
        didSet { placeholderLabel.text = placeholder }
    }

    private let container = UIVisualEffectView(effect: ComposerBar.containerEffect())
    private let attachGlass = UIVisualEffectView()
    private let fieldGlass = UIVisualEffectView()
    private let sendGlass = UIVisualEffectView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let attachButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)

    /// How tall the text may grow before it scrolls internally instead. Five lines is the
    /// Messages ceiling too — past that you're writing a paragraph, and the conversation
    /// behind the bar has given up enough room.
    private static let maxLines = 5
    /// The gap between the three glass pills.
    private static let gap: CGFloat = 8
    /// The text view's own inset. The placeholder is pinned to *these* exact values so it
    /// sits where the first typed character will, not merely somewhere near it.
    private static let textInset = UIEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
    /// The symbol size in the round buttons — small enough to read as an icon with air
    /// around it, like Messages'.
    private static let glyph = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)

    /// The height of the collapsed field: exactly one line of body text plus its inset.
    /// Used as the field's floor *and* the round pills' size, so the empty bar and the
    /// one-line bar are the same height — otherwise the field would jump a couple of points
    /// the instant you typed, because a fixed floor never quite matches a real line.
    private static var collapsedHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight) + textInset.top + textInset.bottom
    }
    private var textHeight: NSLayoutConstraint!
    /// The pills' width/height constraints, kept so a Dynamic Type change can resize them.
    private var pillSizeConstraints: [NSLayoutConstraint] = []
    /// Whether the send button is currently in its active (accent) state, so its glass
    /// effect is only rebuilt when that flips — not on every keystroke.
    private var sendActive: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Match the message bubbles' horizontal inset, so the group's edges line up with
        // the column of bubbles above it rather than sitting a few points proud of them. A
        // bare view defaults to an 8pt margin; a table cell's content uses the system 16,
        // which is what the bubbles get.
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        container.translatesAutoresizingMaskIntoConstraints = false

        // The field: a fixed radius, not `.capsule()`. A capsule's radius is half its
        // height, right at one line — but as the field grows the radius grows with it until
        // the corners are huge arcs that clip the text top and bottom. Pinned to half the
        // single-line height, it's a capsule when short and a rounded rectangle when tall.
        fieldGlass.effect = Self.glass()
        fieldGlass.cornerConfiguration = .corners(radius: .fixed(Self.collapsedHeight / 2))
        fieldGlass.translatesAutoresizingMaskIntoConstraints = false

        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = Self.textInset
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .no
        textView.isScrollEnabled = false // until it hits the cap; see textViewDidChange
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        // A UITextView has no placeholder of its own, so it's a label pinned inside — at the
        // text container's own origin, in the text view's own font, so it's indistinguishable
        // from a caret on an empty line. Hidden the moment there's text.
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        configureRoundGlass(attachGlass, button: attachButton, symbol: "paperclip")
        attachButton.addAction(UIAction { [weak self] _ in self?.onAttach?() }, for: .touchUpInside)

        configureRoundGlass(sendGlass, button: sendButton, symbol: "arrow.up")
        sendButton.addAction(UIAction { [weak self] _ in self?.fire() }, for: .touchUpInside)

        fieldGlass.contentView.addSubview(textView)
        fieldGlass.contentView.addSubview(placeholderLabel)
        container.contentView.addSubview(attachGlass)
        container.contentView.addSubview(fieldGlass)
        container.contentView.addSubview(sendGlass)
        addSubview(container)

        let content = container.contentView
        let pill = Self.collapsedHeight
        textHeight = textView.heightAnchor.constraint(equalToConstant: pill)
        // The round pills are sized to the field's one-line height so all three match. That
        // height tracks Dynamic Type, so these constants have to move with it (see
        // `updateMetrics`) — kept in one place for that.
        pillSizeConstraints = [
            attachGlass.widthAnchor.constraint(equalToConstant: pill),
            attachGlass.heightAnchor.constraint(equalToConstant: pill),
            sendGlass.widthAnchor.constraint(equalToConstant: pill),
            sendGlass.heightAnchor.constraint(equalToConstant: pill),
        ]
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: fieldGlass.contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: fieldGlass.contentView.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: fieldGlass.contentView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: fieldGlass.contentView.trailingAnchor),
            textHeight,

            // Exactly the text container's origin — same inset the glyphs use.
            placeholderLabel.leadingAnchor.constraint(
                equalTo: textView.leadingAnchor, constant: Self.textInset.left
            ),
            placeholderLabel.topAnchor.constraint(
                equalTo: textView.topAnchor, constant: Self.textInset.top
            ),

            container.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            container.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),

            // Both round pills sit at the *bottom* of the group, so they stay beside the
            // last line as the field grows upward rather than floating to the middle.
            attachGlass.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            attachGlass.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            fieldGlass.topAnchor.constraint(equalTo: content.topAnchor),
            fieldGlass.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            fieldGlass.leadingAnchor.constraint(equalTo: attachGlass.trailingAnchor, constant: Self.gap),

            sendGlass.leadingAnchor.constraint(equalTo: fieldGlass.trailingAnchor, constant: Self.gap),
            sendGlass.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sendGlass.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ] + pillSizeConstraints)

        // Keep the pills and the field's corner radius sized to one line as the text size
        // changes under us — without this the field's floor (recomputed live in
        // `textViewDidChange`) grows on a type change while the pills stay put, and the
        // three stop matching height.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bar: ComposerBar, _) in
            bar.updateMetrics()
        }

        updateSendEnabled()
    }

    /// Re-size the round pills and the field's corner radius to the current one-line height,
    /// then refresh the field's floor. Called on a Dynamic Type change.
    private func updateMetrics() {
        let pill = Self.collapsedHeight
        pillSizeConstraints.forEach { $0.constant = pill }
        fieldGlass.cornerConfiguration = .corners(radius: .fixed(pill / 2))
        textViewDidChange(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Clears the field after a send the owner accepted, and collapses it back to one line.
    func clear() {
        textView.text = ""
        textViewDidChange(textView)
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool { textView.becomeFirstResponder() }

    @discardableResult
    override func resignFirstResponder() -> Bool { textView.resignFirstResponder() }

    // MARK: - Setup helpers

    /// One interactive glass effect. Interactive so it reacts to touch the way Messages'
    /// controls do — illuminating under the finger — and, inside the container, bleeding
    /// toward its neighbors as it does. An optional tint colors the glass; the send button
    /// takes the accent when it goes live.
    /// The container that groups the three pills into one glass system. Its `spacing` is the
    /// merge threshold — glass elements closer than it bleed toward each other. The default
    /// leaves them inert, so it's set well above the `gap` between the pills: they bridge
    /// with a glassy meniscus when touched rather than sitting in sealed panes, without
    /// fully fusing into one shape. This is the knob to turn — lower it if they merge too
    /// much, raise it if they don't bleed enough.
    private static func containerEffect() -> UIGlassContainerEffect {
        let effect = UIGlassContainerEffect()
        effect.spacing = 10
        return effect
    }

    private static func glass(tint: UIColor? = nil) -> UIGlassEffect {
        let glass = UIGlassEffect()
        glass.isInteractive = true
        glass.tintColor = tint
        return glass
    }

    /// A round glass pill wrapping a plain (non-glass) button — the button can't carry the
    /// glass itself and still join the container, so the glass is the wrapper and the button
    /// just fills it.
    private func configureRoundGlass(_ glass: UIVisualEffectView, button: UIButton, symbol: String) {
        glass.effect = Self.glass()
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = Self.glyph
        config.baseForegroundColor = .label
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])
    }

    // MARK: - State

    private func fire() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend?(text)
    }

    private func updateSendEnabled() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText
        // Take the accent color when there's something to send, clear glass when not — the
        // same "lights up when it goes live" the Messages send button does, here through the
        // glass tint so it still belongs to the group. Only rebuilt on the transition:
        // reassigning `.effect` re-triggers the glass materialize, and this runs on every
        // keystroke.
        if sendActive != hasText {
            sendActive = hasText
            sendGlass.effect = Self.glass(tint: hasText ? .tintColor : nil)
            // White arrow on the accent tint when live, like Messages; back to `.label` on
            // the clear glass when there's nothing to send.
            sendButton.configuration?.baseForegroundColor = hasText ? .white : .label
        }
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
}

extension ComposerBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateSendEnabled()

        // Grow to fit the text, up to the cap; past it, hold the height and let the text
        // scroll inside. The floor is one line's height, the same value the pills use, so a
        // one-line message is exactly as tall as the empty field.
        let fitting = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let lineHeight = ceil((textView.font ?? .preferredFont(forTextStyle: .body)).lineHeight)
        let cap = Self.collapsedHeight + CGFloat(Self.maxLines - 1) * lineHeight
        let target = min(max(fitting, Self.collapsedHeight), cap)
        textView.isScrollEnabled = fitting > cap
        guard abs(textHeight.constant - target) > 0.5 else { return }
        textHeight.constant = target
        onHeightChange?()
    }
}

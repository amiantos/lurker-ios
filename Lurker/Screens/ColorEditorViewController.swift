// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The draft, full screen, with a palette docked above the keyboard — the composer's Edit Color.
///
/// The text IS the preview. Select words the ordinary way and tap a colour, and they change
/// where they sit; with nothing selected, the colour is what you type next, as in Notes. There's
/// no sample sentence and no hidden "pen" to keep track of: what the field shows is what sends.
///
/// Nothing here is a draft of the draft. Every change goes to the composer as it's made
/// (`onChange`), so it saves and syncs like typing there does — backgrounding mid-edit loses
/// nothing — and whatever changes the composer meanwhile (a finished upload's link, another
/// device's draft) comes back in through `adopt`. There's no Cancel to lose an edit to; undo is
/// there for a pick you didn't mean.
///
/// Sixteen colours, not mIRC's 99: the sixteen are the ones every client paints, and the list
/// draws them in the same palette (`MessageRenderer.mircSlot`).
final class ColorEditorViewController: UIViewController {

    /// What the editor hands back: the text, where the selection was, and a colour picked at a
    /// bare caret and not yet typed with — so "pick red, tap Done, type" types red.
    struct Result {
        let text: NSAttributedString
        let selection: NSRange
        let typing: (fg: Int?, bg: Int?)?
    }

    /// Every edit and colour pick, for the composer to mirror. Never mid-composition: an IME's
    /// marked text isn't written yet, and mirrored it would be saved and synced as if it were.
    var onChange: ((Result) -> Void)?
    /// A caret move — cheap to mirror, since the text hasn't changed.
    var onSelect: ((Result) -> Void)?
    /// An edit `onChange` held back while an IME was composing, owed once it commits.
    private var owesChange = false
    /// Done: for the composer to take back.
    var onDone: ((Result) -> Void)?
    /// Send: the same, then send it.
    var onSend: ((Result) -> Void)?

    private let textView = UITextView()
    private let panel = UIVisualEffectView()
    private let layerControl = UISegmentedControl(items: ["Text", "Highlight"])
    private let noneSwatch = SwatchButton(slot: nil)
    private var swatches: [SwatchButton] = []
    private let initialText: NSAttributedString
    private let initialSelection: NSRange
    private let initialTyping: (fg: Int?, bg: Int?)

    private var layer: ComposerColors.Layer {
        layerControl.selectedSegmentIndex == 0 ? .text : .highlight
    }

    /// The message list's fixed-width face, as in the composer this edits for. It's a fixed
    /// size per text-size setting, so a change is re-applied by hand — see `viewDidLoad`.
    private var font: UIFont { MessageRenderer.compactFont(compatibleWith: traitCollection) }

    /// mIRC's own names, for VoiceOver — the colour the code means to every other client.
    private static let names = [
        "White", "Black", "Blue", "Green", "Red", "Brown", "Purple", "Orange",
        "Yellow", "Light Green", "Teal", "Cyan", "Light Blue", "Pink", "Grey", "Light Grey",
    ]

    /// `typing` is the composer's pending colour — a pick made in an earlier visit and not yet
    /// typed with, which is still the pick.
    init(text: NSAttributedString, selection: NSRange, typing: (fg: Int?, bg: Int?)) {
        initialText = ComposerColors.restyled(text, font: MessageRenderer.compactFont())
        initialSelection = selection
        initialTyping = typing
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The message list's ground: what's written here is read against it.
        view.backgroundColor = Palette.bg
        title = "Edit Color"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Done", primaryAction: UIAction { [weak self] _ in self?.finish(sending: false) })
        let send = UIBarButtonItem(
            image: UIImage(systemName: "arrow.up"), style: .prominent, target: self, action: #selector(sendTapped))
        send.accessibilityLabel = "Send"
        navigationItem.rightBarButtonItem = send

        textView.font = font
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (editor: Self, _) in
            editor.textView.font = editor.font
            editor.adopt(editor.textView.attributedText, selection: editor.textView.selectedRange)
        }
        textView.attributedText = initialText
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        // Colour is the only styling a line carries here; the B/I/U menu would offer what
        // `ColorMarkup` can't write.
        textView.allowsEditingTextAttributes = false
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        buildPanel()

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -8),

            // Rides the keyboard, and sits on the safe area when it's down.
            panel.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        let fill = panel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor)
        fill.priority = .defaultHigh
        fill.isActive = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !textView.isFirstResponder else { return }
        let length = textView.attributedText.length
        let location = min(initialSelection.location, length)
        textView.selectedRange = NSRange(
            location: location, length: min(initialSelection.length, length - location))
        textView.becomeFirstResponder()
        if textView.selectedRange.length == 0 {
            textView.typingAttributes = ComposerColors.applying(initialTyping, to: textView.typingAttributes)
        }
        refreshPicks()
        // Placing the caret above already told the composer, before the pending colour was back.
        onSelect?(result)
    }

    /// Take in a change the composer made while this was open, keeping the caret where the
    /// composer put it — which is where this one was, since every move is mirrored there.
    ///
    /// ⚠ The undo stack goes: every step in it names a range in the text it was made against,
    /// and replayed against this one it would recolour the wrong words — or, on a shorter text,
    /// raise out of range and crash.
    ///
    /// ⚠ A colour picked at a bare caret and not yet typed with survives: assigning the text
    /// rebuilds the typing attributes from the characters, which would drop it.
    func adopt(_ text: NSAttributedString, selection: NSRange) {
        guard isViewLoaded else { return }
        let pending = textView.selectedRange.length == 0 ? ComposerColors.colors(in: textView.typingAttributes) : nil
        textView.attributedText = ComposerColors.restyled(text, font: font)
        textView.undoManager?.removeAllActions()
        let length = textView.attributedText.length
        let location = min(selection.location, length)
        textView.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
        if let pending, textView.selectedRange.length == 0 {
            textView.typingAttributes = ComposerColors.applying(pending, to: textView.typingAttributes)
        }
        refreshPicks()
        onSelect?(result)
    }

    // MARK: - Panel

    private func buildPanel() {
        panel.effect = UIGlassEffect()
        panel.cornerConfiguration = .corners(radius: .fixed(24))
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        layerControl.selectedSegmentIndex = 0
        layerControl.addAction(UIAction { [weak self] _ in self?.refreshPicks() }, for: .valueChanged)

        noneSwatch.accessibilityLabel = "No color"
        noneSwatch.addAction(UIAction { [weak self] _ in self?.pick(nil) }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [layerControl, noneSwatch])
        header.spacing = 12
        header.alignment = .center
        NSLayoutConstraint.activate([
            noneSwatch.widthAnchor.constraint(equalToConstant: 44),
            noneSwatch.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Two rows of eight: big enough to hit on the narrowest phone, small enough to leave the
        // text most of the screen above the keyboard.
        let rows = (0..<2).map { row in
            let stack = UIStackView(arrangedSubviews: (0..<8).map { column in
                let slot = row * 8 + column
                let swatch = SwatchButton(slot: slot)
                swatch.accessibilityLabel = Self.names[slot]
                swatch.addAction(UIAction { [weak self] _ in self?.pick(slot) }, for: .touchUpInside)
                swatches.append(swatch)
                swatch.heightAnchor.constraint(equalToConstant: 44).isActive = true
                return swatch
            })
            stack.distribution = .fillEqually
            return stack
        }

        let content = UIStackView(arrangedSubviews: [header] + rows)
        content.axis = .vertical
        content.spacing = 4
        content.setCustomSpacing(10, after: header)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -12),
        ])
    }

    /// Colour the selection, or — with only a caret — what's typed next.
    private func pick(_ slot: Int?) {
        let range = textView.selectedRange
        if range.length > 0 {
            let before = textView.attributedText.attributedSubstring(from: range)
            let after = NSMutableAttributedString(attributedString: before)
            ComposerColors.apply(slot, layer: layer, to: NSRange(location: 0, length: after.length), in: after)
            replace(range, with: after, undoing: before)
        } else {
            textView.typingAttributes = ComposerColors.applying(slot, layer: layer, to: textView.typingAttributes)
        }
        refreshPicks()
        onChange?(result)
    }

    /// Swap `range`'s styled text, undoably — colour changes go through the text storage, which
    /// registers nothing on its own. The selection stays put, so the highlight can follow the text
    /// colour onto the same words.
    private func replace(_ range: NSRange, with text: NSAttributedString, undoing previous: NSAttributedString) {
        textView.textStorage.replaceCharacters(in: range, with: text)
        textView.selectedRange = range
        textView.undoManager?.registerUndo(withTarget: self) { editor in
            editor.replace(range, with: previous, undoing: text)
            editor.refreshPicks()
            editor.onChange?(editor.result)
        }
        textView.undoManager?.setActionName("Color")
    }

    /// Ring the colour the selection (or the caret) is in now, for the layer being picked.
    private func refreshPicks() {
        let range = textView.selectedRange
        let attributes = range.length > 0
            ? textView.attributedText.attributes(at: range.location, effectiveRange: nil)
            : textView.typingAttributes
        let current = ComposerColors.slot(layer, in: attributes)
        for swatch in swatches { swatch.isSelected = swatch.slot == current }
        noneSwatch.isSelected = current == nil
    }

    // MARK: - Leaving

    @objc private func sendTapped() { finish(sending: true) }

    private func finish(sending: Bool) {
        (sending ? onSend : onDone)?(result)
    }

    private var result: Result {
        let selection = textView.selectedRange
        return Result(
            text: textView.attributedText ?? NSAttributedString(),
            selection: selection,
            typing: selection.length == 0 ? ComposerColors.colors(in: textView.typingAttributes) : nil)
    }
}

extension ColorEditorViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        guard textView.markedTextRange == nil else {
            owesChange = true
            return
        }
        owesChange = false
        onChange?(result)
    }

    /// A commit that leaves the text as it was (romaji `ka` committed as typed) changes no text,
    /// so `textViewDidChange` may not hear it — but the marked range went away, which lands here.
    func textViewDidChangeSelection(_ textView: UITextView) {
        refreshPicks()
        guard textView.markedTextRange == nil else { return }
        if owesChange {
            owesChange = false
            onChange?(result)
        } else {
            onSelect?(result)
        }
    }
}

/// One round colour in the palette — or, with no slot, the "no colour" choice. A ring marks the
/// colour the selection is in.
private final class SwatchButton: UIControl {
    let slot: Int?
    private let dot = UIView()
    private let ring = UIView()
    private let slash = UIImageView(image: UIImage(systemName: "circle.slash"))

    init(slot: Int?) {
        self.slot = slot
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        dot.isUserInteractionEnabled = false
        ring.isUserInteractionEnabled = false
        dot.backgroundColor = slot.flatMap(MessageRenderer.mircSlot)
        // A hairline, so white reads as a swatch on the light canvas and black on the dark one.
        dot.layer.borderWidth = slot == nil ? 0 : 1
        ring.layer.borderWidth = 2.5
        ring.isHidden = true
        slash.tintColor = .secondaryLabel
        slash.contentMode = .scaleAspectFit
        slash.isHidden = slot != nil
        addSubview(ring)
        addSubview(dot)
        addSubview(slash)
        updateBorders()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (swatch: SwatchButton, _) in
            swatch.updateBorders()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override var isSelected: Bool {
        didSet {
            ring.isHidden = !isSelected
            if isSelected { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
        }
    }

    override var isHighlighted: Bool {
        didSet { dot.alpha = isHighlighted ? 0.6 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height, 44) - 12
        let frame = CGRect(
            x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        dot.frame = frame
        dot.layer.cornerRadius = side / 2
        slash.frame = frame
        ring.frame = frame.insetBy(dx: -4, dy: -4)
        ring.layer.cornerRadius = ring.frame.width / 2
    }

    /// `CGColor`s don't follow the appearance, so they're re-resolved when it changes.
    private func updateBorders() {
        dot.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        ring.layer.borderColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
    }
}

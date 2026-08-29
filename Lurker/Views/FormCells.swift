// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The three cells a settings-shaped form needs: a labelled text field, a labelled switch,
/// and a multi-line text box.
///
/// Reusable primitives rather than three private classes inside the networks form (#11),
/// because a form is the one thing this app has needed repeatedly and built ad hoc each time
/// — the login screen hand-lays-out its own fields, and the settings screen hand-attaches a
/// `UISwitch` to a default content configuration. The next form (a highlight rule, a nick
/// note) should start from these.
///
/// `UIListContentConfiguration` deliberately isn't used: it has no text field, and a label
/// drawn by one configuration next to a control positioned by hand is how two rows in the
/// same table end up misaligned.

/// A label and a text field on one line. The label hugs its content and the field takes the
/// rest, so a long value scrolls inside the field rather than squeezing the label.
final class FormTextCell: UITableViewCell {
    static let reuseID = "form.text"

    let field = UITextField()
    private let label = UILabel()
    /// Called on every keystroke. The form keeps its draft up to date rather than reading the
    /// fields back at save time: a cell that scrolls out of view is dequeued and reused, and
    /// a form that read its values from cells would lose whatever the user typed above the
    /// fold.
    var onChange: ((String) -> Void)?
    /// What the field should be showing when it regains focus, asked at that moment.
    ///
    /// ⚠⚠ Exists for secure fields. `UITextField` blanks a secure field every time it becomes
    /// first responder — `clearsOnBeginEditing` is documented as ignored while
    /// `isSecureTextEntry` is set — and that programmatic clear fires no `editingChanged`. So
    /// a password typed, scrolled away from and tapped again showed empty while the form's
    /// draft still held it: the screen and the value about to be saved disagreed, in the one
    /// place this form is careful everywhere else to keep them together. Returning nil (the
    /// default) leaves the field alone.
    var restoreOnFocus: (() -> String?)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = .right
        field.addAction(
            UIAction { [weak self] _ in self?.onChange?(self?.field.text ?? "") }, for: .editingChanged
        )
        // Added once, here, not per configure: `addAction` accumulates, and a cell that
        // gained a handler on every dequeue would fire the same work N times.
        field.addAction(UIAction { [weak self] _ in
            guard let self, field.text?.isEmpty ?? true, let restored = restoreOnFocus?() else { return }
            field.text = restored
        }, for: .editingDidBegin)

        let stack = UIStackView(arrangedSubviews: [label, field])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .firstBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
        selectionStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func prepareForReuse() {
        super.prepareForReuse()
        // ⚠ Cleared explicitly. A dequeued cell keeps the last row's handler, and a reused
        // one firing the previous row's `onChange` writes the wrong field of the draft — a
        // bug that only shows on a form long enough to scroll.
        onChange = nil
        field.isSecureTextEntry = false
        field.keyboardType = .default
        field.autocapitalizationType = .sentences
        field.autocorrectionType = .default
        field.spellCheckingType = .default
        field.textContentType = nil
        field.clearsOnBeginEditing = false
        restoreOnFocus = nil
    }

    func configure(label text: String, value: String, placeholder: String? = nil) {
        label.text = text
        field.text = value
        field.placeholder = placeholder
        field.accessibilityLabel = text
    }

    /// Turn off the keyboard's helpfulness for a value that is not prose — a hostname, a
    /// nick, a SASL account. Autocapitalising a nick is how you end up connecting as
    /// "Amiantos" and wondering why nobody's highlights fire.
    func typedAsIdentifier(keyboard: UIKeyboardType = .default) {
        field.keyboardType = keyboard
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
    }
}

/// A label and a switch. What the settings screen builds by hand, minus the hand.
final class FormSwitchCell: UITableViewCell {
    static let reuseID = "form.switch"

    private let toggle = UISwitch()
    var onChange: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        toggle.addAction(
            UIAction { [weak self] _ in self?.onChange?(self?.toggle.isOn ?? false) }, for: .valueChanged
        )
        accessoryView = toggle
        selectionStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
    }

    func configure(label: String, isOn: Bool) {
        var content = defaultContentConfiguration()
        content.text = label
        contentConfiguration = content
        toggle.isOn = isOn
        toggle.accessibilityLabel = label
    }
}

/// A multi-line box for a value that is genuinely several lines — connect commands, and
/// nothing else so far. Grows with its content rather than scrolling inside a fixed height,
/// so the whole script is visible while it's being written.
final class FormTextViewCell: UITableViewCell, UITextViewDelegate {
    static let reuseID = "form.textview"

    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let titleLabel = UILabel()
    var onChange: ((String) -> Void)?
    /// Called when the intrinsic height changes, so the table can re-measure without a
    /// full reload — which would resign the keyboard mid-typing.
    var onHeightChange: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = false // the cell grows instead
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.delegate = self

        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0

        // ⚠ A real, visible label. Without one this is the only row in a form of labelled
        // rows with no name — an unlabelled box between two switches — and VoiceOver was
        // reading it out as its own placeholder, announcing the example script as if it were
        // the field's name.
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
        ])

        for view in [textView, placeholderLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
                view.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            ])
        }
        textView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor).isActive = true
        // Room for a couple of lines before anything is typed, so the row reads as a place
        // for several rather than as a one-line field that happens to wrap.
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        selectionStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        onHeightChange = nil
    }

    func configure(label: String, value: String, placeholder: String) {
        titleLabel.text = label
        textView.text = value
        placeholderLabel.text = placeholder
        placeholderLabel.isHidden = !value.isEmpty
        // The field's NAME, not its example. VoiceOver reads the placeholder as a hint of its
        // own accord; announcing it as the label left the box called "PRIVMSG NickServ…".
        textView.accessibilityLabel = label
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        onChange?(textView.text)
        onHeightChange?()
    }
}

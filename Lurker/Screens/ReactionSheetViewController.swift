// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The reaction sheet (iOS #183) — the web's `ReactModal`, shaped for a thumb.
///
/// Who reacted with what (the only place a touch screen can see that: the web names them in a
/// hover title), a row of quick picks, and a field for anything else — an emoji from the emoji
/// keyboard, which the field opens on, or plain text like "lol", which the spec allows and IRC
/// people actually use. Every choice toggles: picking a reaction you already gave takes it back.
///
/// Live, unlike the message actions sheet: it watches the store, so a reaction landing while it's
/// open shows up in the list instead of the sheet asserting an answer that has since moved.
final class ReactionSheetViewController: UIViewController, UITextFieldDelegate {

    private let viewModel: ChatViewModel
    private let message: Message
    private let networkId: Int?
    private let target: String
    private var cancellables = Set<AnyCancellable>()
    /// Choosing dismisses, and the buttons stay live through the animation — a second tap would
    /// send a second toggle, taking the first one straight back.
    private var hasChosen = false

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let standingStack = UIStackView()
    private let standingTitle = UILabel()
    private let quickRow = UIStackView()
    private let field = EmojiTextField()
    private let reactButton = UIButton(type: .system)
    private let fieldRow = UIStackView()
    private let problem = UILabel()
    private let offline = UILabel()

    private static let detent = UISheetPresentationController.Detent.Identifier("reactions")

    init(viewModel: ChatViewModel, message: Message, networkId: Int?, target: String) {
        self.viewModel = viewModel
        self.message = message
        self.networkId = networkId
        self.target = target
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        sheetPresentationController?.prefersGrabberVisible = true
        // Sized to what's in it, like the actions sheet: a few picks in a half-screen sheet is
        // mostly empty space, and the line you're reacting to is worth leaving in view.
        sheetPresentationController?.detents = [
            .custom(identifier: Self.detent) { [weak self] context in
                guard let self else { return context.maximumDetentValue }
                return min(preferredHeight, context.maximumDetentValue)
            },
            .large(),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 26, leading: 20, bottom: 20, trailing: 20)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])

        stack.addArrangedSubview(makeHeader())
        stack.setCustomSpacing(22, after: stack.arrangedSubviews[0])

        quickRow.axis = .horizontal
        quickRow.distribution = .fillEqually
        quickRow.spacing = 6
        stack.addArrangedSubview(quickRow)

        field.placeholder = "Any emoji or text"
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .send
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.delegate = self
        field.accessibilityLabel = "Reaction"
        field.addAction(UIAction { [weak self] _ in self?.typedChanged() }, for: .editingChanged)
        reactButton.configuration = .borderedProminent()
        reactButton.configuration?.title = "React"
        reactButton.isEnabled = false
        reactButton.setContentHuggingPriority(.required, for: .horizontal)
        reactButton.addAction(UIAction { [weak self] _ in self?.submitTyped() }, for: .touchUpInside)
        fieldRow.axis = .horizontal
        fieldRow.spacing = 8
        fieldRow.alignment = .center
        fieldRow.addArrangedSubview(field)
        fieldRow.addArrangedSubview(reactButton)
        stack.addArrangedSubview(fieldRow)
        stack.setCustomSpacing(6, after: fieldRow)

        problem.text = "That's longer than a reaction can be."
        problem.font = .preferredFont(forTextStyle: .footnote)
        problem.adjustsFontForContentSizeCategory = true
        problem.textColor = .systemRed
        problem.isHidden = true
        stack.addArrangedSubview(problem)

        offline.text = "This network can't carry reactions right now."
        offline.font = .preferredFont(forTextStyle: .subheadline)
        offline.adjustsFontForContentSizeCategory = true
        offline.textColor = .secondaryLabel
        offline.numberOfLines = 0
        stack.addArrangedSubview(offline)

        standingTitle.text = "Reactions"
        standingTitle.font = .preferredFont(forTextStyle: .footnote)
        standingTitle.adjustsFontForContentSizeCategory = true
        standingTitle.textColor = .secondaryLabel
        stack.addArrangedSubview(standingTitle)
        stack.setCustomSpacing(6, after: standingTitle)
        standingStack.axis = .vertical
        standingStack.spacing = 2
        stack.addArrangedSubview(standingStack)

        render(viewModel.state)
        viewModel.statePublisher
            .removeDuplicates { [networkId, key = BufferKey(networkId: networkId, target: target)] old, new in
                old.reactionsRevision(for: key) == new.reactionsRevision(for: key)
                    && old.canReact(networkId: networkId) == new.canReact(networkId: networkId)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(state) }
            .store(in: &cancellables)
    }

    /// Who you're reacting to and the line itself, so the sheet can't act on the wrong one
    /// without saying so — the job the actions sheet's header does too.
    private func makeHeader() -> UIView {
        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        let nick = message.nick ?? ""
        title.text = nick.isEmpty ? "React" : (message.isSelf ? "React to your message" : "React to \(nick)")
        let quote = UILabel()
        quote.font = .preferredFont(forTextStyle: .subheadline)
        quote.adjustsFontForContentSizeCategory = true
        quote.textColor = .secondaryLabel
        quote.textAlignment = .center
        quote.numberOfLines = 2
        quote.text = message.text.map { IRCFormatting.strip($0) }
        let header = UIStackView(arrangedSubviews: [title, quote])
        header.axis = .vertical
        header.spacing = 6
        return header
    }

    private func render(_ state: ChatState) {
        let canReact = canSend(state)
        let groups = state.reactionGroups(for: message.id)
        let mine = Set(groups.filter(\.mine).map(\.value))

        quickRow.isHidden = !canReact
        fieldRow.isHidden = !canReact
        offline.isHidden = canReact
        // Blame the right thing: a notice or an encrypted line can't take one on any network, and
        // sending someone off to look for a connection problem there would be a wild goose chase.
        offline.text = Reactions.lineTakes(message, target: target)
            ? "This network can't carry reactions right now."
            : "This line can't take reactions."
        if !canReact { problem.isHidden = true; field.resignFirstResponder() }
        for view in quickRow.arrangedSubviews { view.removeFromSuperview() }
        for value in Reactions.quickPicks {
            quickRow.addArrangedSubview(quickButton(value, mine: mine.contains(value)))
        }

        standingTitle.isHidden = groups.isEmpty
        for view in standingStack.arrangedSubviews { view.removeFromSuperview() }
        for group in groups {
            standingStack.addArrangedSubview(standingRow(group, canReact: canReact))
        }
        view.setNeedsLayout()
    }

    private func canSend(_ state: ChatState) -> Bool {
        Reactions.canSend(on: message, target: target, networkCanReact: state.canReact(networkId: networkId))
    }

    private func quickButton(_ value: String, mine: Bool) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = value
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .title3)
            return attributes
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        config.background.cornerRadius = 4
        config.background.strokeWidth = 1
        config.background.backgroundColor = mine
            ? Palette.translucent(Palette.accent, alpha: 0.15) : .secondarySystemGroupedBackground
        config.background.strokeColor = mine ? Palette.accent : .separator
        let button = UIButton(configuration: config)
        button.accessibilityLabel = value
        button.accessibilityTraits = mine ? [.button, .selected] : .button
        button.accessibilityHint = mine ? "Takes your reaction back." : nil
        button.addAction(UIAction { [weak self] _ in self?.choose(value) }, for: .touchUpInside)
        return button
    }

    /// One standing reaction: the value — whole, wrapping, the one place a long text reaction is
    /// shown in full — and everyone who gave it. Tapping it toggles yours.
    private func standingRow(_ group: ReactionGroup, canReact: Bool) -> UIView {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        config.background.cornerRadius = 4
        config.background.backgroundColor = group.mine
            ? Palette.translucent(Palette.accent, alpha: 0.12) : .secondarySystemGroupedBackground
        let body = UIFont.preferredFont(forTextStyle: .body)
        let line = NSMutableAttributedString(
            string: group.value,
            attributes: [.font: body, .foregroundColor: group.mine ? Palette.accent : UIColor.label]
        )
        line.append(NSAttributedString(
            string: "   " + group.nicks.joined(separator: ", "),
            attributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline), .foregroundColor: UIColor.secondaryLabel]
        ))
        config.attributedTitle = AttributedString(line)
        config.titleAlignment = .leading
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.isEnabled = canReact
        // Disabled reads as greyed out, which would make the list of who reacted look like an
        // error. It's still information — only the tap is gone.
        button.configurationUpdateHandler = { button in
            button.configuration?.attributedTitle = AttributedString(line)
        }
        let value = group.value
        button.addAction(UIAction { [weak self] _ in self?.choose(value) }, for: .touchUpInside)
        button.accessibilityLabel = "\(group.value), \(group.nicks.count): \(group.nicks.joined(separator: ", "))"
        button.accessibilityTraits = group.mine ? [.button, .selected] : .button
        return button
    }

    private var typedValue: String {
        (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func typedChanged() {
        let value = typedValue
        let tooLong = !value.isEmpty && !Reactions.isValidValue(value)
        problem.text = "That's longer than a reaction can be."
        problem.isHidden = !tooLong
        reactButton.isEnabled = !value.isEmpty && !tooLong
        view.setNeedsLayout()
    }

    private func submitTyped() {
        let value = typedValue
        guard Reactions.isValidValue(value) else { return }
        choose(value)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitTyped()
        return false
    }

    /// Toggle `value` and close. Re-checked against the store at the tap rather than trusted from
    /// whenever the buttons were drawn: the network may have dropped since.
    private func choose(_ value: String) {
        guard !hasChosen, canSend(viewModel.state), Reactions.isValidValue(value) else { return }
        guard viewModel.toggleReaction(messageId: message.id, value: value) else {
            // Nothing went out — no socket. Say so and stay, rather than closing on a reaction
            // that will never appear.
            problem.text = "Not connected — try again in a moment."
            problem.isHidden = false
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        hasChosen = true
        dismiss(animated: true)
    }

    // MARK: - Sizing

    private var measuredHeight: CGFloat = 320

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = stack.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        guard abs(height - measuredHeight) > 0.5 else { return }
        measuredHeight = height
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.invalidateDetents()
        }
    }

    /// A custom detent's height already excludes the home indicator's strip.
    private var preferredHeight: CGFloat { measuredHeight }
}

/// A text field that opens on the emoji keyboard, since that's what a reaction usually is — with
/// the globe key a tap away for "lol". Falls back to whatever the user had when they've no emoji
/// keyboard enabled.
final class EmojiTextField: UITextField {
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The join-a-channel form: a name to join, and — when there's a choice — which network to
/// join it on.
///
/// A form rather than the menu it replaced. A menu had to be *rebuilt* whenever the
/// networks changed, and the buffer switcher rebuilds on every unread count, so the item
/// was being swapped out from under an open menu. More to the point, a menu can only ask
/// one of the two questions: picking the network still landed you in an alert to type the
/// name, so the choice was split across two surfaces for no reason.
///
/// It reports the join through `onJoin` and doesn't know what happens next — the presenter
/// owns navigating to the new channel, the same contract as the switcher's `onSelect`.
final class JoinChannelViewController: UIViewController {
    /// The networks to offer, in the order they're shown. Never empty: the "+" that opens
    /// this is disabled when there's nowhere to join.
    private let networks: [Network]
    private var selected: Network

    /// Called with the network and the (prefixed) channel name.
    var onJoin: ((Network, String) -> Void)?

    private let field = UITextField()
    private let picker = UIPickerView()
    private lazy var joinButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: "Join", image: nil,
            primaryAction: UIAction { [weak self] _ in self?.submit() }, menu: nil
        )
        // The confirming action of the sheet, so it gets the weight iOS 26 gives one.
        item.style = .prominent
        return item
    }()

    init(networks: [Network]) {
        // Same order as everywhere else this app lists networks.
        self.networks = networks.sorted { $0.name.lowercased() < $1.name.lowercased() }
        // Force-unwrapped deliberately: an empty list is a programming error here, not a
        // state to render. See the doc comment.
        selected = self.networks[0]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Join Channel"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
        navigationItem.rightBarButtonItem = joinButton

        field.placeholder = "#channel"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .join
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .roundedRect
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.refreshJoinButton() }, for: .editingChanged)

        picker.dataSource = self
        picker.delegate = self

        let stack = UIStackView(arrangedSubviews: [field, networkView()])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let margins = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: margins.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor, constant: -20),
        ])

        refreshJoinButton()
    }

    /// The picker earns its space only when there's a choice to make. On a single network
    /// it's replaced by a line of text naming where the channel is going — the same fact,
    /// without a wheel whose only position is the one it's already on.
    private func networkView() -> UIView {
        guard networks.count > 1 else {
            let label = UILabel()
            label.text = "on \(selected.name)"
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            return label
        }
        return picker
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The name is the thing you came here to type; the network is a default you may
        // never touch.
        field.becomeFirstResponder()
    }

    /// Nothing to join until something is typed. Whitespace alone doesn't count, and
    /// neither does a bare sigil — `#` on its own would be prefixed into `#` and sent.
    private func refreshJoinButton() {
        joinButton.isEnabled = !typedChannel.isEmpty
    }

    private var typedChannel: String {
        let typed = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ChannelName.isPrefixed(typed) ? String(typed.dropFirst()) : typed
    }

    private func submit() {
        guard !typedChannel.isEmpty else { return }
        // `ensurePrefix` on what the user actually typed, not on `typedChannel` — the
        // latter has had its sigil stripped for the empty check, and re-prefixing it would
        // turn `&local` into `#local`.
        let channel = ChannelName.ensurePrefix((field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        onJoin?(selected, channel)
    }
}

// MARK: - Text field

extension JoinChannelViewController: UITextFieldDelegate {
    /// Return joins, so the common single-network case never needs the toolbar at all.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }
}

// MARK: - Network picker

extension JoinChannelViewController: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        networks.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        networks[row].name
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        selected = networks[row]
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// Screen 3: a buffer's messages, plus the input bar. Messages arrive two ways and
/// are treated identically: the `backlog` frame the server sends in reply to
/// `open-buffer`, and live `irc` frames after that — including the echo of our own
/// sends (`self: true`), which is why there's no optimistic-bubble bookkeeping here.
final class ChatViewController: UIViewController, UITableViewDataSource {
    private let client: LurkerClient
    private let buffer: Buffer

    private let tableView = UITableView()
    private let inputField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let inputBar = UIStackView()
    private var inputBarBottom: NSLayoutConstraint!

    private var messages: [Msg] = []

    init(client: LurkerClient, buffer: Buffer) {
        self.client = client
        self.buffer = buffer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = buffer.target

        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "msg")
        tableView.allowsSelection = false
        tableView.separatorStyle = .none
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        inputField.placeholder = "Message \(buffer.target)"
        inputField.borderStyle = .roundedRect
        inputField.autocorrectionType = .no
        inputField.delegate = self

        sendButton.setTitle("Send", for: .normal)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        inputBar.addArrangedSubview(inputField)
        inputBar.addArrangedSubview(sendButton)
        inputBar.axis = .horizontal
        inputBar.spacing = 8
        inputBar.isLayoutMarginsRelativeArrangement = true
        inputBar.directionalLayoutMargins = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        // The system buffer is read-only — there's nowhere to send it.
        inputBar.isHidden = buffer.networkId == nil
        view.addSubview(inputBar)

        inputBarBottom = inputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBarBottom,
        ])

        observeKeyboard()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Claim the callback — the buffer list also sets it, and whoever is on screen
        // owns it. Reclaimed on the way back in didMove(toParent:) below.
        client.onMessagesChanged = { [weak self] key in
            guard let self, key == self.buffer.key else { return }
            self.reload()
        }
    }

    private func reload() {
        messages = client.messages(for: buffer)
        tableView.reloadData()
        guard !messages.isEmpty else { return }
        tableView.scrollToRow(
            at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: false
        )
    }

    @objc private func send() {
        let text = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.send(buffer, text: text)
        inputField.text = ""
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // The safe-area inset is already accounted for by the constraint's anchor, so
        // subtract it or the bar floats above the keyboard by the home-indicator height.
        let overlap = view.bounds.maxY - frame.minY - view.safeAreaInsets.bottom
        inputBarBottom.constant = -max(0, overlap)
        view.layoutIfNeeded()
        if !messages.isEmpty {
            tableView.scrollToRow(
                at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: false
            )
        }
    }

    @objc private func keyboardWillHide() {
        inputBarBottom.constant = 0
        view.layoutIfNeeded()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "msg", for: indexPath)
        let msg = messages[indexPath.row]

        var content = cell.defaultContentConfiguration()
        let nick = msg.type == "action" ? "* \(msg.nick)" : msg.nick
        let line = NSMutableAttributedString(
            string: nick,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .subheadline).bold(),
                .foregroundColor: msg.isSelf ? UIColor.tintColor : UIColor.secondaryLabel,
            ]
        )
        line.append(NSAttributedString(
            string: "  \(msg.text)",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline)]
        ))
        content.attributedText = line
        cell.contentConfiguration = content
        return cell
    }
}

extension ChatViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        send()
        return false
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

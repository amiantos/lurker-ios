// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// Screen 3: a buffer's messages, plus the input bar. Messages arrive two ways and are
/// treated identically: the `backlog` frame the server sends in reply to `open-buffer`,
/// and live `irc` frames after that — including the echo of our own sends (`self: true`),
/// which is why there's no optimistic-bubble bookkeeping here. Only speech events
/// (message/action/notice) render; structural events (join/part/…) are #9.
final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let viewModel: ChatViewModel
    private let buffer: Buffer
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView()
    private let inputField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let inputBar = UIStackView()
    private var inputBarBottom: NSLayoutConstraint!

    /// A rendered row: a message, or the "new messages" divider.
    private enum Row {
        case message(Message)
        case unreadDivider
    }

    private var messages: [Message] = [] // filtered speech; drives anchoring + mark-read
    private var rows: [Row] = [] // messages + the unread divider; what the table renders
    /// The read boundary, snapshotted once when the buffer opens and held fixed for the
    /// visit — the divider must not jump as we mark messages read live.
    private var dividerAfterId = 0

    init(viewModel: ChatViewModel, buffer: Buffer) {
        self.viewModel = viewModel
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
        tableView.delegate = self
        tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "divider")
        tableView.allowsSelection = false
        tableView.separatorStyle = .none
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        // Snapshot the unread boundary once, on open, and hold it for the visit.
        dividerAfterId = viewModel.state.buffers[buffer.key.id]?.lastReadId ?? 0

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

        // Only re-render when this buffer's messages or the error actually change — a
        // frame for some other channel shouldn't reload this screen.
        let key = buffer.key.id
        viewModel.statePublisher
            .removeDuplicates { $0.messages[key] == $1.messages[key] && $0.error == $1.error }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // We're now looking at this buffer — mark it read up to the latest loaded message.
        viewModel.markRead(buffer.key)
    }

    private func apply(_ state: ChatState) {
        let updated = (state.messages[buffer.key.id] ?? []).filter { $0.type.isSpeech }
        let oldFirstId = messages.first?.id
        let newFirstId = updated.first?.id
        let wasNearBottom = isNearBottom
        let oldContentHeight = tableView.contentSize.height

        messages = updated
        rows = buildRows(from: updated)
        surface(state.error)
        // New traffic arrived while we're on screen → keep it marked read.
        if view.window != nil { viewModel.markRead(buffer.key) }

        // A history page prepended older messages above the viewport: reload, then shift
        // the content offset by exactly the added height so the rows you were reading stay
        // put instead of jumping.
        let prepended = oldFirstId != nil && newFirstId != nil && newFirstId! < oldFirstId!
        if prepended {
            UIView.performWithoutAnimation {
                tableView.reloadData()
                tableView.layoutIfNeeded()
                tableView.contentOffset.y += tableView.contentSize.height - oldContentHeight
            }
        } else {
            tableView.reloadData()
            // Follow live traffic only if you were already at the bottom; if you'd scrolled
            // up to read, a new message lands below without yanking you down.
            if wasNearBottom { scrollToBottom() }
        }
    }

    /// Interleave the unread divider before the first message past the read boundary.
    /// Only when there was a real read point (`dividerAfterId > 0`) and something unread —
    /// a brand-new buffer with nothing previously read shows no divider.
    private func buildRows(from messages: [Message]) -> [Row] {
        var result = messages.map(Row.message)
        if dividerAfterId > 0, let index = messages.firstIndex(where: { $0.id > dividerAfterId }) {
            result.insert(.unreadDivider, at: index)
        }
        return result
    }

    /// Within ~80pt of the bottom — treated as "following the conversation".
    private var isNearBottom: Bool {
        let fromBottom = tableView.contentSize.height - tableView.contentOffset.y - tableView.bounds.height
        return fromBottom < 80
    }

    // MARK: - UITableViewDelegate (pagination)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Near the top → pull older history. The view model guards `hasMoreOlder` and an
        // in-flight page, so firing this on every scroll tick is safe.
        guard !messages.isEmpty, scrollView.contentOffset.y < 300 else { return }
        viewModel.loadOlder(buffer.key)
    }

    /// A failed send (`send-result` ok:false) or a server `error` frame lands in
    /// `state.error`; surface it rather than losing it silently. Comprehensive error /
    /// empty / loading states across every screen are #19 — this is the send-failure
    /// case the composer must never swallow.
    private func surface(_ error: String?) {
        guard let error, presentedViewController == nil else { return }
        let alert = UIAlertController(title: nil, message: error, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.viewModel.clearError()
        })
        present(alert, animated: true)
    }

    private func scrollToBottom() {
        guard !rows.isEmpty else { return }
        tableView.scrollToRow(
            at: IndexPath(row: rows.count - 1, section: 0), at: .bottom, animated: false
        )
    }

    @objc private func send() {
        let text = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.send(buffer.key, text: text)
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
        scrollToBottom()
    }

    @objc private func keyboardWillHide() {
        inputBarBottom.constant = 0
        view.layoutIfNeeded()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .unreadDivider:
            return dividerCell()
        case .message(let message):
            return messageCell(message)
        }
    }

    private func messageCell(_ message: Message) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID) as! MessageCell
        cell.configure(MessageRenderer.render(message))
        return cell
    }

    private func dividerCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "divider")!
        var content = cell.defaultContentConfiguration()
        content.text = "New messages"
        content.textProperties.color = .systemRed
        let caption = UIFont.preferredFont(forTextStyle: .caption1)
        content.textProperties.font = caption.fontDescriptor.withSymbolicTraits(.traitBold)
            .map { UIFont(descriptor: $0, size: 0) } ?? caption
        content.textProperties.alignment = .center
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

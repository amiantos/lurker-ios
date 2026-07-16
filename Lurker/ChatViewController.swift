// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The app's one screen: a buffer's messages, plus the input bar. Messages arrive two ways
/// and are treated identically: the `backlog` frame the server sends in reply to
/// `open-buffer`, and live `irc` frames after that — including the echo of our own sends
/// (`self: true`), which is why there's no optimistic-bubble bookkeeping here.
///
/// This is the root of the navigation stack, not a pushed detail: the buffer list is a
/// sheet summoned from the title pill. So the stack is exactly one deep, always, and
/// switching buffers replaces the root rather than growing it.
final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let viewModel: ChatViewModel
    private let buffer: Buffer
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView()
    private let inputField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let inputBar = UIStackView()
    private var inputBarBottom: NSLayoutConstraint!
    private var titleButton: BufferTitleButton!

    /// A rendered row. A message is either dialogue (a bubble, carrying where it sits in
    /// its run) or narration (a full-width line) — see `EventType.isBubble`.
    private enum Row {
        case bubble(Message, RunPosition)
        case line(Message)
        case unreadDivider
    }

    private var messages: [Message] = [] // filtered to what this buffer renders; drives anchoring + mark-read
    private var rows: [Row] = [] // messages + the unread divider; what the table renders
    /// Network names, for labelling system lines with the network they're about.
    private var networks: [Int: Network] = [:]
    /// The read boundary, latched the first time the server tells us where it is and held
    /// fixed for the visit — the divider must not jump as we mark messages read live.
    ///
    /// Latched on first sight rather than read in `viewDidLoad`, because this screen is
    /// now built at launch, before the socket exists: read state hasn't arrived yet, and
    /// snapshotting it then would pin the boundary to 0 and suppress the divider for the
    /// whole session. `nil` means "not told yet", which is not the same as "nothing read".
    private var dividerAfterId: Int?
    /// Whether we've asked for this buffer's history on the *current* connection. Cleared
    /// when the socket drops, because a reconnect resyncs buffers as shells again.
    private var openRequested = false

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

        titleButton = BufferTitleButton(onTap: { [weak self] in self?.showBufferList() })
        navigationItem.titleView = titleButton
        navigationItem.leftBarButtonItem = overflowItem()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(promptJoin)
        )

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(BubbleCell.self, forCellReuseIdentifier: BubbleCell.reuseID)
        tableView.register(LineCell.self, forCellReuseIdentifier: LineCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "divider")
        tableView.allowsSelection = false
        tableView.separatorStyle = .none
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        inputField.placeholder = "Message \(displayName)"
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
        let composes = buffer.networkId != nil
        inputBar.isHidden = !composes
        view.addSubview(inputBar)

        inputBarBottom = inputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            // Pinned to the view, not the safe area, so messages scroll *under* the
            // floating title pill and its scroll edge effect. The table's automatic
            // content inset still keeps the first and last rows clear of the bars.
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Hiding the input bar doesn't reclaim its space — it's a plain subview, not
            // a stack's arranged one, so it keeps its intrinsic height and the table
            // would stop short of it. Skip it entirely when there's no composer, or the
            // system buffer (now the landing screen) ends in a band of dead space.
            tableView.bottomAnchor.constraint(equalTo: composes ? inputBar.topAnchor : view.bottomAnchor),

            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBarBottom,
        ])

        observeKeyboard()

        // Re-render when this buffer's messages or the error change — a frame for some
        // other channel shouldn't reload this screen. The title pill's light also depends
        // on the socket, the network path, and this buffer's network, so those count too.
        //
        // `buffers[key]` is in here for hydration, not for rendering: a shell arriving for
        // an empty buffer changes no messages, and dropping it as a duplicate would mean
        // never noticing we still owe this buffer an `open-buffer`.
        //
        // `networks` is compared whole rather than just this buffer's. The system buffer
        // has no network of its own, but its lines are labelled with the names of *other*
        // networks — and a name arrives later than the network does (the WS snapshot
        // creates it as "network", the REST roster fills the real name in without changing
        // the count). Anything narrower drops that update and leaves the labels wrong.
        let key = buffer.key.id
        viewModel.statePublisher
            .removeDuplicates {
                $0.messages[key] == $1.messages[key]
                    && $0.buffers[key] == $1.buffers[key]
                    && $0.error == $1.error
                    && $0.connection == $1.connection
                    && $0.reachable == $1.reachable
                    && $0.networks == $1.networks
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // We're now looking at this buffer — mark it read up to the latest loaded message.
        viewModel.markRead(buffer.key)
        // An error that landed before we had a window — or while the buffer list was
        // covering us — has nothing else coming to re-trigger it.
        surface(viewModel.state.error)
    }

    /// What the pill and the composer call this buffer. The system buffer is the app
    /// itself, so it's "Lurker" — its connection state used to be spelled out here as the
    /// title text ("Connecting…"), and is now the pill's light instead.
    private var displayName: String {
        switch buffer.kind {
        case .system: return "Lurker"
        case .server: return buffer.networkId.flatMap { networks[$0]?.name } ?? "Server"
        default: return buffer.target
        }
    }

    private func apply(_ state: ChatState) {
        networks = state.networks
        hydrateIfNeeded(state)
        // Latch the read boundary the first time the server tells us where it is, and
        // never again — marking messages read live must not move the divider under us.
        if dividerAfterId == nil, let known = state.buffers[buffer.key.id] {
            dividerAfterId = known.lastReadId
        }
        // Filter by what this *kind* of buffer renders. The system buffer's content is
        // entirely `type: "system"`, which isn't speech — a blanket `isSpeech` filter
        // (right for channels) left it permanently empty.
        let updated = (state.messages[buffer.key.id] ?? []).filter { buffer.kind.renders($0.type) }
        let oldFirstId = messages.first?.id
        let newFirstId = updated.first?.id
        let wasNearBottom = isNearBottom
        let oldContentHeight = tableView.contentSize.height

        messages = updated
        rows = buildRows(from: updated)
        updateTitle(state)
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

    /// Ask for history once the socket is up.
    ///
    /// Buffers arrive as shells (`events: []`) and aren't read until the client sends
    /// `open-buffer`. Picking a buffer from the list opens it on the way in, but this
    /// screen is also the *launch* screen, so it exists before there's a socket to ask
    /// over — and a reconnect resyncs it back to a shell. Both cases land here.
    private func hydrateIfNeeded(_ state: ChatState) {
        guard state.connection == .connected else {
            openRequested = false // a reconnect will resync this buffer as a shell
            return
        }
        guard !openRequested, let known = state.buffers[buffer.key.id], !known.hydrated else { return }
        openRequested = true
        viewModel.openBuffer(buffer.key)
    }

    private func updateTitle(_ state: ChatState) {
        titleButton.update(
            title: displayName,
            status: StatusLight.of(
                reachable: state.reachable,
                connection: state.connection,
                // A DM's light tracks its network, exactly like a channel's: real peer
                // presence is 1.1 (see StatusLight.of).
                network: buffer.networkId.flatMap { state.networks[$0]?.state }
            )
        )
    }

    /// Interleave the unread divider before the first message past the read boundary, and
    /// work out where each message sits in its run. Only when there was a real read point
    /// (`dividerAfterId > 0`) and something unread — a brand-new buffer with nothing
    /// previously read shows no divider.
    private func buildRows(from messages: [Message]) -> [Row] {
        // The divider is a hard run break: tightened corners across it would knit together
        // the very messages it's there to separate.
        let boundary = dividerAfterId ?? 0
        let dividerIndex = boundary > 0
            ? messages.firstIndex(where: { $0.id > boundary })
            : nil

        func continuesRun(at index: Int) -> Bool {
            guard index > 0, index != dividerIndex else { return false }
            return MessageGrouping.continuesRun(messages[index], after: messages[index - 1])
        }

        var result: [Row] = []
        for (index, message) in messages.enumerated() {
            if index == dividerIndex { result.append(.unreadDivider) }
            guard message.type.isBubble else {
                result.append(.line(message))
                continue
            }
            result.append(.bubble(message, RunPosition(
                isFirst: !continuesRun(at: index),
                isLast: index + 1 >= messages.count || !continuesRun(at: index + 1)
            )))
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
    ///
    /// Presented from whatever is actually on top, not from `self`. The buffer-list sheet
    /// is presented by the *navigation controller*, so our own `presentedViewController`
    /// reads nil while the sheet covers the screen — presenting on `self` there is
    /// dropped by UIKit, and since only the alert's OK clears `state.error`, the error
    /// would stick and its own repeat would then be swallowed as a duplicate.
    private func surface(_ error: String?) {
        guard let error, let root = view.window?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        // Already showing one, or the sheet is mid-dismiss and can't present — either way
        // `viewDidAppear` and the next state change both retry.
        guard !(top is UIAlertController), !top.isBeingDismissed else { return }
        let alert = UIAlertController(title: nil, message: error, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.viewModel.clearError()
        })
        top.present(alert, animated: true)
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

    // MARK: - Navigation

    /// The pill expands into the buffer list. A sheet, not a push: the list is a picker
    /// for this screen, not a place you go — so the stack never grows and there's no back
    /// chevron competing with the pill for the same job.
    private func showBufferList() {
        let viewModel = self.viewModel
        let nav = navigationController
        let list = BufferListViewController(viewModel: viewModel)
        // `nav` weakly: it holds the sheet, which holds the list, which holds this
        // closure — a strong capture would close that loop for as long as the sheet is up.
        list.onSelect = { [weak nav] buffer in
            // No `openBuffer` here: the new screen's own `hydrateIfNeeded` asks for the
            // history. Requesting it here too would double every buffer tap — the reply
            // hasn't landed by the time the new VC's first `apply` runs, so it would still
            // see `hydrated == false` and ask again, costing a second backlog read and a
            // second full reload.
            //
            // Swap the root *behind* the sheet, then dismiss, so it slides down onto the
            // buffer you picked instead of flashing the one you left.
            nav?.setViewControllers(
                [ChatViewController(viewModel: viewModel, buffer: buffer)], animated: false
            )
            nav?.dismiss(animated: true)
        }
        let sheet = UINavigationController(rootViewController: list)
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        // Presented from the navigation controller rather than from `self`, which is about
        // to be replaced as its root — a presenting VC deallocated mid-dismiss takes the
        // sheet down with it.
        nav?.present(sheet, animated: true)
    }

    // MARK: - Actions

    /// The overflow button, balancing "+" across the pill. A bare "…" means "there's a
    /// menu here" on iOS, so sign-out lives inside it rather than firing on tap — an
    /// unlabelled button that ends your session on one touch is a trap. It's also where
    /// the rest of Settings (#20) lands, which is why it's an ellipsis and not a door.
    private func overflowItem() -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIAction(
                    title: "Sign Out",
                    image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                    attributes: .destructive
                ) { [weak self] _ in
                    // Revokes server-side + clears the Keychain; SceneDelegate returns us
                    // to sign-in.
                    self?.viewModel.logout()
                },
            ])
        )
    }

    @objc private func promptJoin() {
        let networks = viewModel.networks.sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard !networks.isEmpty else { return }
        guard networks.count > 1 else { return presentJoinAlert(network: networks[0]) }
        let sheet = UIAlertController(title: "Join a channel on…", message: nil, preferredStyle: .actionSheet)
        for network in networks {
            sheet.addAction(UIAlertAction(title: network.name, style: .default) { [weak self] _ in
                self?.presentJoinAlert(network: network)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    private func presentJoinAlert(network: Network) {
        let alert = UIAlertController(title: "Join channel", message: "on \(network.name)", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "#channel"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Join", style: .default) { [weak self, weak alert] _ in
            self?.viewModel.joinChannel(networkId: network.id, channel: alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
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
        case .bubble(let message, let position):
            let cell = tableView.dequeueReusableCell(withIdentifier: BubbleCell.reuseID) as! BubbleCell
            cell.configure(message, position: position)
            return cell
        case .line(let message):
            let cell = tableView.dequeueReusableCell(withIdentifier: LineCell.reuseID) as! LineCell
            // A system line names the network it's about; everything else ignores this.
            let networkName = message.originNetworkId.flatMap { networks[$0]?.name }
            cell.configure(MessageRenderer.render(message, networkName: networkName))
            return cell
        }
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
        cell.backgroundColor = .clear
        return cell
    }
}

extension ChatViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        send()
        return false
    }
}

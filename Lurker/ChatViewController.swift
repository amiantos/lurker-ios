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
final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    UIGestureRecognizerDelegate {
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
    /// How far the timestamps are currently slid in. Held here, not per-cell, so a cell
    /// recycled mid-drag comes back at the same offset as its neighbors.
    private var reveal: CGFloat = 0
    private var revealPan: UIPanGestureRecognizer!
    /// Cleared once the buffer has been parked at its newest message.
    ///
    /// Opening a buffer has to land at the bottom, and neither obvious place to do it works
    /// alone. `viewDidLoad` is too early — the table has no height yet, and `scrollToRow` on
    /// a table with no height silently does nothing, which is exactly what happens for an
    /// already-hydrated buffer whose messages are in `state` before the screen exists: it
    /// asks once, is ignored, and nothing changes afterwards to ask again. And the first
    /// `apply` is not enough either, because the backlog can just as easily arrive *after*
    /// the first layout pass. So both paths ask and this makes it happen exactly once.
    private var needsInitialScroll = true

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

        titleButton = BufferTitleButton(onTap: { [weak self] in self?.showBufferInfo() })
        navigationItem.titleView = titleButton
        navigationItem.leftBarButtonItem = bufferListItem()
        navigationItem.rightBarButtonItem = overflowItem()

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
        addEdgeSwipes()

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
        // …and it's now the most recent, which is what the switcher promotes. Recorded on
        // appear rather than on the pick, so the launch buffer counts too and a buffer
        // reached any other way can't slip past the bookkeeping.
        UserPreferences.standard.recordRecentBuffer(buffer.key.id)
        // An error that landed before we had a window — or while the buffer list was
        // covering us — has nothing else coming to re-trigger it.
        surface(viewModel.state.error)
    }

    /// What the pill and the composer call this buffer. The system buffer's connection
    /// state used to be spelled out here as the title text ("Connecting…"); it's the pill's
    /// light now.
    private var displayName: String {
        buffer.displayName(networkName: buffer.networkId.flatMap { networks[$0]?.name })
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
        //
        // Only when you're actually reading up there. Scrolling up isn't the only thing
        // that makes the first id smaller — so does hydration, when a backlog replaces the
        // live events that outran it (your own echo, usually, which is why this looked like
        // "the last message is mine"). Shifting by a whole history's height throws the
        // offset clean past the end of the content, and a scroll view holds an out-of-range
        // offset until something touches it: a black buffer that snaps into place when you
        // poke it.
        //
        // Being at the bottom is what separates the two: preserving your position only
        // means anything if you have one to preserve. At the bottom, the bottom is it.
        let prepended = !wasNearBottom
            && oldFirstId != nil && newFirstId != nil && newFirstId! < oldFirstId!
        if prepended {
            UIView.performWithoutAnimation {
                tableView.reloadData()
                tableView.layoutIfNeeded()
                tableView.contentOffset.y += tableView.contentSize.height - oldContentHeight
                clampToContent()
            }
        } else {
            tableView.reloadData()
            // Follow live traffic only if you were already at the bottom; if you'd scrolled
            // up to read, a new message lands below without yanking you down.
            if wasNearBottom { scrollToBottom() }
        }
        landAtBottomIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The other half of the initial scroll: this is where an already-hydrated buffer
        // finally gets a height to scroll within.
        landAtBottomIfNeeded()
    }

    /// The one-shot landing. Needs both rows to scroll to and a height to scroll within,
    /// which arrive in either order.
    private func landAtBottomIfNeeded() {
        guard needsInitialScroll, !rows.isEmpty, tableView.bounds.height > 0 else { return }
        needsInitialScroll = false
        scrollToBottom()
    }

    /// Pull the offset back inside the content.
    ///
    /// A scroll view will hold an offset past the end of its content indefinitely and only
    /// clamps it once a touch starts a scroll — so an offset put there by arithmetic reads
    /// as an empty buffer that snaps into place the moment you poke it. Anything that moves
    /// the offset by computing it, rather than by asking the table to scroll somewhere, has
    /// to land back in range itself.
    private func clampToContent() {
        let insets = tableView.adjustedContentInset
        let maxY = max(-insets.top, tableView.contentSize.height + insets.bottom - tableView.bounds.height)
        if tableView.contentOffset.y > maxY {
            tableView.contentOffset.y = maxY
        }
    }

    /// Ask for history once the socket is up.
    ///
    /// Channel and DM buffers arrive as shells (`events: []`) and aren't read until the
    /// client sends `open-buffer`. This screen is also the *launch* screen, so it can exist
    /// before there's a socket to ask over — that's the case this covers.
    ///
    /// The system buffer and `:server:` logs are excluded rather than merely redundant:
    /// the server discards `open-buffer` for both without replying (see
    /// `BufferKind.hydratesOnDemand`), so asking would set `openRequested` on a request
    /// that can never be answered and wedge the screen waiting on it.
    private func hydrateIfNeeded(_ state: ChatState) {
        guard buffer.kind.hydratesOnDemand else { return }
        guard state.connection == .connected else {
            openRequested = false // a reconnect resyncs buffers, so ask again on the next one
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

    /// Park the newest message at the bottom.
    ///
    /// Scrolled twice, on purpose. Rows are self-sizing, so the first pass positions using
    /// *estimated* heights for the rows it hasn't laid out and stops short of the real
    /// bottom — the "opens a scroll above the newest message" symptom. Laying out and asking
    /// again lets the second pass use the heights the first one just made real.
    ///
    /// The height guard matters as much: `scrollToRow` against a table that has no bounds
    /// yet does nothing at all, quietly.
    private func scrollToBottom() {
        guard !rows.isEmpty, tableView.bounds.height > 0 else { return }
        let last = IndexPath(row: rows.count - 1, section: 0)
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: last, at: .bottom, animated: false)
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: last, at: .bottom, animated: false)
    }

    @objc private func send() {
        let text = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.send(buffer.key, text: text)
        inputField.text = ""
    }

    // MARK: - Navigation

    /// Swipe in from either edge to reach the two lists this screen sits between: buffers
    /// on the left, nicks on the right. Each edge has the matching bar item above it — the
    /// list button and the overflow menu's "Members" — so these are shortcuts to visible
    /// controls, not the only way in.
    ///
    /// The left edge is free to claim because this screen is the navigation stack's root,
    /// so there's no interactive pop gesture to collide with.
    private func addEdgeSwipes() {
        func edgeSwipe(_ edge: UIRectEdge, _ action: Selector) -> UIScreenEdgePanGestureRecognizer {
            let swipe = UIScreenEdgePanGestureRecognizer(target: self, action: action)
            swipe.edges = edge
            view.addGestureRecognizer(swipe)
            return swipe
        }
        _ = edgeSwipe(.left, #selector(swipedFromLeft))
        let rightEdge = edgeSwipe(.right, #selector(swipedFromRight))

        // Drag left anywhere to pull the timestamps in. This overlaps the right-edge swipe
        // — both are leftward drags — so it defers: starting at the edge opens the nick
        // list, starting anywhere else reveals times. An edge recognizer fails instantly
        // when the touch doesn't begin in its strip, so the wait costs nothing.
        revealPan = UIPanGestureRecognizer(target: self, action: #selector(revealPanned))
        revealPan.delegate = self
        revealPan.require(toFail: rightEdge)
        tableView.addGestureRecognizer(revealPan)
    }

    @objc private func revealPanned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .changed:
            // Leftward only, and it stops at the peek width rather than tracking the finger
            // off the screen.
            apply(reveal: min(max(-pan.translation(in: view).x, 0), TimestampReveal.maxOffset))
        case .ended, .cancelled, .failed:
            // Always springs back — this is a peek, not a mode you can get stuck in.
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                self.apply(reveal: 0)
            }
        default:
            break
        }
    }

    private func apply(reveal offset: CGFloat) {
        reveal = offset
        // Every kind of row reveals now, but what actually moves differs: our own bubbles
        // slide aside because they sit where the time is arriving, while a full-width line
        // holds still and lets the time come into the gutter it already reserves. Each cell
        // decides for itself — see `setReveal`.
        for case let cell as TimestampRevealing in tableView.visibleCells {
            cell.setReveal(offset)
        }
    }

    /// Claim the drag only when it's clearly a leftward horizontal one, so vertical scrolls
    /// still belong to the table.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === revealPan, let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
    }

    /// Run alongside the table's own pan rather than displacing it — a mostly-horizontal
    /// drag barely scrolls, and fighting the scroll recognizer would cost the flick.
    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func swipedFromLeft(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        // On `.began`, so the sheet starts coming as soon as the intent is unambiguous
        // rather than waiting for the finger to lift.
        guard recognizer.state == .began else { return }
        showBufferList()
    }

    @objc private func swipedFromRight(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        guard recognizer.state == .began else { return }
        showMemberList()
    }

    /// The buffer list. A sheet, not a push: the list is a picker for this screen, not a
    /// place you go — so the stack never grows and there's no back chevron competing with
    /// the bar items for the same job.
    private func showBufferList() {
        guard presentedViewController == nil, navigationController?.presentedViewController == nil else { return }
        let viewModel = self.viewModel
        let nav = navigationController
        let current = buffer.key
        let list = BufferSwitcherViewController(viewModel: viewModel, current: current)
        // `nav` weakly: it holds the sheet, which holds the list, which holds this
        // closure — a strong capture would close that loop for as long as the sheet is up.
        list.onSelect = { [weak nav] buffer in
            // Picking the buffer you're already in means "close this", not "rebuild it".
            // Swapping the root would re-latch the unread divider, re-request history, and
            // throw away your scroll position to arrive back exactly where you started.
            guard buffer.key != current else { return nav?.dismiss(animated: true) ?? () }
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

    /// What the pill opens: this buffer's own info, not a picker for a different one.
    /// Medium-height first, like the nick list — it's a glance about the conversation
    /// behind it, so it leaves that conversation on screen.
    private func showBufferInfo() {
        guard presentedViewController == nil, navigationController?.presentedViewController == nil else { return }
        let info = BufferInfoViewController(viewModel: viewModel, buffer: buffer)
        // Runs after this sheet has finished dismissing, so `showMemberList`'s guard sees a
        // clear screen.
        info.onShowMembers = { [weak self] in self?.showMemberList() }
        let sheet = UINavigationController(rootViewController: info)
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        present(sheet, animated: true)
    }

    /// The nick list. Presented from `self`, unlike the buffer switcher: nothing here
    /// replaces this screen, so there's no VC about to be deallocated under the sheet.
    private func showMemberList() {
        guard presentedViewController == nil, navigationController?.presentedViewController == nil else { return }
        let sheet = UINavigationController(
            rootViewController: MemberListViewController(viewModel: viewModel, buffer: buffer)
        )
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        // Medium first: a nick list is a glance, and half-height keeps the conversation
        // you're reading it against on screen behind it.
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        present(sheet, animated: true)
    }

    // MARK: - Actions

    /// The buffer list, on the leading side to agree with the left-edge swipe that already
    /// opens it — the button and the gesture on that edge now mean the same thing.
    private func bufferListItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "list.bullet"),
            primaryAction: UIAction { [weak self] _ in self?.showBufferList() }
        )
        item.accessibilityLabel = "Buffers"
        return item
    }

    /// The overflow button, balancing the buffer list across the pill. A bare "…" means
    /// "there's a menu here" on iOS, so nothing in it fires on tap — sign-out least of
    /// all, since an unlabelled button that ends your session on one touch is a trap.
    /// It's also where the rest of Settings (#20) lands, which is why it's an ellipsis
    /// and not a door.
    ///
    /// Deferred rather than built once here, because what belongs in it moves after
    /// `viewDidLoad`: networks connect and disconnect. A menu assembled at launch would
    /// still be offering the networks that existed then.
    private func overflowItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.overflowElements() ?? [])
                },
            ])
        )
        item.accessibilityLabel = "More"
        return item
    }

    private func overflowElements() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        if let join = joinElement() { actions.append(join) }
        // Channels only. A DM has nobody to list and never will, and the system buffer
        // isn't even on a network — the list would open empty by construction. The
        // right-edge swipe stays unconditional: a gesture you have to go looking for can
        // afford to land on an empty list, a row sitting in a menu can't.
        if buffer.kind == .channel {
            actions.append(UIAction(title: "Members", image: UIImage(systemName: "person.2")) { [weak self] _ in
                self?.showMemberList()
            })
        }
        let signOut = UIAction(
            title: "Sign Out",
            image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
            attributes: .destructive
        ) { [weak self] _ in
            // Revokes server-side + clears the Keychain; SceneDelegate returns us to
            // sign-in.
            self?.viewModel.logout()
        }
        // Inline sections, so sign-out sits below a divider instead of one slip of the
        // thumb away from "Members".
        guard !actions.isEmpty else { return [signOut] }
        return [
            UIMenu(options: .displayInline, children: actions),
            UIMenu(options: .displayInline, children: [signOut]),
        ]
    }

    /// Join lands here from the menu rather than owning a "+" of its own: it's a rare,
    /// deliberate act that was holding the most valuable slot on the bar.
    ///
    /// One network makes it a plain item, several make it a submenu, none omits it — the
    /// same three cases the old action sheet decided at tap time, now visible before you
    /// commit to a tap. Omitted rather than disabled on none, because there's nothing the
    /// user could do from here to make a greyed-out row work.
    private func joinElement() -> UIMenuElement? {
        let networks = viewModel.networks.sorted { $0.name.lowercased() < $1.name.lowercased() }
        let icon = UIImage(systemName: "plus.bubble")
        guard let only = networks.first else { return nil }
        guard networks.count > 1 else {
            return UIAction(title: "Join Channel…", image: icon) { [weak self] _ in
                self?.presentJoinAlert(network: only)
            }
        }
        return UIMenu(title: "Join Channel…", image: icon, children: networks.map { network in
            UIAction(title: network.name) { [weak self] _ in
                self?.presentJoinAlert(network: network)
            }
        })
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
            cell.configure(message, position: position, networkName: networkName(for: message))
            // Scrolled into view mid-drag: match the neighbors it's arriving next to.
            cell.setReveal(reveal)
            return cell
        case .line(let message):
            let cell = tableView.dequeueReusableCell(withIdentifier: LineCell.reuseID) as! LineCell
            cell.configure(MessageRenderer.render(message, networkName: networkName(for: message)), date: message.date)
            cell.setReveal(reveal)
            return cell
        }
    }

    /// What to call the network a nick-less line belongs to.
    ///
    /// Two sources, because two different lines need it: a system line is app-scoped and
    /// carries the network it's *about* in `originNetworkId`, while server text carries
    /// nothing and simply belongs to whichever server buffer we're looking at.
    private func networkName(for message: Message) -> String? {
        (message.originNetworkId ?? buffer.networkId).flatMap { networks[$0]?.name }
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

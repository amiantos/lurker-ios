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
    /// The floating "your connection is unhappy" capsule at the top — offline/connecting/
    /// reconnecting in words, the loud counterpart to the title pill's dot (#19).
    private let connectionBanner = ConnectionBanner()
    /// The empty/loading placeholder drawn behind an empty message list — the difference
    /// between "still fetching" and "genuinely nothing here", which a blank list conflates.
    private let placeholderView = StateView()
    private let composer = ComposerBar()
    private var composerBottom: NSLayoutConstraint!
    /// The floating "back to the newest message" pill (see `JumpToLatestButton`), and the
    /// count it badges: messages that landed while the reader was up in history. Reset the
    /// moment they're back at the bottom, however they got there.
    private let jumpButton = JumpToLatestButton()
    private var newWhileDetached = 0
    /// The completion pill strip and the context currently driving it (nil = nothing under
    /// the caret). The composer reports what *kind* of completion is live; this screen owns
    /// the candidates, because they come from state the bar never sees — the command table,
    /// the network's channels, this buffer's members.
    private let suggestions = SuggestionsView()
    private var activeCompletion: ComposerBar.Completion?
    /// How far the keyboard currently intrudes into the view, above the safe area — i.e.
    /// "is the keyboard actually up". The keyboard layout guide moves the composer; this
    /// only decides whether the breathing gap applies (see `keyboardWillChange`).
    private var keyboardOverlap: CGFloat = 0
    private var titleButton: BufferTitleButton!

    /// A rendered row. A message is either dialogue (a bubble, carrying where it sits in
    /// its run) or narration (a full-width line) — see `EventType.isBubble`. A run of
    /// consecutive membership churn collapses into a single `consolidated` summary line.
    private enum Row {
        case bubble(Message, RunPosition)
        case line(Message)
        case consolidated(ConsolidationSummary)
        case unreadDivider
    }

    private var messages: [Message] = [] // filtered to what this buffer renders; drives anchoring + mark-read
    private var rows: [Row] = [] // messages + the unread divider; what the table renders
    /// Network names, for labelling system lines with the network they're about.
    private var networks: [Int: Network] = [:]

    /// Colors known nicks mentioned in message bodies. Rebuilt only when this buffer's
    /// coloring set changes, since compiling the match regex is the costly part.
    private var nickHighlighter = NickHighlighter(nicks: [])
    private var highlighterNicks: [String] = []
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

    /// The message to open *at* rather than the bottom (#42) — a tapped highlight (later a
    /// notification, a search hit). The initial landing scrolls to it instead of the tail, and
    /// if it isn't already held the screen fetches an `around` slice centered on it first.
    /// Consumed once the landing scrolls to it, so it's a one-shot like `needsInitialScroll`.
    private var pendingJumpId: Int?
    /// Whether the `around` slice for `pendingJumpId` has been requested on this connection —
    /// same one-shot-per-connection shape as `openRequested`.
    private var aroundRequested = false
    /// Set once the requested `around` slice has landed, so the initial scroll can give up on
    /// a missing anchor (`anchorMissing`) and fall back to the bottom instead of waiting forever.
    private var aroundSliceArrived = false

    init(viewModel: ChatViewModel, buffer: Buffer, jumpTo: Int? = nil) {
        self.viewModel = viewModel
        self.buffer = buffer
        self.pendingJumpId = jumpTo
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
        // The iMessage dismissal: drag down through the conversation and the keyboard
        // tracks the finger once it reaches it, rather than snapping away. The composer
        // rides along because it's constrained to `keyboardLayoutGuide` (below), which
        // follows the keyboard through the interactive part of the gesture — the old
        // notification-driven constant only ever heard about the endpoints.
        tableView.keyboardDismissMode = .interactive
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        // Floats over the conversation just under the nav bar; touches pass through to the
        // messages beneath it (see `ConnectionBanner`).
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(connectionBanner)

        // Nick and mIRC colors are trait-keyed and adapt in place when redrawn, but a `/me`
        // marker is a baked image that can't — so on a light/dark switch, reconfigure the
        // visible rows to rebuild those markers. Reconfigure, not reloadData: it keeps the
        // scroll position instead of dropping the reader wherever a fresh reload lands.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.tableView.reconfigureRows(at: self.tableView.indexPathsForVisibleRows ?? [])
        }

        composer.placeholder = composerPlaceholder
        composer.onSend = { [weak self] text in self?.send(text) }
        // A grown composer reserves more space (via viewDidLayoutSubviews after this forces
        // the pass), and should carry the newest message up with it rather than letting the
        // growing field cover what you were just reading.
        composer.onHeightChange = { [weak self] in
            guard let self else { return }
            let wasNearBottom = isNearBottom
            view.layoutIfNeeded()
            if wasNearBottom { scrollToBottom() }
        }
        composer.translatesAutoresizingMaskIntoConstraints = false
        // Every buffer composes — the system buffer too, as the app's command console
        // (#355 on the web; commands themselves are #10 here). It just has nothing to
        // attach, so the paperclip goes and the field takes the width.
        composer.showsAttach = buffer.networkId != nil
        view.addSubview(composer)

        // The bottom counterpart of the fade the nav bar's scroll-edge effect gives the
        // top: declaring the composer as an element container over the table's bottom edge
        // has the system draw the same soft Liquid Glass fade under it, sized to the
        // composer's actual shape — and every buffer has a composer now, so every buffer
        // gets the fade.
        let bottomEdge = UIScrollEdgeElementContainerInteraction()
        bottomEdge.scrollView = tableView
        bottomEdge.edge = .bottom
        composer.addInteraction(bottomEdge)

        jumpButton.onTap = { [weak self] in self?.jumpToLatest() }
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(jumpButton)

        composer.onCompletion = { [weak self] completion in
            self?.activeCompletion = completion
            self?.updateSuggestions()
        }
        // A pick means different things per context: a command inserts its verb, a channel
        // or nick argument inserts that value, an `@`-mention inserts the nick with its
        // addressing suffix. The composer owns each insertion; this only routes to it.
        suggestions.onPick = { [weak self] suggestion in
            guard let self else { return }
            switch activeCompletion {
            case .command: composer.completeCommand(name: suggestion.value)
            case .channelArg, .nickArg: composer.completeArgument(value: suggestion.value)
            case .mention: composer.completeMention(with: suggestion.value)
            case nil: break
            }
        }
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(suggestions)

        // To the keyboard layout guide, not the safe area: at rest the guide's top *is*
        // the safe-area bottom, and with the keyboard up (or mid-drag — see
        // `keyboardDismissMode` above) it's the keyboard's top edge. One anchor covers
        // every position; the notifications below only add the breathing gap.
        composerBottom = composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            // Full height, under everything. The conversation scrolls beneath the floating
            // title pill at the top and the floating composer at the bottom, and off into
            // both safe areas — `updateBottomInset` reserves the composer's height as inset
            // so the newest message still clears it.
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Centered just below the nav bar — the safe-area top sits right under it, so
            // the capsule drops into the gap between the title pill and the conversation.
            connectionBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            connectionBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            connectionBanner.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            connectionBanner.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBottom,

            // Above the composer so it clears the newest message's landing zone, on the
            // trailing edge where Messages and Slack put theirs. Anchored to the composer,
            // so the keyboard carries both up together.
            jumpButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            jumpButton.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -12),

            // The suggestion pills: centered over the field for tap reach (the jump pill
            // owns the trailing edge), riding the composer for the same
            // keyboard-carries-both reason. The edge insets only bite on a title long
            // enough to need truncating.
            suggestions.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            suggestions.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            suggestions.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            suggestions.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
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

    /// Rebuild the nick highlighter when this buffer's coloring set changes — the channel's
    /// members (or the DM peer), minus our own nick, which a self-mention leaves in the body
    /// color rather than a palette color, matching the web.
    private func refreshHighlighter(_ state: ChatState) {
        let ownNick = buffer.networkId.flatMap { networks[$0]?.nick }?.lowercased()
        let candidates: [String]
        switch buffer.kind {
        case .channel: candidates = (state.members[buffer.key.id] ?? []).map(\.nick)
        case .dm: candidates = [buffer.target]
        default: candidates = []
        }
        let names = ownNick.map { own in candidates.filter { $0.lowercased() != own } } ?? candidates
        guard names != highlighterNicks else { return }
        highlighterNicks = names
        nickHighlighter = NickHighlighter(nicks: names)
    }

    /// What the pill calls this buffer. The system buffer's connection state used to be
    /// spelled out here as the title text ("Connecting…"); it's the pill's light now.
    private var displayName: String {
        buffer.displayName(networkName: buffer.networkId.flatMap { networks[$0]?.name })
    }

    /// What the empty field says: the network's name — the transport, the way iMessage
    /// captions its field "iMessage" or "Text Message" rather than the recipient, who is
    /// already named by the title pill. Re-read on every `apply`, because the snapshot
    /// creates networks as "network" and the REST roster fills real names in later.
    /// The system buffer is the app's own command console, so it invites one.
    private var composerPlaceholder: String {
        guard let networkId = buffer.networkId else { return "Type a command…" }
        return networks[networkId]?.name ?? "Message"
    }

    private func apply(_ state: ChatState) {
        networks = state.networks
        refreshHighlighter(state)
        hydrateIfNeeded(state)
        requestAroundIfNeeded(state)
        // Latch the read boundary the first time the server tells us where it is, and
        // never again — marking messages read live must not move the divider under us.
        if dividerAfterId == nil, let known = state.buffers[buffer.key.id] {
            dividerAfterId = known.lastReadId
        }
        // Filter by what this *kind* of buffer renders. The system buffer's content is
        // entirely `type: "system"`, which isn't speech — a blanket `isSpeech` filter
        // (right for channels) left it permanently empty.
        let updated = (state.messages[buffer.key.id] ?? [])
            .filter { buffer.kind.renders($0.type) && $0.isRenderable }
        let oldFirstId = messages.first?.id
        let newFirstId = updated.first?.id
        let wasNearBottom = isNearBottom
        let oldContentHeight = tableView.contentSize.height
        // Remember the line at the top of the viewport and exactly where it sits, *before*
        // the rows change under us. If this turns out to be a history prepend, we put that
        // same line back in the same place — which pins scroll position precisely, where the
        // old "shift by the content-height delta" could only approximate it (off-screen rows
        // self-size from an estimate, and consolidation can reshape the run at the boundary).
        let anchor = wasNearBottom ? nil : topVisibleAnchor()

        // What the jump pill badges: messages that landed below while the reader was up in
        // history. Appends only — the first id moving means the reader pulled older pages,
        // and a pure state change (connection, read counts, names) moves no count at all.
        if !wasNearBottom, newFirstId == oldFirstId, updated.count > messages.count {
            newWhileDetached += updated.count - messages.count
        }

        messages = updated
        rows = buildRows(from: updated)
        updateTitle(state)
        composer.placeholder = composerPlaceholder
        // A strip left open across new traffic re-ranks live: whoever just spoke is now
        // the most recent speaker, and a leaver stops being offered.
        updateSuggestions()
        surface(state.error)
        // Connection trouble spelled out (#19) — the loud counterpart to the title dot —
        // and, behind an empty list, whether we're still loading or genuinely have nothing.
        connectionBanner.update(ConnectionBannerState.of(reachable: state.reachable, connection: state.connection))
        updatePlaceholder(hasMessages: !updated.isEmpty, known: state.buffers[buffer.key.id])
        // New traffic arrived while we're on screen → keep it marked read.
        if view.window != nil { viewModel.markRead(buffer.key) }

        // Being at the bottom decides everything here: preserving your position only means
        // anything if you have one to preserve. At the bottom, the bottom is it — follow
        // live traffic. Anywhere else, whatever changed (older pages prepended, live
        // traffic appended, a run re-consolidated), the line being read goes back exactly
        // where it was: a bare reload re-estimates off-screen row heights and shoves the
        // viewport around, and that shove — on *appends*, not just prepends — is what made
        // the list lurch mid-read.
        // A jump landed the around slice: remember it so the landing can give up on a missing
        // anchor rather than wait forever.
        if aroundRequested, !updated.isEmpty { aroundSliceArrived = true }

        if pendingJumpId != nil {
            // A jump is pending — don't auto-scroll to the bottom; `landInitialIfNeeded` lands
            // on the anchor once its row exists (or falls back if the anchor never arrives).
            tableView.reloadData()
        } else if wasNearBottom {
            tableView.reloadData()
            scrollToBottom()
        } else {
            // The height-delta fallback is for prepends alone. The first id also gets
            // smaller on hydration, when a backlog replaces the live events that outran it
            // (your own echo, usually) — shifting by a whole history's height there throws
            // the offset clean past the end of the content, and a scroll view holds an
            // out-of-range offset until something touches it: a black buffer that snaps
            // into place when you poke it.
            let prepended = oldFirstId != nil && newFirstId != nil && newFirstId! < oldFirstId!
            UIView.performWithoutAnimation {
                tableView.reloadData()
                tableView.layoutIfNeeded()
                if let anchor, let index = rowIndex(containing: anchor.id) {
                    // Put the anchored line back at the same screen offset it had before.
                    let target = tableView.rectForRow(at: IndexPath(row: index, section: 0)).minY - anchor.offset
                    tableView.contentOffset.y = target
                } else if prepended {
                    // No line to anchor to (or it vanished) — fall back to the height delta.
                    tableView.contentOffset.y += tableView.contentSize.height - oldContentHeight
                }
                clampToContent()
            }
        }
        // After the landing, not before: the first apply reaches here with the offset
        // still at the top, and the pill would flash in for the frame before
        // `landInitialIfNeeded` parks the buffer at its newest message.
        landInitialIfNeeded()
        updateJumpButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The composer's height is only real after layout, so its reservation is set here —
        // every pass, which also catches rotation and Dynamic Type. Setting a scroll view's
        // contentInset doesn't invalidate this view's layout, so there's no feedback loop.
        updateBottomInset()
        // Extend the interactive-dismiss zone up past the composer: the drag should engage
        // when the finger reaches the *bar*, the way Messages' does, not only once it
        // touches the keyboard itself. Recomputed here because the bar grows with its text.
        view.keyboardLayoutGuide.keyboardDismissPadding = composer.bounds.height + Self.keyboardGap
        // The other half of the initial scroll: this is where an already-hydrated buffer
        // finally gets a height to scroll within.
        landInitialIfNeeded()
    }

    /// The one-shot landing. Needs both rows to scroll to and a height to scroll within, which
    /// arrive in either order. Lands at the bottom normally, or — for a jump (#42) — on the
    /// target message, waiting for its `around` slice to bring the row in before consuming the
    /// one-shot. If the slice comes back without the anchor (`anchorMissing`), it gives up and
    /// lands at the bottom rather than hanging at the top.
    private func landInitialIfNeeded() {
        guard needsInitialScroll, tableView.bounds.height > 0 else { return }
        if let anchor = pendingJumpId {
            if let index = rowIndex(containing: anchor) {
                needsInitialScroll = false
                pendingJumpId = nil
                scrollToRow(index)
            } else if aroundSliceArrived, !rows.isEmpty {
                // The slice landed but the anchor isn't in it — fall back to the bottom.
                needsInitialScroll = false
                pendingJumpId = nil
                scrollToBottom()
            }
            // else: still waiting for the around slice to arrive.
            return
        }
        guard !rows.isEmpty else { return }
        needsInitialScroll = false
        scrollToBottom()
    }

    /// Scroll a jumped-to message into the middle of the viewport and give it a brief warm
    /// pulse so the eye finds it among similar bubbles. Scrolls twice for the same reason
    /// `scrollToBottom` does — self-sizing rows settle their real heights on the first pass.
    private func scrollToRow(_ index: Int) {
        guard rows.indices.contains(index), tableView.bounds.height > 0 else { return }
        let path = IndexPath(row: index, section: 0)
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: path, at: .middle, animated: false)
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: path, at: .middle, animated: false)
        flashRow(at: path)
    }

    /// A gentle warm pulse behind the row, fading out — the "here it is" after a jump. The
    /// wash reuses the highlight color; it fades to clear (these cells never carry a fill).
    private func flashRow(at path: IndexPath) {
        guard let cell = tableView.cellForRow(at: path) else { return }
        cell.contentView.backgroundColor = Palette.highlightBubble
        UIView.animate(withDuration: 1.1, delay: 0.4, options: [.curveEaseOut]) {
            cell.contentView.backgroundColor = .clear
        }
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
        // A pending jump hydrates via an `around` slice centered on the target (see
        // `requestAroundIfNeeded`), not `open-buffer`'s latest backlog — asking for both would
        // double-fetch and the latest slice would fight the jump. Once the around slice lands
        // the buffer reads hydrated, so this stays a no-op afterwards.
        guard pendingJumpId == nil else { return }
        guard state.connection == .connected else {
            openRequested = false // a reconnect resyncs buffers, so ask again on the next one
            return
        }
        guard !openRequested, let known = state.buffers[buffer.key.id], !known.hydrated else { return }
        openRequested = true
        viewModel.openBuffer(buffer.key)
    }

    /// Fetch the `around` slice a jump needs (#42): a history window centered on `pendingJumpId`,
    /// so the target and its context land even when it's older than any backlog. Skipped when
    /// the message is already held (the fast path — a highlight in an open buffer just scrolls),
    /// and re-armed on reconnect like `hydrateIfNeeded`. Only channel/DM buffers hydrate on
    /// demand; a `:server:`/system jump has nothing to fetch and falls through to a plain scroll.
    private func requestAroundIfNeeded(_ state: ChatState) {
        guard let anchor = pendingJumpId, buffer.kind.hydratesOnDemand else { return }
        guard state.connection == .connected else {
            aroundRequested = false
            return
        }
        guard !aroundRequested else { return }
        // Already have the target? No fetch — the landing scrolls straight to it.
        if (state.messages[buffer.key.id] ?? []).contains(where: { $0.id == anchor }) { return }
        aroundRequested = true
        viewModel.loadAround(buffer.key, anchorId: anchor)
    }

    /// The placeholder currently installed, so a fresh `apply` on every live message
    /// doesn't rebuild the same `StateView` and reassign `backgroundView` unchanged.
    private var shownPlaceholder: BufferPlaceholder?

    /// Show a loading spinner or an empty-state placeholder behind an empty message list,
    /// or nothing when there are messages. Set as the table's `backgroundView`, so it sits
    /// behind the cells and the table hides it the instant there's a row to draw.
    private func updatePlaceholder(hasMessages: Bool, known: Buffer?) {
        let placeholder = BufferPlaceholder.of(
            hasMessages: hasMessages,
            hydrated: known?.hydrated ?? false,
            hydratesOnDemand: buffer.kind.hydratesOnDemand,
            bufferExists: known != nil
        )
        guard placeholder != shownPlaceholder else { return }
        shownPlaceholder = placeholder
        switch placeholder {
        case .none:
            tableView.backgroundView = nil
        case .loading:
            placeholderView.configure(.init(title: "Loading messages…", isLoading: true))
            tableView.backgroundView = placeholderView
        case .empty:
            placeholderView.configure(emptyStateModel)
            tableView.backgroundView = placeholderView
        }
    }

    /// The empty-state copy, per buffer kind — a just-joined channel and a fresh DM are
    /// different invitations, and the system/server buffers aren't conversations at all.
    private var emptyStateModel: StateView.Model {
        switch buffer.kind {
        case .channel:
            return .init(symbol: "text.bubble", title: "No messages yet",
                         subtitle: "Messages in \(buffer.target) will show up here.")
        case .dm:
            return .init(symbol: "text.bubble", title: "No messages yet",
                         subtitle: "Say hello to \(buffer.target).")
        case .server:
            return .init(symbol: "server.rack", title: "Nothing from the server yet")
        case .system:
            return .init(symbol: "sparkles", title: "Welcome to Lurker",
                         subtitle: "Run /commands to see what you can do.")
        }
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

    /// Turn the filtered message list into rows: collapse runs of membership churn into
    /// summary lines, interleave the unread divider before the first message past the read
    /// boundary, and work out where each surviving bubble sits in its run.
    ///
    /// The divider only shows when there was a real read point (`dividerAfterId > 0`) and
    /// something unread — a brand-new buffer with nothing previously read shows none. It is
    /// a hard break for *both* passes: consolidation must not span it (a run half-read and
    /// half-new would hide the new arrivals inside a summary), and neither may a bubble run
    /// (tightened corners across it would knit together the very messages it separates).
    private func buildRows(from messages: [Message]) -> [Row] {
        let boundary = dividerAfterId ?? 0
        let splitIndex = boundary > 0
            ? messages.firstIndex(where: { $0.id > boundary })
            : nil

        // Consolidate each side of the divider independently so a run never straddles it.
        let (before, after): ([Message], [Message]) = splitIndex.map {
            (Array(messages[..<$0]), Array(messages[$0...]))
        } ?? (messages, [])

        var rows: [Row] = []
        func appendConsolidated(_ slice: [Message]) {
            for row in Consolidation.consolidate(slice) {
                switch row {
                case .summary(let summary):
                    rows.append(.consolidated(summary))
                case .passthrough(let message):
                    rows.append(message.type.isBubble ? .bubble(message, .solo) : .line(message))
                }
            }
        }
        appendConsolidated(before)
        if splitIndex != nil { rows.append(.unreadDivider) }
        appendConsolidated(after)

        return withBubbleRuns(rows)
    }

    /// Second pass: fill in each bubble's `RunPosition` by looking at its neighbours. Only
    /// consecutive bubble rows group; a line, a summary, or the divider between two bubbles
    /// is a non-bubble neighbour and so breaks the run — exactly what we want.
    private func withBubbleRuns(_ rows: [Row]) -> [Row] {
        func bubble(at index: Int) -> Message? {
            guard rows.indices.contains(index), case .bubble(let message, _) = rows[index] else { return nil }
            return message
        }
        return rows.enumerated().map { index, row in
            guard case .bubble(let message, _) = row else { return row }
            let isFirst = !MessageGrouping.continuesRun(message, after: bubble(at: index - 1))
            let isLast = bubble(at: index + 1).map { !MessageGrouping.continuesRun($0, after: message) } ?? true
            return .bubble(message, RunPosition(isFirst: isFirst, isLast: isLast))
        }
    }

    // MARK: - Scroll anchoring across a history prepend

    /// The line at the top of the viewport and how far its top sits from the viewport's
    /// top edge, captured from the *current* layout. Restoring both after a reload pins the
    /// reading position, whatever the rows above re-estimate or re-consolidate to.
    private func topVisibleAnchor() -> (id: Int, offset: CGFloat)? {
        let viewportTop = tableView.contentOffset.y + tableView.adjustedContentInset.top
        guard let visible = tableView.indexPathsForVisibleRows?.sorted() else { return nil }
        for indexPath in visible {
            guard rows.indices.contains(indexPath.row), let id = rowAnchorId(rows[indexPath.row]) else { continue }
            let frame = tableView.rectForRow(at: indexPath)
            // The first row still showing below the viewport top is the one being read.
            if frame.maxY > viewportTop {
                return (id, frame.minY - tableView.contentOffset.y)
            }
        }
        return nil
    }

    /// A stable id to anchor a row by. A summary anchors on its *last* event, because a run
    /// only ever grows upward as older history loads — so its bottom id doesn't move.
    /// Ephemeral lines (id 0) can't be re-found after a reload, so they don't anchor.
    private func rowAnchorId(_ row: Row) -> Int? {
        let id: Int
        switch row {
        case .bubble(let message, _): id = message.id
        case .line(let message): id = message.id
        case .consolidated(let summary): id = summary.lastId
        case .unreadDivider: return nil
        }
        return id > 0 ? id : nil
    }

    /// The row that now represents message `id` — its own row, or the summary whose span
    /// covers it after a history page merged it into a consolidated run.
    private func rowIndex(containing id: Int) -> Int? {
        rows.firstIndex { row in
            switch row {
            case .bubble(let message, _): message.id == id
            case .line(let message): message.id == id
            case .consolidated(let summary): summary.firstId <= id && id <= summary.lastId
            case .unreadDivider: false
            }
        }
    }

    /// Within ~80pt of the bottom — treated as "following the conversation".
    private var isNearBottom: Bool {
        let fromBottom = tableView.contentSize.height - tableView.contentOffset.y - tableView.bounds.height
        return fromBottom < 80
    }

    // MARK: - UITableViewDelegate (pagination + the jump pill)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Back at the bottom — however you got there — means caught up: the badge counts
        // "new since you scrolled away", and you're not away anymore.
        if isNearBottom { newWhileDetached = 0 }
        updateJumpButton()
        // Near the top → pull older history. The view model guards `hasMoreOlder` and an
        // in-flight page, so firing this on every scroll tick is safe.
        guard !messages.isEmpty, scrollView.contentOffset.y < 300 else { return }
        viewModel.loadOlder(buffer.key)
    }

    /// The settle after `jumpToLatest`'s animated scroll: rows are self-sizing, so the
    /// animated pass positions with estimated heights and can stop short of the real
    /// bottom — the same reason `scrollToBottom` scrolls twice. Finish the job with it.
    /// Unconditional, because that jump is the only animated scroll this screen makes.
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollToBottom()
    }

    /// Visible whenever the reader is up in history; the badge only when something has
    /// arrived below since. Both derived, so it can run on every tick and every reload.
    private func updateJumpButton() {
        jumpButton.setVisible(!isNearBottom && !rows.isEmpty, animated: true)
        jumpButton.setNewCount(newWhileDetached)
    }

    /// Ride back down animated — it's a distance covered, not a teleport — then let
    /// `scrollViewDidEndScrollingAnimation` correct for the estimated heights.
    private func jumpToLatest() {
        guard !rows.isEmpty else { return }
        newWhileDetached = 0
        tableView.scrollToRow(at: IndexPath(row: rows.count - 1, section: 0), at: .bottom, animated: true)
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

    private func send(_ text: String) {
        let outcome = viewModel.send(buffer.key, text: text)
        composer.clear()
        // `/msg`/`/query` opened a DM and asked us to switch to it.
        if case .activate(let key) = outcome { navigate(to: key) }
    }

    /// Switch the whole screen to another buffer — what `/msg` and `/query` ask for once the
    /// DM is open. The same root-swap the buffer switcher does: no back chevron, no stack
    /// growth. The target may not be in state yet (a brand-new DM whose `open-buffer` reply
    /// is still in flight), so it's synthesized when absent, exactly like the system buffer.
    private func navigate(to key: BufferKey) {
        guard key != buffer.key else { return }
        let target = viewModel.state.buffers[key.id]
            ?? Buffer(networkId: key.networkId, target: key.target,
                      kind: BufferKind.of(networkId: key.networkId, target: key.target))
        navigationController?.setViewControllers(
            [ChatViewController(viewModel: viewModel, buffer: target)], animated: true
        )
    }

    /// Recompute the pill strip for the completion under the caret: command chips from the
    /// table, channel chips from this network's buffers, or nick chips ranked the web
    /// client's way (`NickCompletion`) — capped at four, best nearest the field (the strip
    /// reverses the list; see its doc).
    private func updateSuggestions() {
        switch activeCompletion {
        case .command(let query):
            suggestions.show(CommandRegistry.matching(query).map { Suggestion.command($0) })
        case .channelArg(let query):
            suggestions.show(channelCandidates(matching: query).map { Suggestion.channel($0) })
        case .nickArg(let query), .mention(let query):
            suggestions.show(nickCandidates(matching: query).map { Suggestion.nick($0) })
        case nil:
            suggestions.show([])
        }
    }

    /// Channels on this buffer's network whose name matches `query`, best-effort. Both sides
    /// are compared with a leading channel sigil stripped, so `/join li` still finds
    /// `#linux` — the `#` the user hasn't typed yet shouldn't hide it.
    private func channelCandidates(matching query: String, limit: Int = 4) -> [String] {
        let needle = ChannelName.fold(query)
        return viewModel.state.buffers.values
            .filter { $0.networkId == buffer.networkId && $0.kind == .channel }
            .map(\.target)
            .filter { ChannelName.fold($0).hasPrefix(needle) }
            .sorted { $0.lowercased() < $1.lowercased() }
            .prefix(limit)
            .map { $0 }
    }

    private func nickCandidates(matching query: String) -> [String] {
        NickCompletion.candidates(
            messages: messages,
            members: viewModel.state.members[buffer.key.id] ?? [],
            selfNick: buffer.networkId.flatMap { networks[$0]?.nick },
            query: query,
            isChannel: buffer.kind == .channel
        )
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

    /// The recent-highlights list. A full-height sheet — it's a reading surface, not a
    /// glance — presented from the navigation controller like the buffer switcher, because
    /// picking a highlight replaces this screen and a presenter deallocated mid-swap would
    /// take the sheet down with it. Tapping a highlight jumps to its buffer the same
    /// root-swap way `/msg` and the switcher do; landing at the bottom of that conversation
    /// (scrolling to the exact matched line is deferred to #42).
    private func showHighlights() {
        guard presentedViewController == nil, navigationController?.presentedViewController == nil else { return }
        let viewModel = self.viewModel
        let nav = navigationController
        let highlights = HighlightsViewController(viewModel: viewModel)
        highlights.onSelect = { [weak nav] item in
            let key = item.bufferKey
            // Root-swap to the buffer and jump to the matched line (#42) — even when it's the
            // buffer already on screen, since the point is to move to that message. The buffer
            // may not be in state (a channel since closed, or one whose row never materialized),
            // so synthesize it exactly like `navigate(to:)`; the new screen fetches an `around`
            // slice centered on the match and scrolls to it.
            let target = viewModel.state.buffers[key.id]
                ?? Buffer(networkId: key.networkId, target: key.target,
                          kind: BufferKind.of(networkId: key.networkId, target: key.target))
            nav?.setViewControllers(
                [ChatViewController(viewModel: viewModel, buffer: target, jumpTo: item.message.id)], animated: false
            )
            nav?.dismiss(animated: true)
        }
        let sheet = UINavigationController(rootViewController: highlights)
        sheet.navigationBar.prefersLargeTitles = true
        sheet.sheetPresentationController?.prefersGrabberVisible = true
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
        // App-scoped, not buffer-scoped: recent highlights span every network, so it belongs
        // here on every buffer rather than gated like Members.
        actions.append(UIAction(title: "Highlights", image: UIImage(systemName: "at")) { [weak self] _ in
            self?.showHighlights()
        })
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

    /// The gap the composer keeps above the keyboard, so the capsule doesn't sit flush on
    /// the key row the way Messages never does. Only applied when the keyboard is actually
    /// up — at rest the composer sits on the safe-area edge with no extra gap.
    private static let keyboardGap: CGFloat = 8

    /// The guide tracks the keyboard's actual edge — appearance, height changes, and the
    /// interactive drag the notifications never hear about — so this no longer moves the
    /// composer. It reads the frame only to learn whether a docked keyboard is up, applies
    /// the gap accordingly, and keeps the newest message above the arriving keyboard.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        keyboardOverlap = max(0, view.bounds.maxY - frame.minY - view.safeAreaInsets.bottom)
        composerBottom.constant = keyboardOverlap > 0 ? -Self.keyboardGap : 0
        // `layoutIfNeeded` moves the composer to its new position and, in the same pass,
        // runs `viewDidLayoutSubviews` → `updateBottomInset` against that fresh frame. So
        // the inset isn't recomputed here — doing it before layout would read the old frame.
        view.layoutIfNeeded()
        // Everything below is for the keyboard's ARRIVAL. This notification also fires at
        // the tail of a dismissal with the end frame off-screen — and scrolling there
        // yanks a reader who dragged the keyboard away mid-history back to the bottom.
        guard keyboardOverlap > 0 else { return clampToContent() }
        scrollToBottom()
        // The keyboard's arrival just parked the conversation at the bottom, so the jump
        // pill goes with it — stated here rather than left to the scroll's delegate tick,
        // which doesn't fire when the offset was already close enough to need no change.
        newWhileDetached = 0
        updateJumpButton()
    }

    @objc private func keyboardWillHide() {
        keyboardOverlap = 0
        composerBottom.constant = 0
        view.layoutIfNeeded() // re-runs updateBottomInset via viewDidLayoutSubviews
        // The composer's reservation just shrank. At the bottom that can strand the offset
        // past the new maximum — held there indefinitely, per `clampToContent` — while
        // mid-history it's a no-op. Never a scroll: position survives the dismissal.
        clampToContent()
    }

    /// Reserve room at the bottom of the conversation for the floating composer (and the
    /// keyboard, when it's up), so the newest message scrolls to just above the composer
    /// rather than behind it. This is the bottom counterpart to the automatic top inset the
    /// nav bar gets — without it the table would run its content under the composer with no
    /// way to see the last line.
    ///
    /// Measured from the composer's actual top rather than computed from its height, because
    /// the keyboard moves the composer and shrinks the safe area, and a frame reads both at
    /// once. The `- safeAreaInsets.bottom` cancels the safe-area inset the table's automatic
    /// adjustment has already added, so the reservation isn't double-counted — get that
    /// wrong and the last line sits half-under the composer.
    private func updateBottomInset() {
        let reserved = max(0, view.bounds.maxY - composer.frame.minY - view.safeAreaInsets.bottom)
        tableView.contentInset.bottom = reserved
        tableView.verticalScrollIndicatorInsets.bottom = reserved
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
            cell.configure(
                message, position: position, networkName: networkName(for: message),
                highlighter: nickHighlighter
            )
            // Scrolled into view mid-drag: match the neighbors it's arriving next to.
            cell.setReveal(reveal)
            return cell
        case .line(let message):
            let cell = tableView.dequeueReusableCell(withIdentifier: LineCell.reuseID) as! LineCell
            // A `/me` action is conversation and keeps the tight default; a status line is
            // narration and gets the block spacing that sets its run apart from the chat.
            let spacing = message.type.isActivity ? statusBlockSpacing(at: indexPath.row) : (top: 4, bottom: 4)
            cell.configure(
                MessageRenderer.render(message, traits: traitCollection), date: message.date,
                topInset: spacing.top, bottomInset: spacing.bottom, highlighted: message.matched
            )
            cell.setReveal(reveal)
            return cell
        case .consolidated(let summary):
            // A collapsed run is a full-width meta line like any other activity line, so it
            // rides the same cell — just rendered from the summary instead of one message.
            let cell = tableView.dequeueReusableCell(withIdentifier: LineCell.reuseID) as! LineCell
            let spacing = statusBlockSpacing(at: indexPath.row)
            cell.configure(MessageRenderer.renderConsolidation(summary), date: summary.date, topInset: spacing.top, bottomInset: spacing.bottom)
            cell.setReveal(reveal)
            return cell
        }
    }

    /// Vertical padding for a status line, by where it sits in a run of consecutive status
    /// rows. Like a bubble run, a status block opens a gap above its first line and below
    /// its last, but sits tight internally — so a cluster of joins/modes/topics reads as one
    /// block with air around it rather than as loose lines threaded through the conversation.
    private func statusBlockSpacing(at index: Int) -> (top: CGFloat, bottom: CGFloat) {
        let edge: CGFloat = 10, inner: CGFloat = 2
        return (
            top: isStatusRow(index - 1) ? inner : edge,
            bottom: isStatusRow(index + 1) ? inner : edge
        )
    }

    /// Whether the row at `index` is status narration — a consolidated summary or a
    /// standalone activity line (a join, mode, topic, …), but *not* a `/me` action, which is
    /// conversation and so breaks a status block rather than joining it.
    private func isStatusRow(_ index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        switch rows[index] {
        case .consolidated: return true
        case .line(let message): return message.type.isActivity
        case .bubble, .unreadDivider: return false
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


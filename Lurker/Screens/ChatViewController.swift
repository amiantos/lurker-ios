// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The app's one screen: a buffer's messages, plus the input bar. Messages arrive two ways
/// and are treated identically: the slice the server sends in reply to our hydrate,
/// and live `irc` frames after that — including the echo of our own sends
/// (`self: true`), which is why there's no optimistic-bubble bookkeeping here.
///
/// This is a *detail* pushed onto the buffer list, which is the navigation stack's root — so
/// it gets the back button and the interactive pop for free (#49). Switching buffers replaces
/// this screen rather than stacking another on top of it (see `UINavigationController
/// .showBuffer`), so the stack is exactly two deep whenever a buffer is open, never more.
final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let viewModel: ChatViewModel
    /// Readable from outside so navigation can tell "open this buffer" from "you're already
    /// in it" without rebuilding the screen to find out — see `showBuffer`.
    let buffer: Buffer
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
    /// The in-flight upload readout above the composer (#14) — phase, progress, and a cancel.
    private let uploadStatus = UploadStatusView()
    /// Retained across the async pick→compress→upload flow (the picker delegates need it kept
    /// alive) and, by living in a single slot, it enforces one attachment at a time.
    private var attachmentPicker: AttachmentPicker?
    /// The running upload, so the status view's cancel can tear it down.
    private var uploadTask: Task<Void, Never>?
    /// The floating "back to the newest message" pill (see `JumpToLatestButton`), and the
    /// count it badges: messages that landed while the reader was up in history. Reset the
    /// moment they're back at the bottom, however they got there.
    private let jumpButton = JumpToLatestButton()
    private var newWhileDetached = 0
    /// The floating "unread messages ↑" banner under the nav bar (#45), shown when this buffer
    /// opened with unreads sitting above the reader. Tapping it lands on the unread divider —
    /// scrolling to it if it's loaded, else jumping an `around` slice centered on the read
    /// boundary — and reading forward from there after-pages down to live.
    private let unreadBanner = UnreadBanner()
    /// Whether the buffer was detached (`hasMoreNewer`) as of the *previous* `apply`. Kept so
    /// after-paging appends (and the re-attach that flips detached→attached in one apply) never
    /// inflate the jump-to-latest badge — that count is live traffic only, and a detached buffer
    /// holds live out, so any growth there is history the reader deliberately pulled (#45).
    private var wasDetached = false
    /// The rule set the last `apply` rendered against, so this one can tell a genuine append
    /// from rows appearing or vanishing because the rules themselves moved. Identity is the
    /// whole comparison — see `IgnoreSet`. Nil until the first apply, which is correct: there
    /// is no previous render to have counted against.
    private var lastIgnores: IgnoreSet?
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

    /// The pill's light. Stored, unlike its title, because the state it comes from arrives by
    /// subscription and isn't kept — `updateTitle` is the one place it's recomputed. Amber
    /// until the first state lands: this screen is built before there's anything to ask.
    private var pillStatus: StatusLight = .warn

    private var messages: [Message] = [] // filtered to what this buffer renders; drives anchoring + mark-read
    private var rows: [MessageRow] = [] // messages + dividers; what the table renders
    /// Who the store says is composing here, as of the last apply or tick (#61).
    private var typists: [String] = []
    /// Whether the server has older history left for this buffer, as of the last apply.
    ///
    /// Starts true so an unhydrated buffer doesn't claim to have reached its beginning in the
    /// moment before its first page lands — "no more history" has to be something the server
    /// told us, not the absence of an answer. Same default the parser applies for the same
    /// reason (`FrameParser.swift:220`).
    private var hasMoreOlder = true
    /// Whether this buffer is detached — showing an `around` slice below the live tail (#42) —
    /// as of the last apply. Snapshotted rather than read live for the same reason as
    /// `settings` below: the typing ticker rebuilds rows with no `state` in hand.
    ///
    /// `isDetached` is the same fact read from the store on demand, for the paging and pill
    /// logic that runs outside a rebuild.
    private var hasMoreNewer = false
    /// The settings in force as of the last apply.
    ///
    /// Snapshotted alongside `typists` rather than read live inside `buildRows`, so every path
    /// that builds rows agrees on which state it's rendering. The sink is
    /// `.receive(on: .main)`, so `apply`'s argument is an instant behind `viewModel.state`; a
    /// live read would let one frame mix old messages with new consolidation rules, and would
    /// disagree with the dedupe predicate about which snapshot is authoritative. It also gives
    /// the typing ticker's `rebuildRows()` — which has no `state` to thread through — the same
    /// answer.
    private var settings = Settings()
    /// Your own away state for this buffer's network, as of the last apply (#68) — nil for a
    /// buffer that doesn't take presence markers.
    ///
    /// Snapshotted like `settings` above, and for the same reason: the typing ticker rebuilds
    /// rows with no `state` in hand, and both paths have to agree on what they're rendering.
    private var awayState: AwayState?
    /// Re-reads `typists` while anybody is typing.
    ///
    /// Needed because a typing entry's lease expires by the *clock*, not by a frame: the last
    /// thing a peer sends is `active`, and what happens next is nothing at all. Without a tick
    /// the line would sit there until some unrelated state change happened to redraw it. Runs
    /// only while someone is typing, so an idle buffer costs nothing.
    private var typingTicker: Timer?
    /// Our own outgoing composing state — decides *what* to send; this screen owns only the
    /// timer that asks it (see `OutgoingTyping`).
    private var outgoingTyping = OutgoingTyping()
    /// Fires once the draft has sat untouched long enough to downgrade `active` → `paused`.
    private var typingIdleTimer: Timer?
    /// Network names, for labelling system lines with the network they're about.
    private var networks: [Int: Network] = [:]
    /// Keeps the date-label observations removable (see `observeDateLabelInvalidation`).
    private var dateLabelObservers: [NSObjectProtocol] = []
    /// Lowercased nick → channel-mode glyph (`@`, `+`, …), for the author caption.
    ///
    /// Snapshotted per apply rather than looked up per row: `cellForRowAt` runs for every
    /// visible cell on every reload, and the glyph comes from the nicklist, not the message.
    /// Empty unless `look.nick.show_mode_prefix` is on — which it isn't by default — so the
    /// whole feature costs nothing until someone asks for it.
    private var modePrefixes: [String: String] = [:]
    /// Turns rows into cells. Stateless; kept as a property rather than made anew per row.
    private let listRenderer = MessageListRenderer()

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
    /// The snapshot burst during which this screen's one hydrate was sent, or nil if
    /// it hasn't asked (or its request has been voided). See `hydrateIfNeeded`.
    ///
    /// One optional rather than a bool plus a generation: two variables tracking one fact
    /// can disagree, and they did — a reset that cleared the bool but left the generation
    /// behind made the screen ask twice on the same burst and take two full backlogs for
    /// it.
    private var hydrateRequestedAtGeneration: Int?
    /// The in-flight `/join` waiting for its channel to materialize (see `awaitJoin`).
    /// At most one: a second `/join` supersedes the first rather than racing it.
    private var pendingJoinCancellable: AnyCancellable?
    /// Whether the store has ever held a real row for this buffer. Latches true and never
    /// clears — see `handleBufferDisappeared`, which uses it to tell "the row hasn't arrived
    /// yet" from "the row was taken away".
    private var sawBufferRow = false
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
    /// The one message id the ignore filter must not drop.
    ///
    /// A jump target is exempt for as long as this screen lives. You reach one by naming a
    /// specific message — a bookmark, a search hit, a notification tap — and the rules can
    /// have changed since (the feeds don't subscribe to live state, so an ignored line stays
    /// tappable there). Filtering it out would land the reader on a message that isn't drawn:
    /// the landing resolves its anchor against the RENDERED rows, so it would never resolve,
    /// `pendingJumpId` would never clear, and `hydrateIfNeeded`'s `guard pendingJumpId == nil`
    /// would keep the buffer from hydrating for the life of the screen.
    ///
    /// Set alongside every `pendingJumpId` assignment rather than by an observer on it — a
    /// `didSet` would not fire for the one in `init`, which is the notification-tap path.
    /// Outlives the landing that consumes `pendingJumpId`, so the row doesn't vanish from
    /// under the reader the instant they arrive on it.
    private var jumpExemptId: Int?
    /// The snapshot burst during which the `around` slice for `pendingJumpId` was requested,
    /// or nil if it hasn't been asked for. Same shape, and the same reasoning, as
    /// `hydrateRequestedAtGeneration`: a request written to a socket that is silently replaced
    /// is lost with `connection` never dipping, so a bool cleared only on disconnect would
    /// leave a jump waiting forever for a slice that cannot arrive.
    private var aroundRequestedAtGeneration: Int?
    /// Set once the requested `around` slice has landed, so the initial scroll can give up on
    /// a missing anchor (`anchorMissing`) and fall back to the bottom instead of waiting forever.
    private var aroundSliceArrived = false
    /// The message ids held when the `around` fetch was sent. The response *replaces* the slice,
    /// so the response has arrived once these are gone (or the anchor appears) — distinguishing
    /// it from the pre-existing connect backlog (unchanged) or a live append (keeps them), either
    /// of which used to be mistaken for the slice and make the jump give up early.
    private var aroundBaselineIds: Set<Int> = []
    /// Whether the buffer was already hydrated when the `around` fetch was sent. A history reply
    /// always flips a buffer hydrated, so a not-yet-hydrated buffer becoming hydrated is itself
    /// proof the response landed — which is how an empty `anchorMissing` reply (nothing to
    /// replace, no anchor to appear) is still recognized instead of hanging on the spinner.
    private var aroundWasHydrated = false
    /// True while the jump is converging on its anchor across runloops (see `convergeJump`), so
    /// a second `landInitialIfNeeded` (from an intervening apply or layout) doesn't start a
    /// competing chain.
    private var jumpConverging = false
    private var jumpConvergePass = 0
    /// Whether this jump should pulse the first UNREAD row (just below the divider) instead of
    /// its anchor. A jump-to-unread (#45) anchors on the last-read message — which sits *above*
    /// the marker — so flashing the anchor would highlight the wrong side of the seam; the
    /// reader's eye wants the first new line. Off for every other jump (a highlight/notification
    /// tap flashes the message it landed on). Consumed and cleared by `finishJump`.
    private var jumpFlashesFirstUnread = false
    /// How many runloops to re-scroll before settling. The first scroll usually lands the anchor
    /// already; a couple of extra passes correct the rare case where estimated off-screen heights
    /// left it slightly off.
    private static let jumpConvergePasses = 3

    init(viewModel: ChatViewModel, buffer: Buffer, jumpTo: Int? = nil) {
        self.viewModel = viewModel
        self.buffer = buffer
        self.pendingJumpId = jumpTo
        self.jumpExemptId = jumpTo
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Explicitly never, not `.automatic`: automatic *inherits* from the screen below,
        // which is the buffer list and its large title — leaving this screen a tall empty
        // band under a pill that is already the title.
        navigationItem.largeTitleDisplayMode = .never
        // No leading item: the navigation controller's own back button goes there, and the
        // buffer list it returns to is this screen's parent rather than a sheet it summons.
        navigationItem.rightBarButtonItem = overflowItem()

        tableView.dataSource = self
        tableView.delegate = self
        listRenderer.register(in: tableView)
        // The list's own backdrop, not the screen's: the composer, pill and banners above it stay
        // on the system background.
        tableView.backgroundColor = listRenderer.listBackground
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
        // messages beneath it (see `ConnectionBanner`). It shares that slot with the unread
        // banner and wins it, so its comings and goings re-decide who's on screen.
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        // Hopped to the next turn, not run inline: the banner's `update` is called from the
        // middle of `apply`, where `rows`/`dividerRow` have been rebuilt but the table hasn't
        // reloaded yet — deciding the unread banner against that mismatch reads visibility for
        // one row set with the indices of another.
        connectionBanner.onVisibilityChange = { [weak self] in
            DispatchQueue.main.async { self?.updateFloatingPills() }
        }
        view.addSubview(connectionBanner)

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
        composer.onDraftChange = { [weak self] draft in self?.draftChanged(draft) }
        composer.onAttach = { [weak self] in self?.presentAttachmentSources() }
        composer.onPasteImage = { [weak self] data, mime, name in
            self?.uploadPastedImage(data: data, mime: mime, filename: name)
        }
        composer.translatesAutoresizingMaskIntoConstraints = false
        // Every buffer composes — the system buffer too, as the app's command console
        // (#355 on the web; commands themselves are #10 here). It just has nothing to
        // attach, so the paperclip goes and the field takes the width.
        composer.showsAttach = buffer.networkId != nil
        view.addSubview(composer)

        uploadStatus.onCancel = { [weak self] in self?.cancelUpload() }
        uploadStatus.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(uploadStatus)

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

        unreadBanner.onTap = { [weak self] in self?.jumpToFirstUnread() }
        unreadBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(unreadBanner)

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

            // Up at the top, where it's pointing — the connection banner's slot, which the two
            // take turns in (see `updateFloatingPills`). Down at the bottom, up at the top: each
            // control sits on the edge it takes you to, and neither covers the newest message.
            unreadBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            unreadBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            unreadBanner.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            unreadBanner.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            // The suggestion pills: centered over the field for tap reach (the jump pill
            // owns the trailing edge), riding the composer for the same
            // keyboard-carries-both reason. The edge insets only bite on a title long
            // enough to need truncating.
            suggestions.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            suggestions.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            suggestions.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            suggestions.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),

            // Centered just above the composer, riding it up with the keyboard — the same
            // slot the suggestion pills use, which is fine because an upload and mid-token
            // completion never run at once.
            uploadStatus.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            uploadStatus.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            uploadStatus.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            uploadStatus.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
        ])

        observeKeyboard()
        observeDateLabelInvalidation()
        observeAppearanceInvalidation()
        addEdgeSwipes()

        // Re-render when this buffer's messages or the error change — a frame for some
        // other channel shouldn't reload this screen. The title pill's light also depends
        // on the socket, the network path, and this buffer's network, so those count too.
        //
        // `buffers[key]` is in here for hydration, not for rendering: a shell arriving for
        // an empty buffer changes no messages, and dropping it as a duplicate would mean
        // never noticing we still owe this buffer a hydrate.
        //
        // `networks` is compared whole rather than just this buffer's. The system buffer
        // has no network of its own, but its lines are labelled with the names of *other*
        // networks — and a name arrives later than the network does (the WS snapshot
        // creates it as "network", the REST roster fills the real name in without changing
        // the count). Anything narrower drops that update and leaves the labels wrong.
        let key = buffer.key.id
        let bufferKey = buffer.key
        // Captured by value like the keys above: the predicate outlives this call, and it
        // needs nothing from `self` that can change.
        let thisBuffer = buffer
        viewModel.statePublisher
            .removeDuplicates { old, new in
                // One instant for both sides, so the comparison can't disagree with itself
                // because a lease happened to lapse between the two reads.
                let now = Date()
                return old.messages[key] == new.messages[key]
                    && old.buffers[key] == new.buffers[key]
                    // Not about *this* buffer's contents, and that's exactly why it has to
                    // be here. When the buffer is absent, every field above is nil on both
                    // sides, so the update that flips the roster to settled — the burst's
                    // terminal frame — is identical by this predicate and gets dropped.
                    // `handleBufferDisappeared` then never learns that absence has become
                    // provable, and a screen opened BY KEY onto a closed buffer sits on
                    // "Loading messages…" forever. The absent case is the one that needs
                    // this update most, and it was the one guaranteed not to receive it.
                    && old.rosterSettled == new.rosterSettled
                    // Same reasoning as `rosterSettled`: `hydrateIfNeeded` re-arms on this,
                    // so filtering it out would hide the very update that lets a screen
                    // recover from a request lost with a replaced socket. Anything this
                    // screen makes a decision from has to be compared here.
                    && old.burstGeneration == new.burstGeneration
                    && old.error == new.error
                    && old.connection == new.connection
                    && old.reachable == new.reachable
                    // Also how an away/back change reaches the list (#68): the away state
                    // hangs off `Network`, so comparing networks whole covers it. Worth
                    // knowing before narrowing this arm — presence markers are exactly the
                    // kind of state that changes with nothing else changing alongside it,
                    // which is the trap typing and the mode glyph both fell into.
                    && old.networks == new.networks
                    // Typing is this buffer's only state that changes with nothing else
                    // changing alongside it — leave it out and every `typing` frame is
                    // dropped here as a duplicate and the line never appears (#61).
                    //
                    // Compared as the RENDERED list, not as the raw entries. A peer re-sends
                    // `active` every ~3s while they keep typing, and each one carries a fresh
                    // `expiresAt` — so comparing entries makes every refresh a change, and
                    // every refresh would run a full `apply`: consolidation over the entire
                    // loaded history, a `reloadData`, and the anchor-restore dance. With three
                    // people typing in a busy channel that's a table reload a second to draw
                    // a line that hasn't changed. The nick list is what's on screen.
                    && old.typists(in: bufferKey, now: now) == new.typists(in: bufferKey, now: now)
                    // Settings reshape the rows (consolidation on/off, its name cap) and
                    // arrive on their own, from another device or the bootstrap fetch — the
                    // same trap typing hit: leave it out and a change made on the web does
                    // nothing here until some unrelated frame happens to redraw (#65).
                    && old.settings == new.settings
                    // The author's mode glyph comes from the nicklist, so an op/deop changes
                    // what's on screen with no message alongside it — the same trap again.
                    //
                    // Compared as the DERIVED glyph map rather than as `members`, for the same
                    // reason typing compares its rendered list: `Member` carries `away`, and
                    // with away-notify on a busy channel that flips constantly. Comparing
                    // members outright would run a full rebuild — consolidation over all of
                    // history, a reload, the anchor restore — every time anyone stepped away.
                    // The map is empty (and both sides equal) while the setting is off, which
                    // is the default, so this costs nothing until someone turns it on.
                    && Self.modePrefixes(for: old, buffer: thisBuffer)
                        == Self.modePrefixes(for: new, buffer: thisBuffer)
                    // Ignore rules decide which of `messages` actually renders and which of
                    // them highlight, and they arrive on their own from another device — the
                    // same trap settings and typing hit. Without this an `/ignore` typed in a
                    // browser changes nothing on screen until the next message happens to
                    // arrive, and the `/unignore` that should bring lines back does nothing
                    // visible at all. (`===` is the right test — see `IgnoreSet`.)
                    && old.ignores === new.ignores
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
        // …and it's now the most recent, which is what the list promotes. Recorded on
        // appear rather than on the pick, so the launch buffer counts too and a buffer
        // reached any other way can't slip past the bookkeeping.
        UserPreferences.standard.recordRecentBuffer(buffer.key.id)
        // …and it's where a relaunch should land (#49). Same moment, same reason: whatever
        // route brought you here, this is the buffer you were last looking at.
        UserPreferences.standard.recordLastBuffer(buffer.key)
        // An error that landed before we had a window — or while a sheet was covering us —
        // has nothing else coming to re-trigger it.
        surface(viewModel.state.error)
    }

    /// Backing out to the list means the *list* is where you were, not this buffer. Without
    /// this the restore target could only ever be a chat screen: leave a conversation on
    /// purpose, quit, and the next launch shoves you straight back into it, which is the one
    /// move a home screen is supposed to make unnecessary.
    ///
    /// Gated on the list being what we're uncovering — the stack is already updated by the
    /// time this runs — so a buffer *swap* (`/msg`, a notification tap, a highlight) doesn't
    /// trip it, and a cancelled interactive pop re-records on the `viewDidAppear` that follows.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving with a half-written draft shouldn't leave the channel thinking you're still
        // mid-sentence for the next 30 seconds. Unconditional — unlike the restore-target
        // bookkeeping below, this applies however you left, including a buffer swap.
        endTyping()
        guard isMovingFromParent, navigationController?.topViewController is BufferListViewController else {
            return
        }
        UserPreferences.standard.forgetLastBuffer()
    }

    deinit {
        // Timers hold this screen alive until they fire; a buffer swap replaces it, so without
        // this a `repeats: true` ticker would keep an off-screen controller (and its state
        // subscription) resident until someone stopped typing.
        typingTicker?.invalidate()
        typingIdleTimer?.invalidate()
        // Block-based observers aren't auto-removed the way the selector-based ones are.
        dateLabelObservers.forEach(NotificationCenter.default.removeObserver)
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

    /// Leave this screen when the buffer it is showing isn't open any more.
    ///
    /// `ChatState` drops buffer rows in four places, and all of them should take the reader
    /// off a buffer screen: `buffer-closed` (another device closed it), `removeBuffer` (this
    /// device did), `pruneToBurst` (a reconnect revealed a close we slept through), and
    /// `reset()` on sign-out — which is handled by SceneDelegate instead, see below.
    ///
    /// Absence alone is not the trigger, because absence is also the normal state early on:
    /// `state.buffer(for:)` synthesizes an empty row so a screen reached by *key* can exist
    /// before its `backlog` frame lands, and popping on that would bounce every cold launch
    /// back to the list. It takes one of the two proofs in the guard below.
    ///
    /// Returns true when `apply` should stop — which is broader than "it popped". It is also
    /// true when this screen is on its way out by some other route: a sign-out that
    /// SceneDelegate is already handling, or a pop already in flight. In every one of those
    /// cases the rest of `apply` would read `state.messages[key]`, find it empty, and repaint
    /// the screen blank on the way out, so the caller wants to stop regardless of who is
    /// doing the leaving.
    private func handleBufferDisappeared(_ state: ChatState) -> Bool {
        guard state.buffers[buffer.key.id] != nil else {
            // Two ways to know the buffer isn't coming:
            //
            //  - We held a row and it was taken away (a close, live or reconciled).
            //  - We never held one, but the roster is settled — so the server has now
            //    listed everything it has and this key wasn't in it (§4.3, lurker #635).
            //
            // The second is the whole point of `backlog-complete`, and without it this
            // screen still spins forever on exactly the case commit 2 is about: arriving
            // BY KEY (launch restore, notification tap) at a buffer that was closed while
            // the phone was away. `sawBufferRow` never becomes true there, because the row
            // never existed on this run.
            guard sawBufferRow || state.rosterSettled else { return false }
            // Sign-out empties `buffers` too, via `store.reset()`. Leave that case entirely
            // to SceneDelegate, which swaps the whole stack for the login screen — popping
            // here as well would run two stack transitions at once. `logout()` sets
            // `sessionSubject.value` synchronously *before* the state sink is delivered on
            // main, so this reads the new session, not the stale one.
            guard viewModel.session == .loggedIn else { return true }
            // Already on the way out (a pop in flight, or the list is showing) — don't
            // stack a second one.
            guard navigationController?.topViewController === self else { return true }
            // Sheets are presented by the navigation controller, so popping this screen
            // doesn't take them with it — a nick list or buffer-info sheet would be left
            // stranded over the buffer list, still bound to a buffer that no longer exists.
            // (This is what `showMemberList`'s "nothing replaces this screen" reasoning
            // assumed couldn't happen; it can now.) Same guard SceneDelegate uses.
            navigationController?.dismiss(animated: false)
            navigationController?.popToRootViewController(animated: true)
            return true
        }
        sawBufferRow = true
        return false
    }

    private func apply(_ state: ChatState) {
        if handleBufferDisappeared(state) { return }
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
        // The render-time ignore filter (lurker #301) sits on top of the kind/renderable one:
        // hidden lines drop out, and a NOHIGHLIGHT-covered line loses its mention wash. At
        // render rather than on the way into the store, which is what makes a rule retroactive
        // both ways — one made in a browser hides backlog the server had already sent, and
        // removing it brings those lines straight back with no refetch.
        let updated = state.ignores.visible(
            (state.messages[buffer.key.id] ?? [])
                .filter { buffer.kind.renders($0.type) && $0.isRenderable },
            networkId: buffer.networkId,
            target: buffer.target,
            keeping: jumpExemptId
        )
        let oldFirstId = messages.first?.id
        let newFirstId = updated.first?.id
        let wasNearBottom = isNearBottom
        let oldContentHeight = tableView.contentSize.height
        // Remember the line at the top of the viewport and exactly where it sits, *before*
        // the rows change under us. If this turns out to be a history prepend, we put that
        // same line back in the same place — which pins scroll position precisely, where the
        // old "shift by the content-height delta" could only approximate it (off-screen rows
        // self-size from an estimate, and consolidation can reshape the run at the boundary).
        let anchors = wasNearBottom ? [] : visibleAnchors()

        // What the jump pill badges: live messages that landed below while the reader was up
        // in history. Appends only — the first id moving means the reader pulled older pages,
        // and a pure state change (connection, read counts, names) moves no count at all.
        //
        // Excluded when the buffer is (or just was) detached: a detached buffer holds live
        // traffic out of the log, so anything appended there is a newer-history page the reader
        // pulled by scrolling down (#45), not a surprise from below. `wasDetached` covers the
        // re-attach apply too, where the final `after` page both appends and clears the flag.
        let nowDetached = state.buffers[buffer.key.id]?.hasMoreNewer == true
        // Sat out entirely on the frame the rules changed: an `/unignore` restores rows
        // *throughout* the loaded window, which is a count increase that nothing arrived to
        // cause. Counting it announced "12 new" for a conversation that hadn't moved, and
        // then sampled the wrong twelve rows to classify.
        let rulesChanged = lastIgnores !== state.ignores
        lastIgnores = state.ignores
        if !wasNearBottom, !wasDetached, !nowDetached, !rulesChanged, newFirstId == oldFirstId {
            // Counted by id rather than by how much longer the array got. The two agree for a
            // plain append and disagree for everything else — a restored row lands in the
            // middle, and `suffix(delta)` would then measure the tail, which is neither the
            // rows that appeared nor the same number of them.
            //
            // Ephemerals (id 0) are excluded: a `/e2e` status line or a local command echo is
            // not something the reader is missing below.
            let previousTail = messages.last(where: { $0.id != 0 })?.id ?? 0
            let appended = updated.filter { $0.id > previousTail }
            // Count what the reader will actually SEE arrive. At the `none` tier (#666) a
            // netsplit rejoin appends dozens of rows that build to nothing, and counting
            // them raw advertises "40 new" on a pill that jumps to a bottom looking exactly
            // like the top. The badge is still approximate under consolidation — a run of
            // 40 folds to one summary line — but that overcounts things that exist, which
            // is a different kind of wrong from counting things that don't.
            let mode = EventFilter.rendered(EventFilter.mode(state.settings))
            newWhileDetached += mode == .none
                ? appended.count { !EventFilter.isNoise($0.type) }
                : appended.count
        }

        messages = updated
        typists = state.typists(in: buffer.key)
        settings = state.settings
        awayState = Self.awayState(for: state, buffer: buffer)
        // Covered by the `old.buffers[key] == new.buffers[key]` arm of the dedupe predicate,
        // so a buffer whose only change is exhausting its history still reaches us.
        hasMoreOlder = state.buffers[buffer.key.id]?.hasMoreOlder ?? true
        hasMoreNewer = nowDetached
        modePrefixes = Self.modePrefixes(for: state, buffer: buffer)
        rebuildRows()
        updateTypingTicker()
        updateTitle(state)
        composer.placeholder = composerPlaceholder
        // A strip left open across new traffic re-ranks live: whoever just spoke is now
        // the most recent speaker, and a leaver stops being offered.
        updateSuggestions()
        surface(state.error)
        // Connection trouble spelled out (#19) — the loud counterpart to the title dot —
        // and, behind an empty list, whether we're still loading or genuinely have nothing.
        connectionBanner.update(ConnectionBannerState.of(reachable: state.reachable, connection: state.connection))
        // Keyed off the BUILT rows, not the raw messages — `hasMessages` means "any
        // renderable line is already on screen", and since the `none` event tier (#666)
        // those two can disagree. A quiet channel whose only stored rows are joins and mode
        // changes has messages but builds to nothing; reading `updated` there reports
        // content, suppresses the placeholder, and leaves the reader on a completely blank
        // screen with no empty-state and no spinner — and nothing to scroll, so no paging
        // fires to correct it. Runs after `rebuildRows()` above, so `rows` is current.
        //
        // The top-up runs first and reports whether it asked for more, so a window filtered
        // down to nothing says "Loading messages…" rather than claiming the buffer is empty
        // while a page is on its way to prove otherwise.
        let toppingUp = topUpIfFilteredEmpty(state)
        updatePlaceholder(
            hasMessages: !rows.isEmpty,
            known: state.buffers[buffer.key.id],
            forceLoading: toppingUp
        )
        // New traffic arrived while we're on screen → keep it marked read.
        if view.window != nil { viewModel.markRead(buffer.key) }

        // Being at the bottom decides everything here: preserving your position only means
        // anything if you have one to preserve. At the bottom, the bottom is it — follow
        // live traffic. Anywhere else, whatever changed (older pages prepended, live
        // traffic appended, a run re-consolidated), the line being read goes back exactly
        // where it was: a bare reload re-estimates off-screen row heights and shoves the
        // viewport around, and that shove — on *appends*, not just prepends — is what made
        // the list lurch mid-read.
        // The around response has landed once the messages we held at request time are gone
        // (it replaces the slice) or the anchor itself shows up — NOT merely because the buffer
        // has *some* messages (a pre-existing connect backlog would trip that and make the jump
        // give up before its real slice arrives). A live append keeps the baseline, so it
        // doesn't count either.
        if aroundRequestedAtGeneration != nil, !aroundSliceArrived {
            let currentIds = Set((state.messages[buffer.key.id] ?? []).map(\.id))
            let replaced = !aroundBaselineIds.isEmpty && !aroundBaselineIds.isSubset(of: currentIds)
            let anchorPresent = pendingJumpId.map { currentIds.contains($0) } ?? false
            // A fresh (unhydrated) buffer flipping hydrated is the reply landing even when it's
            // empty (anchorMissing) — otherwise that case never resolves and hangs the spinner.
            let becameHydrated = !aroundWasHydrated && state.buffers[buffer.key.id]?.hydrated == true
            if replaced || anchorPresent || becameHydrated { aroundSliceArrived = true }
        }

        if pendingJumpId != nil || needsInitialScroll {
            // A landing is pending — an initial open, a jump to an anchor (#42), or a re-attach
            // to the tail. Don't auto-scroll here; `landInitialIfNeeded` does the placement once
            // the rows and a height exist.
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
                // The first captured line that still has a row — see `visibleAnchors`.
                let survivor = anchors.lazy
                    .compactMap { anchor in
                        self.rowIndex(containing: anchor.id).map { ($0, anchor.offset) }
                    }
                    .first
                if let (index, offset) = survivor {
                    // Put the anchored line back at the same screen offset it had before.
                    let target = tableView.rectForRow(at: IndexPath(row: index, section: 0)).minY - offset
                    tableView.contentOffset.y = target
                } else if prepended || tableView.contentSize.height < oldContentHeight {
                    // Nothing anchorable survived. Fall back to the height delta — which is
                    // the right approximation in both directions: content grew above us (a
                    // prepend) or shrank (rows filtered away). Not applied when the content
                    // merely grew *below* the viewport, where the offset is already correct.
                    tableView.contentOffset.y += tableView.contentSize.height - oldContentHeight
                }
                clampToContent()
            }
        }
        // After the landing, not before: the first apply reaches here with the offset
        // still at the top, and the pill would flash in for the frame before
        // `landInitialIfNeeded` parks the buffer at its newest message.
        landInitialIfNeeded()
        updateFloatingPills()
        wasDetached = nowDetached
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
    /// target message.
    private func landInitialIfNeeded() {
        guard needsInitialScroll, tableView.bounds.height > 0 else { return }
        if pendingJumpId != nil {
            beginJumpLanding()
            return
        }
        guard !rows.isEmpty else { return }
        needsInitialScroll = false
        scrollToBottom()
    }

    /// The row a converging jump scrolls to and flashes: the first unread (just below the
    /// divider) for a jump-to-unread (#45), else the anchor's own row. Re-resolved every pass by
    /// `convergeJump`, so a row rebuild between runloops can't strand the scroll on a stale index.
    /// Nil until the target both exists and can be trusted — which is what keeps a landing
    /// waiting: the anchor's row isn't loaded yet, or, for the unread jump, the `around` slice is
    /// still in flight so the divider is pinned to the top of the stale latest window (every
    /// loaded row unread) rather than the real seam.
    private func jumpTargetRow(anchor: Int) -> Int? {
        if jumpFlashesFirstUnread {
            if aroundRequestedAtGeneration != nil, !aroundSliceArrived { return nil }
            return firstUnreadRow
        }
        return rowIndex(containing: anchor)
    }

    /// Start converging on the jump target, once. Waits (returns, leaving the jump pending) if
    /// the target row isn't available yet — unless the `around` slice already came back without
    /// it (`anchorMissing`, or no unread in the slice), in which case it gives up and lands at
    /// the bottom.
    private func beginJumpLanding() {
        guard let anchor = pendingJumpId, !jumpConverging else { return }
        guard jumpTargetRow(anchor: anchor) != nil else {
            if aroundSliceArrived {
                // The response landed without a target. Release the jump so the screen isn't
                // stuck "landing" forever — land at the bottom if there's anything to land on,
                // otherwise just let go (an empty buffer shows its empty state, and a later
                // message follows the near-bottom path).
                resetJumpState()
                needsInitialScroll = false
                if !rows.isEmpty { scrollToBottom() }
            }
            return // else: still waiting for the around response.
        }
        jumpConverging = true
        jumpConvergePass = 0
        convergeJump(anchor: anchor)
    }

    /// Scroll the anchor to the middle of the viewport (clamped near an edge — a recent anchor
    /// with little below it lands lower than centre, as centred as it can be), re-checking over
    /// a couple of runloops.
    ///
    /// Two things make the naive version wrong, and this fixes both: (1) it re-resolves the row
    /// by message *id* every pass rather than caching an index, so a row rebuild between passes
    /// (a live message, a read-state update) can't slide the scroll onto the wrong message; and
    /// (2) the jump stays *pending* until the last pass, so an intervening `apply` reloads
    /// without stealing the scroll to the bottom. Off-screen rows self-size from an estimate, so
    /// a lone scroll can land approximately — a couple of passes correct as real heights render —
    /// then it flashes and releases the jump.
    private func convergeJump(anchor: Int) {
        guard let index = jumpTargetRow(anchor: anchor) else { return finishJump(flashing: nil) }
        tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: false)
        jumpConvergePass += 1
        guard jumpConvergePass < Self.jumpConvergePasses else { return finishJump(flashing: anchor) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingJumpId == anchor else { return } // superseded / torn down
            self.convergeJump(anchor: anchor)
        }
    }

    /// Release the jump and pulse the landed-on row — the same row `convergeJump` targeted (the
    /// first unread for a jump-to-unread, else the anchor), resolved once through `jumpTargetRow`
    /// before the state is cleared. A vanished target just lands at the bottom.
    private func finishJump(flashing anchor: Int?) {
        let target = anchor.flatMap { jumpTargetRow(anchor: $0) }
        resetJumpState()
        needsInitialScroll = false
        guard let target else {
            if !rows.isEmpty { scrollToBottom() }
            return
        }
        flashRow(at: IndexPath(row: target, section: 0))
    }

    /// Clear all one-shot jump state. Both jump entry points call this before arming their own
    /// `pendingJumpId`/`jumpFlashesFirstUnread`, and the landing paths call it to release the
    /// jump — so a newly added jump field (as `jumpFlashesFirstUnread` was for #45) can't be left
    /// stranded set from a prior jump.
    private func resetJumpState() {
        pendingJumpId = nil
        aroundRequestedAtGeneration = nil
        aroundSliceArrived = false
        aroundBaselineIds = []
        jumpConverging = false
        jumpConvergePass = 0
        jumpFlashesFirstUnread = false
    }

    /// A warm pulse behind the row, fading out — the "here it is" after a jump. The wash reuses
    /// the highlight color and fades to clear (these cells never carry a fill).
    ///
    /// `cellForRow` is nil for a row that hasn't rendered yet, which is exactly the frame after
    /// a jump scroll — so retry across a couple of runloops rather than silently skipping the
    /// glow (the bug where a jump landed with no pulse).
    private func flashRow(at path: IndexPath, retries: Int = 3) {
        guard let cell = tableView.cellForRow(at: path) else {
            guard retries > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.flashRow(at: path, retries: retries - 1) }
            return
        }
        cell.contentView.backgroundColor = Palette.highlightBubble
        UIView.animate(withDuration: 1.2, delay: 0.5, options: [.curveEaseOut]) {
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
    /// client asks. This screen is also the *launch* screen, so it can exist before there's a
    /// socket to ask over — that's the case this covers.
    ///
    /// Asks with `{type:'history', mode:'latest'}`, not `open-buffer`. Both answer with the
    /// buffer's newest slice, but `open-buffer` is a WRITE: it reopens a closed row and now
    /// announces that to every one of the user's devices. Hydrating through it meant merely
    /// *opening a screen* reopened a buffer everywhere — and, since the server's
    /// paused-account gate correctly classes writes as writes, meant a paused account could
    /// never read its own history at all: `account paused`, then this screen on
    /// "Loading messages…" forever.
    ///
    /// The system buffer and `:server:` logs are excluded (`BufferKind.hydratesOnDemand`)
    /// because they already ship their real backlog in the burst — there is no shell to fill.
    private func hydrateIfNeeded(_ state: ChatState) {
        guard buffer.kind.hydratesOnDemand else { return }
        // A pending jump hydrates via an `around` slice centered on the target (see
        // `requestAroundIfNeeded`), not the latest backlog — asking for both would
        // double-fetch and the latest slice would fight the jump. Once the around slice lands
        // the buffer reads hydrated, so this stays a no-op afterwards.
        guard pendingJumpId == nil else { return }
        guard state.connection == .connected else {
            // A reconnect resyncs buffers as shells, so ask again on the next one. Kept as
            // a fast path only — it fires when a drop is actually reported, which it isn't
            // when a close arrives after the socket was already replaced. The burst check
            // below is the one that always fires.
            hydrateRequestedAtGeneration = nil
            return
        }
        // The row went away, so whatever we asked for is void — re-arm.
        //
        // The request used to clear ONLY on disconnect, which assumed the row could
        // never vanish underneath a live socket. Roster reconciliation broke that: a
        // burst that doesn't name this buffer drops the row and its messages, and
        // anything that re-materializes it — a live event, a later frame — brings it
        // back as an unhydrated shell. With the flag still latched, this would decline
        // to ask ever again over that connection, and the screen sat on "Loading
        // messages…" permanently *without* popping, because by then a row exists again.
        //
        // Keyed on the row being ABSENT rather than merely unhydrated: unhydrated is
        // also the normal state between sending the hydrate and its reply landing, and
        // re-arming there would fire a fresh request on every state update until it did.
        // The absence is reliably observed — the sink's dedupe compares `buffers[key]`,
        // so nil↔shell always gets delivered.
        if state.buffers[buffer.key.id] == nil { hydrateRequestedAtGeneration = nil }
        // A new burst voids a request made during the previous one.
        //
        // The socket can die and be replaced with `connection` never leaving `.connected`
        // (`handleClose` drops a close that lands after the replacement, so a stale close
        // can't clobber a live socket). A request written to the dying socket is lost with
        // no state change to notice, so the `notConnected` reset above never fires and
        // this screen waits forever for a reply that cannot arrive. Observed exactly that
        // way: `-> open-buffer` (the hydrate request of the day), socket shutdown one line
        // later, then a second burst, and
        // `conn=connected` throughout.
        //
        // The burst is the reliable signal — a reconnect always produces one, and it means
        // the server is re-sending everything, which is precisely when anything asked over
        // the old socket becomes void.
        if let asked = hydrateRequestedAtGeneration, asked != state.burstGeneration {
            hydrateRequestedAtGeneration = nil
        }
        guard hydrateRequestedAtGeneration == nil,
              let known = state.buffers[buffer.key.id],
              !known.hydrated
        else { return }
        hydrateRequestedAtGeneration = state.burstGeneration
        // `known.key`, not `buffer.key`: this screen's key can carry a casing the server
        // doesn't store. `state.buffers` is keyed on `BufferKey.id`, which lowercases, so the
        // guard above matches a canonically-cased row even when our own target differs — the
        // join flow synthesizes a screen from the TYPED name before any row exists, and the
        // row then arrives with the network's casing (`#idlerpg` typed, `#idleRPG` stored).
        // The server folds this too, but only a client that never had a stale key is actually
        // safe against an older one.
        viewModel.hydrate(known.key)
    }

    /// Fetch the `around` slice a jump needs (#42): a history window centered on `pendingJumpId`,
    /// so the anchor and its context land even when it's older than any backlog. Skipped when
    /// the message is already held — the landing scrolls straight to it — and re-armed on
    /// reconnect like `hydrateIfNeeded`. Only channel/DM buffers hydrate on demand; a
    /// `:server:`/system jump has nothing to fetch and the landing places against what's loaded.
    private func requestAroundIfNeeded(_ state: ChatState) {
        guard let anchor = pendingJumpId, buffer.kind.hydratesOnDemand else { return }
        guard state.connection == .connected else {
            aroundRequestedAtGeneration = nil
            return
        }
        // A new burst voids a request made during the previous one — see
        // `hydrateIfNeeded` for why `connection` alone can't be trusted to notice.
        if let asked = aroundRequestedAtGeneration, asked != state.burstGeneration {
            aroundRequestedAtGeneration = nil
        }
        guard aroundRequestedAtGeneration == nil else { return }
        // Already held? No fetch — land against what's loaded.
        if (state.messages[buffer.key.id] ?? []).contains(where: { $0.id == anchor }) { return }
        aroundRequestedAtGeneration = state.burstGeneration
        aroundBaselineIds = Set((state.messages[buffer.key.id] ?? []).map(\.id))
        aroundWasHydrated = state.buffers[buffer.key.id]?.hydrated == true
        viewModel.loadAround(buffer.key, anchorId: anchor)
    }

    /// The placeholder currently installed, so a fresh `apply` on every live message
    /// doesn't rebuild the same `StateView` and reassign `backgroundView` unchanged.
    private var shownPlaceholder: BufferPlaceholder?

    /// Show a loading spinner or an empty-state placeholder behind an empty message list,
    /// or nothing when there are messages. Set as the table's `backgroundView`, so it sits
    /// behind the cells and the table hides it the instant there's a row to draw.
    /// Pull older history when everything loaded is filtered out but more exists.
    ///
    /// Paging is driven by scrolling, and a table with no rows cannot scroll — so a window
    /// whose every line is hidden is a dead end: the buffer shows "No messages yet", nothing
    /// can fire `loadOlder`, and it stays that way for the life of the screen even though the
    /// server has plenty more. An ignored sender who dominates a channel reaches this easily,
    /// and so does the `.none` event tier in a channel whose recent traffic is all joins.
    ///
    /// So the filters that can empty the view have to re-arm paging themselves, exactly as
    /// `HistoryFeedViewController.settle()` does for the same reason. `loadOlder` is guarded
    /// against re-entry and reads the RAW store list for its cursor, so calling it here is
    /// safe and correctly paged even though the visible list is empty.
    ///
    /// Gated on the raw list being non-empty: with genuinely nothing loaded this is an
    /// un-hydrated buffer, which `hydrateIfNeeded` owns.
    /// Returns whether a page was requested, so the caller can show the spinner instead of an
    /// empty state while it lands.
    @discardableResult
    private func topUpIfFilteredEmpty(_ state: ChatState) -> Bool {
        guard rows.isEmpty, pendingJumpId == nil else { return false }
        guard let known = state.buffers[buffer.key.id], known.hydrated, known.hasMoreOlder else {
            return false
        }
        guard !(state.messages[buffer.key.id] ?? []).isEmpty else { return false }
        viewModel.loadOlder(buffer.key)
        return true
    }

    private func updatePlaceholder(hasMessages: Bool, known: Buffer?, forceLoading: Bool = false) {
        let placeholder = forceLoading ? .loading : BufferPlaceholder.of(
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
        pillStatus = StatusLight.of(
            reachable: state.reachable,
            connection: state.connection,
            // A DM's light tracks its network, exactly like a channel's: real peer
            // presence is 1.1 (see StatusLight.of).
            network: buffer.networkId.flatMap { state.networks[$0]?.state }
        )
        navigationPill?.refresh(from: self)
    }

    /// The channel-mode glyph for each current member, keyed by lowercased nick.
    ///
    /// Empty — and free — unless `look.nick.show_mode_prefix` is on, and only for channels: a
    /// DM has no modes, and the server buffer has no members. Members only, deliberately:
    /// backlog from someone who has since left gets no glyph rather than a guessed one, which
    /// is what the web does. A member holding no modes is left out entirely, so the lookup
    /// falls through to "" for them too.
    private static func modePrefixes(for state: ChatState, buffer: Buffer) -> [String: String] {
        guard buffer.kind == .channel,
              state.settings.bool("look.nick.show_mode_prefix", default: false)
        else { return [:] }
        var prefixes: [String: String] = [:]
        for member in state.members[buffer.key.id] ?? [] {
            let glyph = MemberPrefix.of(member.modes)
            if !glyph.isEmpty { prefixes[member.nick.lowercased()] = glyph }
        }
        return prefixes
    }

    /// Your own away state as it applies to *this* buffer (#68), or nil where it doesn't.
    ///
    /// The state itself is user-scoped — `/away` hits every connection — but the server
    /// broadcasts a copy per network, so reading this buffer's network reads the user's state.
    ///
    /// Conversations only. The `:server:` log and the system buffer are narration about the
    /// connection rather than a conversation you were absent from, so a marker there would be
    /// noise in the one place noise is already densest — the same call the web makes.
    private static func awayState(for state: ChatState, buffer: Buffer) -> AwayState? {
        switch buffer.kind {
        case .channel, .dm:
            return buffer.networkId.flatMap { state.networks[$0]?.away }
        case .server, .system:
            return nil
        }
    }

    /// Rebuild `rows` from the current `messages` + `typists`, and re-cache the divider index.
    ///
    /// Two callers with different triggers — a state apply and the typing ticker — so the
    /// bookkeeping that has to stay in step with `rows` lives here rather than being repeated
    /// (and eventually forgotten) at each one.
    ///
    /// The row stream itself is built in `LurkerKit` (`MessageRows`): it's the
    /// layout-independent half of the list, so it belongs where a second message-list style
    /// can reach it — and where it can be tested, which a view controller's private method
    /// can't be.
    private func rebuildRows() {
        rows = MessageRows.build(
            messages: messages,
            dividerAfterId: dividerAfterId,
            hasMoreOlder: hasMoreOlder,
            hasMoreNewer: hasMoreNewer,
            typists: typists,
            settings: settings,
            away: awayState
        )
        // Cached so `dividerRow`/`firstUnreadRow` stay O(1) on the scroll-tick and
        // jump-converge hot paths — `rows` only changes here.
        dividerRow = rows.firstIndex { if case .unreadDivider = $0 { return true }; return false }
    }

    // MARK: - Scroll anchoring across a history prepend

    /// The line at the top of the viewport and how far its top sits from the viewport's
    /// top edge, captured from the *current* layout. Restoring both after a reload pins the
    /// reading position, whatever the rows above re-estimate or re-consolidate to.
    /// Every anchorable visible row and where it sits, top-down — the first entry is the line
    /// being read, the rest are fallbacks.
    ///
    /// It returns a list rather than just the top row because the anchor can be one of the
    /// rows that just went away. A history prepend can only *add* above the viewport, but an
    /// ignore rule arriving from another device removes rows anywhere in the loaded window,
    /// the anchor included — and with no anchor and no prepend the old code adjusted nothing
    /// while the content above the viewport shrank, silently relocating the reader into a
    /// different part of the conversation. Restoring against the first row that survived
    /// keeps them where they were, and the second-choice row is usually inches from the first.
    private func visibleAnchors() -> [(id: Int, offset: CGFloat)] {
        let viewportTop = tableView.contentOffset.y + tableView.adjustedContentInset.top
        guard let visible = tableView.indexPathsForVisibleRows?.sorted() else { return [] }
        var anchors: [(id: Int, offset: CGFloat)] = []
        for indexPath in visible {
            guard rows.indices.contains(indexPath.row), let id = rows[indexPath.row].anchorId else { continue }
            let frame = tableView.rectForRow(at: indexPath)
            // Rows above the viewport top aren't being read and make poor anchors — the first
            // one still showing is the line the reader is on.
            guard frame.maxY > viewportTop else { continue }
            anchors.append((id, frame.minY - tableView.contentOffset.y))
        }
        return anchors
    }

    /// The row that now represents message `id` — its own row, or the summary whose span
    /// covers it after a history page merged it into a consolidated run.
    private func rowIndex(containing id: Int) -> Int? {
        rows.firstIndex { $0.represents(id) }
    }

    /// How far the newest message sits below the viewport bottom (0 when parked at the tail).
    ///
    /// The bottom inset is part of the answer, not noise to be left out. `updateBottomInset`
    /// reserves the composer — and, with the keyboard up, the keyboard as well — so the offset
    /// at the tail is `inset` past `contentSize - bounds`, and omitting it made this report
    /// `-inset` where the doc line above promises 0. Harmless at rest, where the reservation is
    /// one composer, but with a keyboard on screen it is 400pt of slack: "near the bottom"
    /// quietly meant "within 80 + inset", so a reader a third of a screen up in history still
    /// counted as parked at the tail. Same maximum `clampToContent` computes.
    private var distanceFromBottom: CGFloat {
        tableView.contentSize.height + tableView.adjustedContentInset.bottom
            - tableView.contentOffset.y - tableView.bounds.height
    }

    /// Within ~80pt of the bottom — treated as "following the conversation".
    private var isNearBottom: Bool { distanceFromBottom < 80 }

    // MARK: - UITableViewDelegate (pagination + the jump pill)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Back at the bottom — however you got there — means caught up: the badge counts
        // "new since you scrolled away", and you're not away anymore.
        if isNearBottom { newWhileDetached = 0 }
        updateFloatingPills()
        guard !messages.isEmpty else { return }
        // Near the top → pull older history. The view model guards `hasMoreOlder` and an
        // in-flight page, so firing this on every scroll tick is safe.
        if scrollView.contentOffset.y < 300 { viewModel.loadOlder(buffer.key) }
        // Near the bottom of a detached slice → pull NEWER history, walking the reader forward
        // toward live (#45). The mirror of the loadOlder prefetch; the view model guards
        // `hasMoreNewer` and an in-flight page. Reaching the tail re-attaches and resumes live.
        if isDetached, distanceFromBottom < 300 { viewModel.loadNewer(buffer.key) }
    }

    /// The settle after `jumpToLatest`'s animated scroll: rows are self-sizing, so the
    /// animated pass positions with estimated heights and can stop short of the real
    /// bottom — the same reason `scrollToBottom` scrolls twice. Finish the job with it.
    /// Unconditional, because that jump is the only animated scroll this screen makes.
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollToBottom()
    }

    /// Update the two floating controls: the jump-to-latest pill in the bottom-trailing corner
    /// and the unread banner under the nav bar. Independent — each is offered whenever its own
    /// condition holds, and "unread above, live traffic below" shows both, one on each edge.
    /// Decided here in one place because both are derived, so it runs on every apply and scroll
    /// tick.
    private func updateFloatingPills() {
        // Jump-to-latest: up in history, or parked on a detached slice below the live tail (#42)
        // — shown even at the bottom *of that slice*, where near-bottom is true.
        let showLatest = (isDetached || !isNearBottom) && !rows.isEmpty
        jumpButton.setVisible(showLatest, animated: true)
        jumpButton.setNewCount(newWhileDetached)
        // Reaching the divider spends the banner for good — checked before the show below, so a
        // divider that's on screen the moment the buffer opens never raises it at all.
        if isDividerVisible { dividerSeen = true }
        // The unread banner (#45): a first-unread row exists, it's above the reader, and they
        // haven't been to it yet. A non-nil `firstUnreadRow` already implies rows exist and a
        // divider is built. It yields the slot whenever the connection banner wants it — the wire
        // being down is the more urgent thing to say, and the unreads will still be there
        // afterwards — and stays down for the length of a jump: `jumpToFirstUnread` hides it to
        // acknowledge the tap, and the scrolls that converge on the anchor run straight back
        // through here, which would otherwise flap it back on until the divider landed.
        let showUnread = firstUnreadRow != nil && !dividerSeen && isDividerAboveViewport
            && pendingJumpId == nil && !connectionBanner.isVisible
        unreadBanner.setVisible(showUnread, animated: true)
    }

    /// The buffer is showing an `around` slice below the live tail (#42): live events are held
    /// back, and the jump-to-latest pill re-attaches rather than just scrolling.
    private var isDetached: Bool { viewModel.state.buffers[buffer.key.id]?.hasMoreNewer == true }

    // MARK: - Typing (#61)

    /// Start ticking while someone is typing, stop when nobody is.
    private func updateTypingTicker() {
        guard !typists.isEmpty else {
            typingTicker?.invalidate()
            typingTicker = nil
            return
        }
        guard typingTicker == nil else { return }
        // One second is well inside the shortest lease (6s), so the line never lingers
        // visibly past its welcome, and it's coarse enough to be free.
        //
        // `.common` rather than `scheduledTimer`'s default mode: the run loop switches to
        // tracking while the table is being dragged, and a default-mode timer simply stops
        // firing for the duration — so a reader scrolling through history would watch the
        // typing line hang there, un-expired, until they lifted their finger.
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshTypists()
        }
        RunLoop.main.add(ticker, forMode: .common)
        typingTicker = ticker
    }

    /// Re-read the typists and redraw only if the list actually changed.
    ///
    /// The guard is what makes a once-a-second timer acceptable: for most ticks nothing has
    /// changed and this costs a dictionary lookup and a comparison, not a table reload.
    ///
    /// Redrawing goes through `apply` rather than reloading here, because adding or removing
    /// a row is exactly the event `apply` already knows how to survive: it re-pins a
    /// scrolled-up reader to the line they were on (a bare `reloadData` re-estimates
    /// off-screen row heights and shoves the viewport — the lurch that was fixed in #42), and
    /// it stays out of the way of a landing that hasn't happened yet, which a direct
    /// `scrollToBottom` here would steal from a jump mid-converge.
    private func refreshTypists() {
        guard viewModel.state.typists(in: buffer.key) != typists else { return }
        apply(viewModel.state)
    }

    /// The draft changed — tell the network, and re-arm the idle downgrade.
    private func draftChanged(_ draft: String) {
        emitTyping(outgoingTyping.draftChanged(to: draft, at: Date()))
        typingIdleTimer?.invalidate()
        typingIdleTimer = nil
        // Nothing to downgrade if we aren't claiming to type in the first place.
        guard outgoingTyping.isSignalling else { return }
        // `.common` for the same reason as the ticker: scrolling the conversation with a
        // half-written draft must not hold the `paused` downgrade open indefinitely.
        let idle = Timer(timeInterval: OutgoingTyping.idle, repeats: false) { [weak self] _ in
            guard let self else { return }
            typingIdleTimer = nil
            // The draft captured here is the latest one: any change re-arms this timer.
            emitTyping(outgoingTyping.idled(draft: draft, at: Date()))
        }
        RunLoop.main.add(idle, forMode: .common)
        typingIdleTimer = idle
    }

    /// Stop claiming to type — on send, and on leaving the buffer. Silent when we weren't.
    private func endTyping() {
        typingIdleTimer?.invalidate()
        typingIdleTimer = nil
        emitTyping(outgoingTyping.ended())
    }

    private func emitTyping(_ signal: TypingSignal?) {
        guard let signal else { return }
        // The `chat.send_typing_notifications` privacy gate lives in `setTyping` itself, at
        // the single point every tag leaves through. `OutgoingTyping` still advances its state
        // while suppressed, so it believes it said things it didn't — harmless both ways:
        // nothing goes out while the switch is off, and turning it on mid-draft costs at most
        // one refresh window (3s) before the next `active`.
        viewModel.setTyping(buffer.key, signal: signal)
    }

    /// Ride back down animated — it's a distance covered, not a teleport — then let
    /// `scrollViewDidEndScrollingAnimation` correct for the estimated heights. When detached,
    /// there's no tail on screen to ride to: re-attach by fetching the latest slice (#42) and
    /// land at its bottom once it arrives.
    private func jumpToLatest() {
        guard !rows.isEmpty else { return }
        newWhileDetached = 0
        if isDetached {
            // Re-arm the one-shot landing (dropping any stale jump state, including a converge
            // that would otherwise leave `jumpConverging` stuck) so `landInitialIfNeeded` parks
            // us at the tail when the replacement slice lands.
            resetJumpState()
            needsInitialScroll = true
            viewModel.loadLatest(buffer.key)
        } else {
            tableView.scrollToRow(at: IndexPath(row: rows.count - 1, section: 0), at: .bottom, animated: true)
        }
    }

    // MARK: - Jump to first unread (#45)

    /// The row the unread divider sits at, cached whenever `rows` is rebuilt (see `apply`).
    /// Read on every scroll tick and jump-converge pass, so it's cached rather than re-scanned:
    /// on a large-unread channel `rows` runs to thousands of entries and the divider can be near
    /// the bottom of them.
    private var dividerRow: Int?

    /// The first unread row — the one just below the divider, when both it and a row past it
    /// exist. The single definition of "where the unreads begin", used by the pill's visibility,
    /// the jump target, and the post-jump flash.
    private var firstUnreadRow: Int? {
        dividerRow.flatMap { rows.indices.contains($0 + 1) ? $0 + 1 : nil }
    }

    /// Whether the unread divider is currently on screen — the reader has reached (or is at)
    /// their first unread, so the unread banner has done its job and should retire.
    private var isDividerVisible: Bool {
        guard let row = dividerRow else { return false }
        return tableView.indexPathsForVisibleRows?.contains(IndexPath(row: row, section: 0)) ?? false
    }

    /// Whether the divider sits *above* the viewport — the unreads are up there, which is the
    /// only arrangement the banner's up-chevron describes truthfully.
    ///
    /// "Off screen" isn't enough on its own. The divider is latched at the read boundary for this
    /// screen's whole life, so scrolling up past it into older history leaves it off screen
    /// *below* the viewport — and a banner promising unread above would then scroll you down.
    /// `.min()` rather than `.first` because the visible index paths aren't documented as sorted.
    private var isDividerAboveViewport: Bool {
        guard let row = dividerRow,
              let topmost = tableView.indexPathsForVisibleRows?.map(\.row).min() else { return false }
        return row < topmost
    }

    /// Latched once the divider has been on screen: the reader has seen where they left off, so
    /// the banner is spent for this screen's lifetime.
    ///
    /// Needed because the divider itself never clears — read forward past it and it's simply
    /// above you again, which without this would put the banner back up (and keep it up for the
    /// rest of the session) after its unreads had all been read.
    private var dividerSeen = false

    /// Jump to the first unread message, always via the #42 jump — never a raw scroll. On a
    /// channel with a large unread count the first unread is thousands of churny, self-sizing
    /// rows above the tail (or not loaded at all), and a single `scrollToRow` against estimated
    /// heights there simply doesn't land. Anchoring the jump on the last-read message handles
    /// both cases uniformly: when it's off the loaded slice, `requestAroundIfNeeded` fetches a
    /// detached `around` slice centered on it; when it's already held, `convergeJump` walks to
    /// it over several passes, re-resolving the row by id each runloop to correct for the
    /// height/consolidation drift that breaks a one-shot scroll. Either way the divider (and the
    /// unreads below it) land on screen, with after-paging carrying the reader forward to live.
    private func jumpToFirstUnread() {
        guard let boundary = dividerAfterId, boundary > 0 else { return }
        // The FETCH anchors on the read boundary (last-read id), not the first unread: on a
        // large-unread channel every loaded row is newer than the boundary, so the first unread
        // *is* the oldest loaded row — anchoring the fetch there would find it already held and
        // never page back to the real seam (the web's #216). Centering the `around` slice on the
        // boundary is what pulls the seam into view.
        //
        // The SCROLL/flash target is decoupled from this anchor (see `jumpTargetRow`): it's the
        // first unread *rendered* row (below the divider), because the boundary id can be an
        // `.other` frame this buffer never renders (`lastReadId` is `max()` over *all* stored
        // ids), which `rowIndex` could never resolve — so scrolling to the boundary itself could
        // wedge the landing forever. `jumpFlashesFirstUnread` switches both onto the divider row.
        resetJumpState()
        needsInitialScroll = true
        pendingJumpId = boundary
        jumpExemptId = boundary
        jumpFlashesFirstUnread = true
        // Down now rather than when the divider lands: the `around` fetch can take a moment and
        // the tap has to be acknowledged. `pendingJumpId` (set just above) is what *keeps* it
        // down until the jump releases — see `updateFloatingPills`.
        unreadBanner.setVisible(false, animated: true)
        requestAroundIfNeeded(viewModel.state)
        landInitialIfNeeded()
    }

    /// A failed send (`send-result` ok:false) or a server `error` frame lands in
    /// `state.error`; surface it rather than losing it silently. Comprehensive error /
    /// empty / loading states across every screen are #19 — this is the send-failure
    /// case the composer must never swallow.
    ///
    /// Presented from whatever is actually on top, not from `self`. The highlights sheet is
    /// presented by the *navigation controller*, so our own `presentedViewController` reads
    /// nil while it covers the screen — presenting on `self` there is dropped by UIKit, and
    /// since only the alert's OK clears `state.error`, the error would stick and its own
    /// repeat would then be swallowed as a duplicate.
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
        // Before the send, not after: the line itself is the end of composing, and a `done`
        // trailing it would be a second, redundant tag. `composer.clear()` below re-enters
        // `draftChanged` with an empty field, which is a no-op once this has run.
        endTyping()
        if isDetached {
            // A detached slice holds live traffic out of the log, so the line just sent isn't
            // loaded and no amount of scrolling will reach it — and `apply` excludes detached
            // buffers from `newWhileDetached`, so the pill wouldn't count it either. Left alone
            // this reads as a failed send. Re-attach instead, which is what the browser does
            // (`sendScroll.ts`) and what the setting's own shared description promises: sending
            // from a jumped-to point returns you to the live conversation either way. The
            // setting has no say here — it is about keeping a place in a conversation, and this
            // is a place the conversation isn't.
            jumpToLatest()
        } else if !keepsPositionWhileReading {
            // Carry the reader down to their own line, the way the browser's composer always
            // has (#628) — unless they asked to keep their place. The echo lands a moment
            // later, over the socket; scrolling to the current tail now is what makes `apply`'s
            // `wasNearBottom` true when it does, so the new bubble is followed rather than
            // counted on the pill.
            scrollToBottom()
        }
        let outcome = viewModel.send(buffer.key, text: text)
        composer.clear()
        // `/msg`/`/query` opened a DM and asked us to switch to it.
        if case .activate(let key) = outcome { navigate(to: key) }
        // `/join` asked us to switch once the channel is real — see `awaitJoin`.
        if case .awaitJoin(let key) = outcome { awaitJoin(key) }
    }

    /// Switch to a channel we just asked to join, the moment its buffer materializes.
    ///
    /// The row appears when `channel-joined` comes back and `applyLive` mints it — which is
    /// the only thing that proves we're actually in the channel. Waiting for it rather than
    /// navigating straight away is what keeps a refused join (no such channel, +i, banned,
    /// a 470 forward to another name) from stranding the user on a screen that never fills:
    /// nothing fires, they stay where they typed, and the error prints in front of them.
    ///
    /// `statePublisher` replays current state on subscribe, so joining a channel already
    /// open switches to it immediately — which is what typing `/join` for it means.
    ///
    /// The timeout only tidies up. It exists so a join that never lands doesn't leave a
    /// subscription that could fire much later — switching the user somewhere unasked
    /// because they happened to join that channel from another client ten minutes on.
    private func awaitJoin(_ key: BufferKey) {
        pendingJoinCancellable?.cancel()
        pendingJoinCancellable = viewModel.statePublisher
            .compactMap { $0.buffers[key.id] }
            .first()
            .timeout(.seconds(15), scheduler: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] _ in self?.pendingJoinCancellable = nil },
                receiveValue: { [weak self] joined in
                    self?.pendingJoinCancellable = nil
                    self?.navigate(to: joined.key)
                }
            )
    }

    /// Switch to another buffer — what `/msg` and `/query` ask for once the DM is open. The
    /// target may not be in state yet (a brand-new DM whose `open-buffer` reply is still in
    /// flight), which is what `buffer(for:)` synthesizes for.
    private func navigate(to key: BufferKey) {
        guard key != buffer.key else { return }
        navigationController?.showBuffer(
            viewModel.state.buffer(for: key), viewModel: viewModel, animated: true
        )
    }

    // MARK: - Attachments (#14)

    /// Whether an attachment is mid-flight — either being staged by the picker (`preparing`,
    /// before `uploadTask` exists) or actively compressing/uploading. Gates every entry point
    /// so a second pick or paste can't start atop the first.
    private var isUploadBusy: Bool { uploadTask != nil || attachmentPicker != nil }

    /// The paperclip: offer the two sources and, on a pick, run the upload. One at a time —
    /// the status readout and `viewModel.upload`'s single-flight both assume it.
    private func presentAttachmentSources() {
        guard !isUploadBusy else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Photo Library", style: .default) { [weak self] _ in
            self?.pick { $0.pickFromPhotoLibrary(completion: $1) }
        })
        sheet.addAction(UIAlertAction(title: "Files", style: .default) { [weak self] _ in
            self?.pick { $0.pickFromFiles(completion: $1) }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // iPad presents an action sheet as a popover, which needs an anchor — the composer's
        // leading edge, roughly where the paperclip sits.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = composer
            popover.sourceRect = CGRect(x: 24, y: 0, width: 1, height: 1)
            popover.permittedArrowDirections = .down
        }
        present(sheet, animated: true)
    }

    /// Build the picker and start it — but only once a source is actually chosen. Setting
    /// `attachmentPicker` HERE, not before presenting the sheet, means a dismissed sheet
    /// (Cancel, or an iPad outside-tap that fires no handler) never leaves `attachmentPicker`
    /// set — which would wedge `isUploadBusy` true and disable the paperclip for the session.
    private func pick(
        _ start: (AttachmentPicker, @escaping (Result<AttachmentPicker.Picked, AttachmentPicker.PickError>) -> Void) -> Void
    ) {
        guard !isUploadBusy else { return }
        let picker = AttachmentPicker(presenter: self)
        // The export/copy is a silent multi-second stretch for a large or iCloud video —
        // raise the readout the moment an item is committed so it isn't a dead pause.
        picker.onPreparing = { [weak self] in self?.uploadStatus.present(.preparing) }
        attachmentPicker = picker
        start(picker) { [weak self] in self?.handlePick($0) }
    }

    private func handlePick(_ result: Result<AttachmentPicker.Picked, AttachmentPicker.PickError>) {
        attachmentPicker = nil
        switch result {
        case .success(let picked):
            beginUpload(picked)
        case .failure(.cancelled):
            // A cancel never raised the "Preparing…" readout (it's shown only once an item is
            // committed), but dismiss defensively in case staging began then bailed.
            uploadStatus.dismiss()
        case .failure(.failed(let message)):
            uploadStatus.dismiss()
            presentUploadAlert(message)
        }
    }

    /// Upload an image pasted into the composer (#14). Reuses the whole pick→upload path by
    /// staging the pasteboard bytes to a temp file, so it flows through the same progress,
    /// URL-insert, and cleanup. Images never need compression, so `isVideo` is always false.
    private func uploadPastedImage(data: Data, mime: String, filename: String) {
        guard !isUploadBusy else { return }
        let ext = (filename as NSString).pathExtension.isEmpty ? "png" : (filename as NSString).pathExtension
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lurker-paste-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
        } catch {
            presentUploadAlert("Couldn't read the pasted image.")
            return
        }
        beginUpload(AttachmentPicker.Picked(url: url, filename: filename, mime: mime, isVideo: false))
    }

    /// Where a completed upload lands, and where a failure is a `case`, not an exception.
    private enum UploadOutcome {
        case inserted(String)
        case failed(UploadError)
        case cancelled
    }

    private func beginUpload(_ picked: AttachmentPicker.Picked) {
        uploadStatus.present(picked.isVideo ? .compressing(0) : .uploading(0))
        let token = UUID().uuidString
        // Strong `self`: the upload must run to completion even if the user leaves this buffer
        // mid-flight (which replaces the root VC). Setting `uploadTask = nil` below breaks the
        // resulting retain cycle, so this VC is released the moment the upload ends.
        uploadTask = Task {
            let outcome = await self.performUpload(picked, token: token)
            self.uploadTask = nil
            self.uploadStatus.dismiss()
            switch outcome {
            case .inserted(let url):
                // Deliver to whatever buffer is on screen NOW: the user may have switched away
                // since starting the upload, and the link should land where their cursor is,
                // not in a torn-down composer (this is what the web client does too).
                //
                // There may be no buffer on screen at all now that the list is a place you can
                // back out to (#49) — and a successful upload whose link goes nowhere, silently,
                // is the worst of the three outcomes. Hand it over instead of dropping it.
                if let chat = Self.activeChat() {
                    chat.composer.insert(url)
                } else {
                    UIPasteboard.general.string = url
                    Self.presentAlert(title: "Upload finished", message: "The link is on your clipboard.")
                }
            case .failed(let error):
                self.presentUploadAlert(error.userMessage)
            case .cancelled:
                break
            }
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// The ChatViewController currently on screen, if any. Exactly one is ever in the stack
    /// and it's on top of the buffer list, so it's the nav's top VC — resolved from the active
    /// window rather than `self`, so it finds the CURRENT buffer even when the originating VC
    /// is offscreen. Nil when the user has backed out to the list and no buffer is open.
    private static func activeChat() -> ChatViewController? {
        (keyWindow()?.rootViewController as? UINavigationController)?.topViewController as? ChatViewController
    }

    /// The frontmost presented VC, for presenting over whatever is currently up (a sheet, the
    /// buffer list). Mirrors `surface(_:)`'s reasoning: presenting on a covered or offscreen
    /// `self` is silently dropped by UIKit.
    private static func topMostViewController() -> UIViewController? {
        guard var top = keyWindow()?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Compress (video only) then upload, reporting each phase to the status view. Returns an
    /// outcome rather than throwing so `beginUpload`'s completion stays a flat switch, and
    /// treats a cancel as its own case so a user-initiated stop never pops an error alert.
    private func performUpload(_ picked: AttachmentPicker.Picked, token: String) async -> UploadOutcome {
        // The picker's copy and any on-device derivative (transcode / HEIC→JPEG) are ours to
        // clean up on every exit.
        defer { try? FileManager.default.removeItem(at: picked.url) }
        var fileURL = picked.url
        var filename = picked.filename
        var mime = picked.mime
        var derivedTemp: URL?
        defer { if let derivedTemp { try? FileManager.default.removeItem(at: derivedTemp) } }

        if picked.isVideo {
            uploadStatus.update(.compressing(0))
            do {
                let prepared = try await VideoCompressor.prepare(source: picked.url) { fraction in
                    Task { @MainActor [weak self] in self?.uploadStatus.update(.compressing(fraction)) }
                }
                if prepared.isTemporary {
                    derivedTemp = prepared.url
                    fileURL = prepared.url
                    filename = (filename as NSString).deletingPathExtension + ".mp4"
                    mime = "video/mp4"
                }
            } catch is CancellationError {
                return .cancelled
            } catch let error as UploadError {
                return .failed(error)
            } catch {
                return .failed(.compressionFailed(error.localizedDescription))
            }
        } else if let jpeg = await ImageConverter.jpegIfProblematicHEIC(source: fileURL, mime: mime) {
            // A HEIC the server's libheif can't decode → hand it a JPEG instead.
            derivedTemp = jpeg
            fileURL = jpeg
            filename = (filename as NSString).deletingPathExtension + ".jpg"
            mime = "image/jpeg"
        }

        if Task.isCancelled { return .cancelled }
        uploadStatus.update(.uploading(0))
        let result = await viewModel.upload(
            fileURL: fileURL, filename: filename, mime: mime, progressToken: token
        ) { fraction in
            Task { @MainActor [weak self] in self?.uploadStatus.update(.uploading(fraction)) }
        }
        if Task.isCancelled { return .cancelled }
        switch result {
        case .success(let response): return .inserted(response.url)
        case .failure(let error): return .failed(error)
        }
    }

    /// Cancel button on the status view. Cancels the task (the upload leg aborts promptly; an
    /// in-progress transcode is abandoned at the next await) and dismisses the readout now so
    /// the tap feels instant — the task's own unwind clears `uploadTask`.
    private func cancelUpload() {
        uploadTask?.cancel()
        uploadStatus.dismiss()
    }

    private func presentUploadAlert(_ message: String) {
        Self.presentAlert(title: "Upload failed", message: message)
    }

    /// Top-most, not `self`: an upload outlives the buffer it started in — the user can back
    /// out to the list or open a sheet — and presenting on a covered or offscreen `self` is
    /// silently dropped by UIKit.
    private static func presentAlert(title: String, message: String) {
        guard let top = topMostViewController() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
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
            members: viewModel.state.visibleMembers(in: buffer.key),
            selfNick: buffer.networkId.flatMap { networks[$0]?.nick },
            query: query,
            isChannel: buffer.kind == .channel,
            ignores: viewModel.state.ignores,
            networkId: buffer.networkId,
            channel: buffer.target
        )
    }

    // MARK: - Navigation

    /// Swipe in from the right edge for the nick list — a shortcut to the overflow menu's
    /// "Members", not the only way in.
    ///
    /// The **left** edge is no longer ours. It used to open the buffer list, which was free
    /// to claim while this screen was the navigation stack's root; now the list is the root
    /// and this is pushed on top, so that edge belongs to the system's interactive pop —
    /// which goes to the same place, and is the gesture people already try.
    private func addEdgeSwipes() {
        func edgeSwipe(_ edge: UIRectEdge, _ action: Selector) {
            let swipe = UIScreenEdgePanGestureRecognizer(target: self, action: action)
            swipe.edges = edge
            view.addGestureRecognizer(swipe)
        }
        edgeSwipe(.right, #selector(swipedFromRight))

        // Long press anywhere on a row for its actions (#60). On the table rather than on a cell,
        // so it costs nothing per row and survives reuse — and so whatever draws a message next
        // doesn't have to remember to attach it. `MessageTextView` refuses its own long presses,
        // which is what lets this one through over a message body.
        tableView.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(messageLongPressed))
        )
    }

    @objc private func swipedFromRight(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        guard recognizer.state == .began else { return }
        showMemberList()
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
        info.onSearchBuffer = { [weak self] scope in
            guard let self else { return }
            showSearch(viewModel: viewModel, seed: scope)
        }
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

    /// The views menu, opposite the back button: the surfaces you *look at*, as against the
    /// buffer you're in. Highlights and Bookmarks today; search and uploads land here as
    /// they're built, which is the set the desktop client keeps in its bottom toolbar (#49).
    ///
    /// Nothing account-scoped lives here. Sign-out sits in the buffer list's own menu,
    /// where the things that outlast the buffer you happen to be reading belong.
    ///
    /// **Members is deliberately not here.** It describes *this channel*, which is what the
    /// buffer-info sheet behind the title pill is for — and that sheet already lists it. A
    /// second door to the same room, one that had to be conditioned on `buffer.kind` because
    /// a DM has nobody to list, only made this menu's contents depend on which buffer you
    /// happened to open. Everything left is app-scoped and present on every buffer, so the
    /// menu is now the same menu everywhere. The right-edge swipe remains as the shortcut.
    ///
    /// A bare "…" means "there's a menu here" on iOS, so nothing in it fires on tap.
    private func overflowItem() -> UIBarButtonItem {
        let actions: [UIMenuElement] = [
            // Unscoped, like everything else in this menu. Searching *this* buffer is a fact
            // about this buffer, so it lives in the buffer-info sheet behind the title pill,
            // where the per-buffer things are — see `BufferInfoViewController`.
            UIAction(title: "Search", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                guard let self else { return }
                showSearch(viewModel: viewModel)
            },
            UIAction(title: "Highlights", image: UIImage(systemName: "at")) { [weak self] _ in
                guard let self else { return }
                showHighlights(viewModel: viewModel)
            },
            UIAction(title: "Bookmarks", image: UIImage(systemName: "bookmark")) { [weak self] _ in
                guard let self else { return }
                showBookmarks(viewModel: viewModel)
            },
        ]
        // Built once, not deferred: nothing in here varies at all now, let alone per press.
        // (The deferral this used to need was for Join, whose networks come and go; that's
        // the buffer sheet's "+" now, and a form rather than a menu.)
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: actions))
        item.accessibilityLabel = "More"
        return item
    }

    // MARK: - Date-label invalidation

    /// Redraw when the meaning of a date label changes out from under it.
    ///
    /// `MessageRenderer.dayLabel` formats relatively ("Today", "Yesterday") and the result is
    /// baked into a cell at `cellForRowAt`. Nothing else invalidates it, so both of these are
    /// buffers-left-open cases that no unrelated state change would come along to fix — and a
    /// quiet buffer is exactly the one that gets no such change:
    ///
    /// - `NSCalendarDayChanged` — local midnight, or a time-zone change moving that boundary.
    ///   Past it, yesterday's divider would go on claiming to be "Today".
    /// - `NSLocale.currentLocaleDidChange` — a region change, after which the label should be
    ///   in the new locale's words. The formatter tracks it (`.autoupdatingCurrent`); this is
    ///   what gets the new string onto the screen.
    ///
    /// The rows themselves don't change — a divider carries an absolute `Date` — so this is a
    /// redraw, not a rebuild.
    ///
    /// Block-based rather than the selector form its keyboard neighbours use, because neither
    /// notification is guaranteed to be posted on the main thread and `queue: .main` is what
    /// makes the redraw safe. That form isn't auto-removed on dealloc, hence the tokens.
    private func observeDateLabelInvalidation() {
        dateLabelObservers = [Notification.Name.NSCalendarDayChanged, NSLocale.currentLocaleDidChangeNotification]
            .map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.tableView.reloadData()
                }
            }
    }

    /// Redraw when the appearance flips, for the one thing in a row that can't follow it.
    ///
    /// Same shape as the date labels above and for the same reason — a value baked into a cell
    /// at `cellForRowAt` that no unrelated state change would come along to correct — but with a
    /// different trigger. Nearly every color in the list is stored *unresolved* and re-resolves
    /// itself as the text draws; the typing row's keyboard symbol can't, because tinting an
    /// image is a draw and the grey goes into its pixels (`MessageRenderer.typingGlyph`). Left
    /// alone, flipping to dark while someone is typing leaves a light-mode glyph on the dark
    /// list until the row next rebuilds — and a quiet buffer with one steady typist is exactly
    /// the case that produces no rebuild, since the typing predicate compares nick lists and a
    /// list that hasn't changed doesn't reload.
    private func observeAppearanceInvalidation() {
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.tableView.reloadData()
        }
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
        // Asked before the layout pass below, which changes the table's bottom inset and so
        // changes the answer: measured against the reservation in force right now, this is
        // "is the reader at the tail as things currently stand", which is what decides whether
        // the keyboard should carry them. Note this notification also fires for frame changes
        // with the keyboard already up (emoji keyboard, predictive bar) — same question, and
        // the same answer is wanted there.
        let keepsPosition = keepsPositionWhileReading
        // `layoutIfNeeded` moves the composer to its new position and, in the same pass,
        // runs `viewDidLayoutSubviews` → `updateBottomInset` against that fresh frame. So
        // the inset isn't recomputed here — doing it before layout would read the old frame.
        view.layoutIfNeeded()
        // Everything below is for the keyboard's ARRIVAL. This notification also fires at
        // the tail of a dismissal with the end frame off-screen — and scrolling there
        // yanks a reader who dragged the keyboard away mid-history back to the bottom.
        guard keyboardOverlap > 0 else { return clampToContent() }
        // `chat.keep_position_on_send` (#628) is written as a rule about sending, but on a
        // phone this is where it's felt: raising the keyboard to reply is what takes a reader
        // out of the history they were reading, well before they've typed anything. A reader
        // already following the live tail is still carried down — the keyboard would otherwise
        // cover the newest messages, which is the whole reason this scroll exists.
        guard !keepsPosition else { return }
        scrollToBottom()
        // The keyboard's arrival just parked the conversation at the bottom, so the jump
        // pill goes with it — stated here rather than left to the scroll's delegate tick,
        // which doesn't fire when the offset was already close enough to need no change.
        newWhileDetached = 0
        updateFloatingPills()
    }

    /// Whether this screen should leave the reader where they are rather than carrying them to
    /// the newest message — `chat.keep_position_on_send` turned on, and the reader actually up
    /// in history rather than parked at the tail (where there's nothing to preserve).
    ///
    /// Inverted at the call sites, which read as "carry them down unless…". The setting is
    /// server-stored and shared with the browser, so the phone and the desktop can't disagree
    /// about the rule; what they differ on is where it bites, which is why this is a property
    /// here and a send-time test on the web.
    private var keepsPositionWhileReading: Bool {
        settings.bool("chat.keep_position_on_send", default: false) && !isNearBottom
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

    // MARK: - Per-message actions (#60)

    /// Long press a message → the actions sheet (`MessageActionsViewController`).
    ///
    /// A plain gesture recognizer rather than `contextMenuConfigurationForRowAt`, because a peek is
    /// a picture of the list and this list is rebuilt (`reloadData`) on every arriving message —
    /// see the sheet's own note for what that cost. The gesture is on the table, not the cell, so
    /// it survives cell reuse for free and doesn't have to be re-attached by whatever draws a row.
    ///
    /// Which actions a line offers is `MessageActions`' call, not this screen's: it lives in
    /// LurkerKit so the answer is unit-testable without a view controller, and so a second
    /// message-list style can't drift from this one — neither of them owns the menu.
    @objc private func messageLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        // A sheet already up (the nick list, buffer info) means this press is somebody's
        // mis-tap through a dimmed screen, not a request for a second sheet.
        guard presentedViewController == nil, navigationController?.presentedViewController == nil
        else { return }
        let point = recognizer.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point), rows.indices.contains(indexPath.row)
        else { return }

        // A press that lands on a URL is about the URL — the line around it isn't what the finger
        // was on. Asked of the cell, which is the only thing that knows where its body sits.
        //
        // Hit-tested before the row is resolved to a message, not after: a row can render text
        // without standing for a single message — a consolidated run of topic changes, say — and
        // a URL in one of those is still a URL you can act on. Gating this on a message first made
        // long press do nothing at all there, while a plain tap opened the link.
        let cell = tableView.cellForRow(at: indexPath) as? MessageBodyHosting
        let url = cell.flatMap { $0.linkURL(at: recognizer.location(in: $0)) }
        let message = rows[indexPath.row].message

        // The scope is read here, at press time, so the sheet's Save/Remove label reflects the
        // store as of the press rather than whenever the row was last drawn. It's then carried
        // to `runMessageAction` rather than re-read there — see that method.
        let scope = MessageActionScope(
            networkId: buffer.key.networkId,
            isBookmarked: message.map { viewModel.isBookmarked($0.id) } ?? false
        )
        let subject = url.map(MessageActionsViewController.Subject.link)
            ?? message.map { .message($0, scope: scope) }
        guard let subject, let sheet = MessageActionsViewController(subject: subject) else { return }

        // The keyboard would otherwise stay up over the sheet. Every other sheet here opens at
        // `.medium()` and stays partly visible above it, but this one is sized to two or three
        // rows — shorter than the keyboard — so it can land entirely behind it, which is the
        // common case: mid-draft, keyboard up, long-press a line to reply to it.
        composer.resignFirstResponder()

        // The press has no other visible effect at the moment it fires — the row doesn't lift the
        // way a peek did — so the tap is what confirms it registered, before the sheet animates in.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        sheet.onRun = { [weak self] key in
            guard let self else { return }
            if let url {
                runLinkAction(key, on: url)
            } else if let message {
                runMessageAction(key, on: message, scope: scope)
            }
        }
        present(sheet, animated: true)
    }

    /// Open / Copy / Share, for a press that landed on a link.
    private func runLinkAction(_ key: MessageActionKey, on url: URL) {
        MessageActions.run(
            key, on: url,
            context: LinkActionContext(
                open: { UIApplication.shared.open($0) },
                copy: { UIPasteboard.general.url = $0 },
                share: { [weak self] url in self?.share(url) }
            )
        )
    }

    /// The system share sheet. Anchored to the composer on a regular-width layout, where a
    /// popover needs somewhere to point — an unanchored one is a runtime trap on iPad, not a
    /// cosmetic issue.
    private func share(_ url: URL) {
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = composer
        share.popoverPresentationController?.sourceRect = composer.bounds
        present(share, animated: true)
    }

    /// The platform half of the two actions: the composer, and the pasteboard. Called after the
    /// sheet has finished dismissing, which is what lets Reply raise the keyboard.
    /// `scope` is the one the SHEET WAS BUILT WITH, deliberately — not a fresh reading.
    ///
    /// It's what titled the row, and honoring it is what makes the button mean what it says.
    /// Re-reading here looks more current and is worse: a `bookmark-updated` echo from another
    /// device landing between the long press and the tap would invert the action, so a row
    /// reading "Save Message" sends an unsave. The user acted on what was on screen.
    private func runMessageAction(_ key: MessageActionKey, on message: Message, scope: MessageActionScope) {
        MessageActions.run(
            key, on: message, scope: scope,
            context: MessageActionContext(
                reply: { [weak self] nick in self?.composer.address(nick) },
                copy: { UIPasteboard.general.string = $0 },
                setBookmark: { [weak self] id, saved in
                    self?.viewModel.setBookmark(messageId: id, saved: saved)
                }
            )
        )
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        listRenderer.cell(for: rows[indexPath.row], at: indexPath.row, in: tableView, context: listContext)
    }

    /// What the renderer needs from this screen to draw a row.
    private var listContext: MessageListContext {
        MessageListContext(
            networkName: { [weak self] message in self?.networkName(for: message) },
            highlighter: nickHighlighter,
            modePrefixes: modePrefixes,
            settings: settings,
            traits: traitCollection,
            isStatusRow: { [weak self] index in self?.isStatusRow(index) ?? false },
            row: { [weak self] index in
                guard let self, rows.indices.contains(index) else { return nil }
                return rows[index]
            }
        )
    }

    /// Whether the row at `index` is status narration (see `MessageRow.isStatus`). Out-of-range
    /// reads as "not status", which is what gives the first and last rows their outer edge.
    private func isStatusRow(_ index: Int) -> Bool {
        rows.indices.contains(index) && rows[index].isStatus
    }

    /// What to call the network a nick-less line belongs to.
    ///
    /// Two sources, because two different lines need it: a system line is app-scoped and
    /// carries the network it's *about* in `originNetworkId`, while server text carries
    /// nothing and simply belongs to whichever server buffer we're looking at.
    private func networkName(for message: Message) -> String? {
        (message.originNetworkId ?? buffer.networkId).flatMap { networks[$0]?.name }
    }

}

// MARK: - The shared title pill

extension ChatViewController: PillPresenting {

    /// The title is computed rather than stored so it is right from the moment this screen
    /// exists: the pill is asked for its content as the push *begins*, which is before any
    /// state has arrived, and a stored title would leave the pill briefly blank and then
    /// cross-fade the buffer's name in on top of a transition that was already running.
    var pillContent: PillContent {
        PillContent(title: displayName, status: pillStatus, hint: "Shows this buffer's info and settings")
    }

    func pillTapped() {
        showBufferInfo()
    }
}


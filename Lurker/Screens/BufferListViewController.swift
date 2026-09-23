// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The app's home screen: every buffer you have, and the way into all of them.
///
/// It is the navigation stack's *root*, and a chat screen is pushed on top of it. That's the
/// ordinary iOS shape for a list of things you go into and come back from, and it buys the
/// back button and the interactive pop gesture rather than making this screen invent its own
/// way in and out. It used to be a sheet over the chat screen, which meant a bespoke button
/// to summon it, an edge swipe wired by hand, and a chat screen that could never be left.
///
/// Drawn as the web sidebar's tree, not as iOS grouped lists: Friends, Favorites, then each
/// network, every group an uppercase header over `├─`/`└─` rows in the log's monospaced face,
/// on the log's own ground. It used to be two-up chip grids over inset-grouped cards, which
/// spent most of a phone's height on padding and rounded corners, and a Recent grid that
/// reshuffled every time you backed out of a buffer and printed rows that were already further
/// down. The cells are in `BufferRowCell.swift`.
///
/// A network's header is its server log (the web's shape), so a network has no "Server" row.
///
/// "Denser" is spacing, not type size — one font size for rows and headers alike. The hierarchy
/// is case, colour and the tree.

/// What a section *is*, independent of where it currently sits.
///
/// ⚠⚠ The fix for a class of bug that cost a long QA session. Sections arrive in a different
/// order than they finally sit in: during the connect burst the list is `libera | …` and
/// moments later `Friends | Favorites | libera | …`, so index 0 stops being a network.
///
/// Everything that used to key off the *index* — which layout to build, which title to
/// draw, whether a drag may land — followed the position rather than the content, and a
/// collection view caches geometry and self-sizing metrics by index path. The result was
/// a list whose rows were each correct and whose picture was not: headers between the
/// wrong rows, one drawn twice, networks apparently out of order. `reloadData`,
/// `invalidateLayout` and even a fresh layout object all failed to fix it, because none
/// of them addressed the reason: identity by position.
nonisolated private enum SectionID: Hashable {
    case friends
    case favorites
    /// A network's group: its header (the server log), its pinned buffers, then the rest.
    case network(Int)
    /// Buffers whose network isn't in the roster yet (snapshot race).
    case unrostered(Int)

    /// Whether these rows can be dragged into a new order (#53). Friends and Favorites,
    /// the two views of the server's one global favorites order (lurker#721) — not the
    /// networks, which are the same sorted list this screen has always shown; a drag there
    /// would be undone by the next rebuild.
    var reorderable: Bool { self == .friends || self == .favorites }
}

/// One item's identity. Section-qualified because a diffable data source requires item
/// identifiers to be unique across the whole snapshot, and the header and pinned-break items
/// every group can carry share a key from one section to the next.
nonisolated private struct ItemID: Hashable {
    let section: SectionID
    let key: String

    /// The keys of the two items that aren't buffers. A `BufferKey.id` always starts with a
    /// network id or `sys`, so these can't collide with one. A network's header takes its
    /// server log's key instead — see `Header.log`.
    static let headerKey = "::header"
    static let pinBreakKey = "::pins"
}

/// It reports the pick through `onSelect` and doesn't know what happens next.
final class BufferListViewController: UICollectionViewController {
    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    /// Called with the picked buffer. The presenter owns opening it.
    var onSelect: ((Buffer) -> Void)?

    private struct Row: Equatable {
        let buffer: Buffer
        /// The full network name. Friends and Favorites rows carry it for their accessibility
        /// label; network rows leave it nil, already sitting under their network's header.
        let networkName: String?
        /// The short `li` disambiguator drawn after the name, set by `addNetworkHints` only
        /// on rows whose name collides with another in the same group. Separate from
        /// `networkName` because the two answer different questions: this one is "would you
        /// otherwise confuse this row with the one beside it", and it's nil far more often.
        var networkHint: String?
        /// The peer's presence, set on every DM row: it mutes an away or offline name
        /// (#167). Nil for anything that isn't a DM. Equatable so a presence change reconfigures the one cell.
        var presence: FriendPresence?
        /// A Friends row — the one row kind whose buffer may be SYNTHESIZED (a
        /// favorite the store hasn't materialized), so a tap must open-buffer first.
        /// An explicit flag, not "has presence": presence is styling every DM row carries,
        /// not a fact about where the buffer came from, and this gates a WRITE.
        var isFriend: Bool = false
        /// Whether an ignore rule mutes this buffer's plain-unread signal (lurker #359).
        /// Carried on the row — and therefore compared by `Equatable` — so muting or unmuting
        /// from another device reconfigures the one cell it affects.
        var muted: Bool = false
        /// A channel we hold a row for and aren't in (`ChatState.isParted`): drawn dimmed, and
        /// offered Join on long-press. Read from the store, never from `buffer` — a favorite's
        /// row can carry a synthesized buffer whose `joined` is a default, not a statement.
        var parted: Bool = false
        /// `├─` or `└─`, set once the group's rows are known — see `Section.init`.
        var guide: TreeGuideView.Shape = .tee

        /// What the unread pill counts.
        ///
        /// A muted buffer drops the plain-unread signal and shows highlights only, so ordinary
        /// traffic stops moving the badge while someone saying your name still does — which is
        /// the entire point of muting a busy room you nonetheless follow. Highlights pass
        /// through untouched, and the red tint with them. Same downgrade the web applies in
        /// `BufferList.vue`'s `displayCount`.
        var displayUnread: Int { muted ? buffer.highlights : buffer.unread }

        init(
            buffer: Buffer,
            networkName: String?,
            presence: FriendPresence? = nil,
            isFriend: Bool = false,
            muted: Bool = false,
            parted: Bool = false
        ) {
            self.buffer = buffer
            self.networkName = networkName
            self.presence = presence
            self.isFriend = isFriend
            self.muted = muted
            self.parted = parted
        }
    }

    /// A group's header. For a network it's also the network's server log — tapping it opens
    /// the log, as the web's header does — and `log` carries that buffer's row.
    private struct Header: Equatable {
        let title: String
        /// The network's state as a dot, under this app's own connection. Nil for Friends and
        /// Favorites.
        var light: StatusLight?
        /// The network's state in words, only when the network itself isn't connected.
        var state: String?
        var log: Row?
        /// Every header but the first draws the rule between it and the group above.
        var ruleAbove = false
    }

    /// Everything an item can be. The list is one flat sequence of these per group.
    private enum Entry: Equatable {
        case header(Header)
        case buffer(Row)
        case pinBreak
    }

    private struct Section {
        let id: SectionID
        var header: Header
        /// The buffer rows, pinned first. What a drag's index arithmetic works on.
        var rows: [Row]
        /// How many of `rows` are pinned. A break is drawn after them when rows follow.
        let pinnedCount: Int

        /// ⚠⚠ De-duplicated once, HERE, so the model and the snapshot cannot disagree.
        ///
        /// A diffable snapshot raises `NSInternalInconsistencyException` on a repeated item
        /// identifier, and the store can hold two favorites under one key for a frame: the
        /// nick-change handler rewrites a favorite's target by `bufferId` and leaves merge
        /// dedupe to the `favorites-changed` that follows, so being friends with `alice` and
        /// `bob` and watching `bob` rename to `alice` collides them.
        ///
        /// The first attempt de-duplicated in `items` alone, which fixed the crash and bought
        /// a subtler bug: the drag reorder does its index arithmetic against `rows`, while
        /// UIKit hands back index paths addressing the de-duplicated snapshot — so with a
        /// duplicate present the two lists are off by one and a drop lands in the wrong
        /// place. One list, de-duplicated at the door, and the question doesn't arise.
        ///
        /// The guides are set here too, since only the finished list knows which row is last.
        /// The last pinned row keeps `├─` when rows follow the break, because the spine runs on
        /// through it.
        init(id: SectionID, header: Header, pinned: [Row] = [], rows rest: [Row]) {
            self.id = id
            self.header = header
            var seen = Set<String>()
            if let log = header.log { seen.insert(log.buffer.key.id) }
            let pinned = pinned.filter { seen.insert($0.buffer.key.id).inserted }
            let rest = rest.filter { seen.insert($0.buffer.key.id).inserted }
            var rows = pinned + rest
            for index in rows.indices { rows[index].guide = index == rows.count - 1 ? .elbow : .tee }
            self.rows = rows
            self.pinnedCount = pinned.count
        }

        var hasPinBreak: Bool { pinnedCount > 0 && pinnedCount < rows.count }

        var headerItem: ItemID {
            ItemID(section: id, key: header.log?.buffer.key.id ?? ItemID.headerKey)
        }

        /// The header, then the rows, with the pinned break where it belongs. `rows` is unique by
        /// construction — see `init`.
        var entries: [(ItemID, Entry)] {
            var out: [(ItemID, Entry)] = [(headerItem, .header(header))]
            for (index, row) in rows.enumerated() {
                if hasPinBreak, index == pinnedCount {
                    out.append((ItemID(section: id, key: ItemID.pinBreakKey), .pinBreak))
                }
                out.append((ItemID(section: id, key: row.buffer.key.id), .buffer(row)))
            }
            return out
        }

        var items: [ItemID] { entries.map(\.0) }

        /// Where the rows start among the items: after the header. Only reorderable sections
        /// ask, and they never have a pinned break.
        static let firstRowItem = 1
    }

    private var state = ChatState()
    private var sections: [Section] = []
    /// The centered "loading"/"nothing here" placeholder, and what it's currently showing.
    /// Tracked so a rebuild only touches the background view when the answer actually changes.
    private let placeholderView = StateView()
    private var shownPlaceholder: BufferListPlaceholder = .none
    /// The floating "Connecting…"/"No internet connection" capsule (#19). The same one the
    /// chat screen carries: the connection is the app's state, not one screen's, and a list
    /// that goes quiet because the socket is down should say so where you're standing.
    ///
    /// Its state is tracked continuously but only *shown* while this screen is the one on top
    /// — see `refreshBanner`.
    private let connectionBanner = ConnectionBanner()
    /// What the banner would show if this screen were frontmost. Held separately so the answer
    /// is already current the moment it becomes frontmost, without waiting for a state change.
    private var bannerState: ConnectionBannerState = .hidden
    /// Whether this screen is actually on screen, as against merely alive under a chat screen.
    /// It is the stack's *root* now and outlives every buffer you open, so `apply` runs for the
    /// whole session — every message anywhere lands as a read-state change on `buffers`. Without
    /// this, each one rebuilds every section and reloads a list nobody can see.
    private var isOnScreen = false
    /// Whether a state change arrived while a row was being dragged and is still owed a
    /// rebuild (#53). See `rebuild()` for why it waits and `dragSessionDidEnd` for the release.
    private var rebuildDeferredByDrag = false
    /// The section a live drag was lifted from — rows reorder only within their own
    /// section, and this is the O(1) identity `dropSessionDidUpdate` checks per
    /// touch-move (sections are frozen during a drag; rebuild defers).
    private var dragSourceSection: Int?
    /// The just-dropped favorites order (bufferIds) awaiting its server echo, plus the
    /// store snapshot it permutes — see `orderedFavorites(_:)`.
    private var optimisticFavoriteOrder: [Int]?
    private var favoritesAtDrop: [FavoriteEntry]?
    /// The store's favorites when the live drag lifted. A drop is refused if they've moved
    /// since — see `performDropWith`.
    private var favoritesAtDragStart: [FavoriteEntry]?

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        // The real layout needs `self` for its swipe actions, which isn't available until after
        // `super.init`; it's swapped in from `viewDidLoad`.
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The title is "Lurker" and its subtitle is the connection's state — see `apply`.
        // Inline, not large: the bar's own row is enough to say what the screen is, and a
        // large title spends a band of the screen on it before the first buffer.
        navigationItem.apply(statusTitle)
        // The empty state's only button, and it has only one meaning here: this screen's
        // placeholder never asks anything else of the user.
        placeholderView.onAction = { [weak self] in self?.showAddNetwork() }
        // The back button borrows "Lurker" from the title for its long-press menu and
        // VoiceOver, but a titled back button is iOS 26's 95pt "‹ Lurker" pill, which crowds
        // the chat screen's bar. `.minimal` keeps the title for those while drawing the
        // indicator alone — a 44pt button with no label.
        navigationItem.backButtonDisplayMode = .minimal
        // The system's own ground rather than the message list's. Set on the list configuration
        // too — see `makeLayout`, whose own default would otherwise paint over this. It holds
        // in an expanded split as well, because the split opts out of the sidebar's glass — see
        // `primaryBackgroundStyle` in `BufferSplitViewController`.
        collectionView.backgroundColor = .rosterGround
        // ⚠ Created explicitly, before anything can ask the collection view for its contents,
        // rather than as a side effect of the first thing that happens to touch it.
        // `UICollectionViewController` installs itself as the collection view's data source in
        // `loadView`; constructing the diffable one is what replaces it.
        _ = dataSource
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)

        // Drag-and-drop rather than `moveItemAt` + the standard interactive-movement gesture
        // (#53). That gesture is a long press, which is already the row's context menu — the
        // two would race, and the one that lost would be the discoverable one. A drag session
        // is how UIKit reconciles them: a lift that *moves* reorders, a lift that stays put
        // opens the menu, which is what every reorderable list on the system does.
        //
        // No `dragInteractionEnabled = true` alongside these: it has defaulted to true on
        // iPhone as well as iPad since iOS 15, and this app floors at 26.
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self

        // This screen *is* its collection view, so the banner is a subview of a scroll view.
        // Two consequences worth naming:
        //
        //  - It's pinned to the safe-area guide, which is expressed against the scroll view's
        //    bounds — and bounds.origin is the content offset — so the banner rides along and
        //    stays put in the viewport, while still clearing the nav bar.
        //  - Cells are inserted above it in subview order as they're dequeued, so a plain
        //    `addSubview` would let a row draw over it. `zPosition` wins regardless of order,
        //    where a `bringSubviewToFront` would need repeating after every reload.
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        connectionBanner.layer.zPosition = 1
        view.addSubview(connectionBanner)
        NSLayoutConstraint.activate([
            connectionBanner.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            connectionBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            connectionBanner.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16
            ),
            connectionBanner.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16
            ),
        ])

        // Force the lazy registrations to instantiate here, up front. UIKit throws if a
        // registration is first *created* inside `cellForItemAt` — a lazy var is created
        // once, but "once" is on first access, and its first access would otherwise be the
        // dequeue itself. Touching them here moves creation out of that call.
        _ = rowRegistration
        _ = headerRegistration
        _ = pinBreakRegistration

        // Both in the navigation bar, and deliberately not in a bottom toolbar. A toolbar
        // would be a second floating bar over a scrolling list, and it can't persist across
        // the push into a chat screen — whose bottom is a composer — so it has to leave and
        // come back on every navigation, which is a lot of movement to buy two buttons.
        //
        // Never touched by `apply`: it runs on every unread-count change, and swapping a bar
        // button item out closes any menu it happens to be showing. Only a layout change
        // touches the bar — see `applyBarLayout`.
        applyBarLayout()
        registerForVerticalBarChanges { list in list.applyBarLayout() }

        // Every row and header is set in a font built from this screen's traits (`listFont`),
        // which a text-size change doesn't reach on its own. `rebuild`'s diff can't
        // see it either — no row's content moved — so reconfigure every item at the new size.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (list: Self, _) in
            var snapshot = list.dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            list.dataSource.apply(snapshot, animatingDifferences: false)
        }

        // The list depends on networks, buffers, and connection state — a message arriving
        // in some channel shouldn't rebuild it (badge counts arrive as read-state updates,
        // which do change `buffers`). `connection` and `reachable` are here because the
        // Lurker row renders them.
        viewModel.statePublisher
            .removeDuplicates {
                $0.networks == $1.networks
                    && $0.buffers == $1.buffers
                    && $0.connection == $1.connection
                    && $0.reachable == $1.reachable
                    // A DM row's presence waits for the reconnect's snapshot (`rowPresence`), and
                    // that snapshot can leave everything else here unchanged. Without this the rows
                    // would sit on "unknown" until some unrelated frame let a rebuild through.
                    && $0.snapshotSinceOpen == $1.snapshotSinceOpen
                    // `backlog-complete` carries no state but this flag. On an account with
                    // nothing to list it moves nothing else at all, so leaving it out would
                    // drop the frame as a duplicate and spin "Loading buffers…" forever on
                    // exactly the account the empty state was written for.
                    && $0.backlogComplete == $1.backlogComplete
                    // The Friends/Favorites sections render off these two: the favorites
                    // list and the per-nick presence DM names are styled by. A friend going
                    // away is a presence change with no buffer change, so without these the
                    // name never dims.
                    && $0.favorites == $1.favorites
                    && $0.peerPresence == $1.peerPresence
                    // Muting is an ignore rule (lurker #359), so a mute set on another device
                    // moves nothing else on this screen — without this, a badge stays loud
                    // until some unrelated change happens to let a rebuild through.
                    // (`===` is the right test — see `IgnoreSet`.)
                    && $0.ignores === $1.ignores
                    // ⚠⚠ Pins order every network section, and a `pins-changed` frame moves
                    // NOTHING else in the state — so without this the frame is dropped as a
                    // duplicate, `apply` never runs, and a pin set on the web moves nothing
                    // here until some unrelated message happens to let a rebuild through.
                    // Worse than a late redraw: `self.state` is never updated either, so even
                    // the `viewWillAppear` rebuild would use the stale pins. Exactly the
                    // failure the favorites and ignores lines above already document.
                    && $0.pinned == $1.pinned
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)
    }

    /// Coming back from a buffer rebuilds, always — not just when state moved under us:
    /// `apply` skips the rebuild while this screen is covered, so whatever changed in the
    /// meantime is drawn here, before the pop reveals it.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        rebuild()
        // The toolbar carrying the search field belongs to the *navigation controller*, and the
        // screen pushed over this one ends in a composer — so it can't simply stay up. Asked
        // for on the way in and given back on the way out, which also means it animates with
        // the transition rather than appearing after it.
        if usesBottomSearchBar { navigationController?.setToolbarHidden(false, animated: animated) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshBanner()
        if usesBottomSearchBar { navigationController?.setToolbarHidden(true, animated: animated) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
    }

    /// Show the banner only once this screen is genuinely frontmost, and hide it the instant a
    /// push begins — the chat screen carries its own at the same position, so without this the
    /// two draw over each other for the length of every transition, and VoiceOver hears the
    /// same string from two `.updatesFrequently` elements.
    ///
    /// `viewDidAppear`/`viewWillDisappear` rather than the `viewWillAppear`/`viewDidDisappear`
    /// pair `isOnScreen` uses, because these two are the edges where `topViewController` has
    /// already moved: a push has re-pointed it before the outgoing screen's `viewWillDisappear`,
    /// and an interactive back-swipe doesn't re-point it until the pop actually commits — so a
    /// cancelled swipe never flashes this screen's banner over the chat screen's.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshBanner()
    }

    private func refreshBanner() {
        // Side by side, both screens are in the window and each is the top of its own column's
        // stack — so without the third condition the banner the comment above says must never
        // be drawn twice is drawn twice, and read out twice. This one yields, as it does when
        // pushed over on the phone.
        let isFrontmost = view.window != nil
            && navigationController?.topViewController === self
            && !marksOpenBuffer
        connectionBanner.update(isFrontmost ? bannerState : .hidden)
    }

    /// The new state is always kept — it's what the deferred menus and the next rebuild read —
    /// but the rebuild itself waits until anyone can see the result.
    private func apply(_ state: ChatState) {
        self.state = state
        // The title is in the bar, not the list, so it tracks connection regardless of
        // whether the roster below is worth rebuilding. `apply` no-ops when nothing it shows
        // has moved.
        navigationItem.apply(statusTitle)
        // The banner is about the connection, not the roster, so its *state* is tracked on
        // every apply regardless of whether the list below is worth rebuilding.
        bannerState = ConnectionBannerState.of(reachable: state.reachable, connection: state.connection)
        refreshBanner()
        guard isOnScreen else { return }
        rebuild()
    }

    /// The system buffer is app-scoped and always exists, so fall back to the synthetic one
    /// if its row hasn't arrived from the server yet — the same fallback its list row used.
    private func openSystemBuffer() {
        onSelect?(state.buffers[Buffer.system.key.id] ?? .system)
    }

    /// Rebuild the section model, then touch the view as narrowly as the change allows.
    ///
    /// A message arriving anywhere bumps an unread count, which lands here — but the buffers,
    /// their order, and the section headers are all unchanged, so only some cells' numbers
    /// moved. Reconfiguring just those cells reuses them in place; a full `reloadData` drops
    /// the whole layout, and mid-scroll that shows as a hitch. A genuinely structural change
    /// (a buffer opened or closed, a network connecting, favorites reordered) still reloads.
    ///
    /// **Deferred entirely while a drag is up (#53).** Every frame that arrives lands here, so
    /// the odds of one during the seconds a row is held are not small — and a `reloadData`
    /// under a live drag resets the layout the drag is drawing against and invalidates the
    /// index paths the drop will be resolved with. So the rebuild waits for
    /// `dragSessionDidEnd`, which runs on both a completed drop and a cancelled one. Nothing is
    /// lost by waiting: `state` is already current, and the rebuild it feeds runs the moment
    /// the hand comes off.
    private func rebuild() {
        guard !collectionView.hasActiveDrag else {
            rebuildDeferredByDrag = true
            return
        }
        rebuildDeferredByDrag = false

        // ⚠⚠ Nothing is drawn until the connect burst has finished.
        //
        // The burst arrives a frame at a time and each one lands here, so the list used to
        // assemble itself in front of the reader: a network's roster before its name, a
        // favorite still sitting in its network section until the favorites frame landed, a
        // whole network appearing halfway through. Eight visible states on the way to the
        // right one, and only the last is true. The spinner exists for exactly this and never
        // got the chance — `BufferListPlaceholder.of` returns `.none` the moment any buffer
        // exists, which during a burst is almost immediately.
        //
        // Only for the FIRST list of a session. After that a resync re-opens the burst with a
        // populated screen, and blanking it to a spinner because the server is re-sending
        // what we already have would be the same flicker wearing the opposite hat — the list
        // stays true while the burst runs and updates when it settles.
        //
        // ⚠⚠ `hasRenderedList` is NEVER reset here. It used to be cleared whenever
        // `backlogComplete` was false — meant as "a fresh session waits again" — which
        // silently disarmed the fallback below: the timer set the flag, called `rebuild`, and
        // this line cleared it again, so the list blanked and re-armed on a 4-second loop
        // forever. On a server that never sends the terminator that is a permanent flashing
        // spinner over a full store: the exact failure the fallback exists to prevent, caused
        // by the fallback. A new session gets a new screen anyway — sign-out replaces the
        // navigation stack and sign-in builds this controller fresh — so the instance's own
        // `false` is the reset, and nothing has to notice a session change to do it.
        guard state.rosterSettled || hasRenderedList else {
            sections = []
            entriesByID = [:]
            if !dataSource.snapshot().sectionIdentifiers.isEmpty {
                dataSource.apply(NSDiffableDataSourceSnapshot<SectionID, ItemID>(), animatingDifferences: false)
            }
            updatePlaceholder()
            armBurstFallback()
            return
        }
        burstFallback?.cancel()
        burstFallback = nil
        hasRenderedList = true

        let previous = entriesByID
        sections = buildSections(state)
        let entries = sections.map(\.entries)
        indexEntries(entries)
        updatePlaceholder()

        var snapshot = NSDiffableDataSourceSnapshot<SectionID, ItemID>()
        snapshot.appendSections(sections.map(\.id))
        for (section, items) in zip(sections, entries) {
            snapshot.appendItems(items.map(\.0), toSection: section.id)
        }
        // Identity alone can't see an item whose *contents* moved — an unread count, a peer's
        // presence, a network going offline — because those don't change the item's
        // identifier. Naming them keeps the cheap path cheap: everything else in the snapshot
        // is left exactly as it is.
        //
        // Headers are items, so this covers them too. They used to be section headers, which a
        // snapshot can't reconfigure at all — a network kept showing "Unnamed network" after
        // its name arrived until the header scrolled off and back — and fixing that needed a
        // separate record of every title drawn and a `reloadSections` for the ones that moved.
        let restyled = snapshot.itemIdentifiers.filter { id in
            guard let was = previous[id], let now = entriesByID[id] else { return false }
            return was != now
        }
        if !restyled.isEmpty { snapshot.reconfigureItems(restyled) }
        // Never animated: this runs on every frame that changes the roster, and a list that
        // slides every time someone speaks is a list you can't read.
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Show a centered placeholder when the list has no rows, so a blank screen always says
    /// which kind of blank it is.
    ///
    /// Keyed on `backlogComplete` — the `backlog-complete` terminal frame — and neither on the
    /// socket being up nor on the `snapshot` frame having arrived. Both of those are prefixes
    /// of the answer rather than the answer, and each flashes the empty state on a different
    /// kind of account; `ChatState.backlogComplete` spells out which and why.
    ///
    /// Whether the connection is the reason nothing has landed is the banner's question, not
    /// this one's — so an offline launch shows the spinner *and* the banner, each answering
    /// its own.
    private func updatePlaceholder() {
        let placeholder = BufferListPlaceholder.of(
            hasBuffers: !sections.isEmpty,
            hasNetworks: !state.networks.isEmpty,
            backlogComplete: state.backlogComplete
        )
        guard placeholder != shownPlaceholder else { return }
        shownPlaceholder = placeholder
        switch placeholder {
        case .none:
            collectionView.backgroundView = nil
        case .loading:
            placeholderView.configure(.init(title: "Loading buffers…", isLoading: true))
            collectionView.backgroundView = placeholderView
        case .noNetworks:
            // The button is the whole point of this state now: it used to say "add a network"
            // to a person with nowhere to do it, which is the dead end #11 exists to close.
            placeholderView.configure(.init(
                symbol: "bubble.left.and.bubble.right",
                title: "No networks yet",
                subtitle: "Add a network to start a conversation.",
                actionTitle: "Add Network"
            ))
            collectionView.backgroundView = placeholderView
        case .noBuffers:
            // They've done the adding already — the next step is joining something, and
            // saying "add a network" here would read as the app not knowing its own state.
            placeholderView.configure(.init(
                symbol: "bubble.left.and.bubble.right",
                title: "No buffers yet",
                subtitle: "Join a channel or start a DM to see it here."
            ))
            collectionView.backgroundView = placeholderView
        }
    }

    // MARK: - Layout

    /// One plain list, section by section: a section per group, each opening with its header
    /// item, no separators, and a gap under each group for the rule over the next.
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            // Named rather than left to the plain appearance's default, which happens to be the
            // same colour today: the list section repaints the collection view in whatever this
            // says, over the ground set in `viewDidLoad`.
            config.backgroundColor = .rosterGround
            // The header is an item, not a supplementary view: a network's header is a buffer
            // you can open, and an item is what can be tapped, marked open, and reconfigured
            // when its network's state changes.
            config.headerMode = .none
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipe(at: indexPath)
            }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: 0, bottom: RosterMetrics.groupGap, trailing: 0
            )
            return section
        }
    }

    // MARK: - Cell registrations

    private lazy var rowRegistration = UICollectionView.CellRegistration<BufferRowCell, Row> {
        [weak self] cell, _, row in
        guard let self else { return }
        let font = listFont(italic: false)
        cell.configure(
            // No server log reaches a row — it's its network's header — so there's no network
            // name for `displayName` to fall back on.
            name: row.buffer.displayName(),
            // An offline person's name is italic (#167).
            font: row.presence?.italicizesName == true ? listFont(italic: true) : font,
            hintFont: font,
            networkName: row.networkName,
            networkHint: row.networkHint,
            unread: row.displayUnread,
            highlights: row.buffer.highlights,
            presence: row.presence,
            parted: row.parted,
            isOpen: isOpen(row.buffer),
            guide: row.guide
        )
    }

    private lazy var headerRegistration = UICollectionView.CellRegistration<RosterHeaderCell, Header> {
        [weak self] cell, _, header in
        guard let self else { return }
        cell.configure(
            title: header.title,
            font: listFont(italic: false),
            light: header.light,
            state: header.state,
            unread: header.log?.displayUnread ?? 0,
            highlights: header.log?.buffer.highlights ?? 0,
            ruleAbove: header.ruleAbove,
            opensLog: header.log != nil,
            isOpen: header.log.map { self.isOpen($0.buffer) } ?? false
        )
    }

    private lazy var pinBreakRegistration = UICollectionView.CellRegistration<PinBreakCell, Void> { _, _, _ in }

    /// The one face this list is set in: the compact message log's, so the list and the log
    /// beside it read as one surface. Italic for an offline peer (#167).
    ///
    /// Built from THIS screen's traits, the rule `MemberListViewController` and `MessageRenderer`
    /// follow: a cell's own traits aren't settled while it's configured. A font set this way no
    /// longer tracks text size by itself, so a text-size change reconfigures every item to build
    /// it again (see `viewDidLoad`).
    private func listFont(italic: Bool) -> UIFont {
        let font = MessageRenderer.compactFont(compatibleWith: traitCollection)
        return italic ? font.italic : font
    }

    /// The list, handed over whole.
    ///
    /// ⚠⚠ Diffable rather than the manual data source this had, and the reason is identity.
    /// The old one answered `numberOfSections`/`cellForItemAt` out of an array, so a section
    /// *was* its index — and the indices shift as sections arrive during the connect burst.
    /// Everything keyed off position went with them: the layout's grid-or-list decision (the
    /// list had grids then), the header's title, the collection view's cached self-sizing metrics. Rows stayed correct
    /// and the picture didn't.
    ///
    /// `SectionID`/`ItemID` make identity explicit, so a section that moves takes its
    /// geometry with it and UIKit computes the moves itself from one snapshot.
    private lazy var dataSource: UICollectionViewDiffableDataSource<SectionID, ItemID> = {
        UICollectionViewDiffableDataSource<SectionID, ItemID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self, let entry = entriesByID[item] else { return UICollectionViewCell() }
            switch entry {
            case let .header(header):
                return collectionView.dequeueConfiguredReusableCell(
                    using: headerRegistration, for: indexPath, item: header
                )
            case let .buffer(row):
                return collectionView.dequeueConfiguredReusableCell(
                    using: rowRegistration, for: indexPath, item: row
                )
            case .pinBreak:
                return collectionView.dequeueConfiguredReusableCell(
                    using: pinBreakRegistration, for: indexPath, item: ()
                )
            }
        }
    }()

    /// Gives up waiting for `backlog-complete` and draws whatever has arrived.
    ///
    /// ⚠⚠ Not belt-and-braces — the terminator genuinely may not come. It was added as an
    /// ADDITIVE frame with no protocol-version bump and no capability signal (lurker#640), so
    /// a self-hosted server older than it simply never sends one, and this is a product whose
    /// operators upgrade on their own schedule. A current server withholds it too when a
    /// burst throws part-way, which is deliberate: it is emitted from inside
    /// `sendSnapshotInner` precisely so a failed burst isn't declared complete.
    ///
    /// Without this, waiting for it would trade a flicker for a permanent spinner over a
    /// fully populated store — a far worse trade. The wait is the optimization; drawing is
    /// the correct behaviour, so the fallback is the one that has to be unconditional.
    private var burstFallback: DispatchWorkItem?
    /// Long enough that any burst worth waiting for lands first, short enough that a server
    /// which never terminates one isn't a broken app.
    private static let burstWait: TimeInterval = 4

    private func armBurstFallback() {
        guard burstFallback == nil else { return } // already counting
        let work = DispatchWorkItem { [weak self] in
            guard let self, !hasRenderedList else { return }
            burstFallback = nil
            hasRenderedList = true
            rebuild()
        }
        burstFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstWait, execute: work)
    }

    /// Whether a settled list has been drawn this session — see the wait at the top of
    /// `rebuild`. Reset when the store is, so signing into another account waits again.
    private var hasRenderedList = false

    /// Every item on screen, by identity — what the cell provider configures from, since a
    /// snapshot carries identifiers and not content.
    private var entriesByID: [ItemID: Entry] = [:]

    /// Rebuild `entriesByID` from every section's entries, built once by the caller.
    private func indexEntries(_ entries: [[(ItemID, Entry)]]) {
        entriesByID = Dictionary(
            entries.joined(),
            // `ItemID` is section-qualified and `Section.init` de-duplicates its rows, so a
            // collision here is impossible rather than merely unlikely — keep the first and
            // move on rather than trapping on it in front of a user.
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Which conversation is open (side by side)

    /// The buffer showing in the split's conversation column, or nil.
    ///
    /// Drawn only side by side — under a conversation rather than beside one, a row left
    /// marked after you navigate away is stale emphasis. `marksOpenBuffer` gates the drawing,
    /// so this stays set through a collapse and the mark comes back on expanding.
    private var openBufferKey: BufferKey?

    /// Whether this list is beside a conversation rather than under one.
    ///
    /// Pushed in by `BufferSplitViewController` rather than read from `isCollapsed`: the moment
    /// it matters is a resize into or out of Slide Over, or an iPhone Duo opening or closing,
    /// which is exactly when that property still answers for the layout being left. False
    /// whenever the split is collapsed — on every iPhone but an opened Duo, all the time.
    ///
    /// It's also what decides what this screen *is*: a sidebar beside the conversation, or a
    /// screen you navigate to and back out of. On a Duo that changes under a live list, so
    /// everything that depends on it is re-applied here rather than decided once at load.
    var marksOpenBuffer = false {
        didSet {
            guard marksOpenBuffer != oldValue else { return }
            markingChanged()
            // The banner yields to the conversation column's whenever there is one, so this
            // flag flipping is exactly when that answer changes.
            refreshBanner()
            applyBarLayout()
        }
    }

    func isOpen(_ buffer: Buffer) -> Bool {
        marksOpenBuffer && buffer.key.id == openBufferKey?.id
    }

    /// Point the mark at a buffer, or clear it. Reconfigures only the rows whose answer moved,
    /// since nothing about what the list *contains* has changed.
    ///
    /// Filters every item identifier by key rather than asking for one `indexPath(for:)`:
    /// `ItemID` is section-qualified, so the key alone doesn't name an item, and a server log
    /// is marked on its network's *header*, which carries the log's key.
    func markSelection(_ key: BufferKey?) {
        guard key?.id != openBufferKey?.id else { return }
        let moved = Set([openBufferKey?.id, key?.id].compactMap { $0 })
        openBufferKey = key
        guard isViewLoaded else { return }
        var snapshot = dataSource.snapshot()
        let affected = snapshot.itemIdentifiers.filter { moved.contains($0.key) }
        guard !affected.isEmpty else { return }
        snapshot.reconfigureItems(affected)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Redraw the mark when the split collapses or expands under us — the rows are unchanged,
    /// but whether they should show a mark at all just flipped.
    private func markingChanged() {
        guard isViewLoaded, let key = openBufferKey else { return }
        var snapshot = dataSource.snapshot()
        let affected = snapshot.itemIdentifiers.filter { $0.key == key.id }
        guard !affected.isEmpty else { return }
        snapshot.reconfigureItems(affected)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Bar items

    /// Account and settings: the things that outlast whichever conversation you're reading.
    /// It lives here rather than on the chat screen's "…" because that one is a list of
    /// *views* — and because sign-out sitting next to "Members" put the end of your session
    /// one slipped thumb from a nick list.
    ///
    /// A cog rather than a second ellipsis, now that this screen has a real views menu of its
    /// own on the trailing side: two identical "…" on one bar would be two buttons that look
    /// like the same button. It's where Settings (#20) lands, so the icon is also honest
    /// about where it's going.
    /// A direct tap now that Settings exists (#20) — the cog said "Settings" and opened a
    /// one-item menu, which is a menu standing in for the screen it was named after. Sign-out
    /// moved inside, where it sits behind a confirmation rather than one slipped thumb away.
    ///
    /// Folded into the "…" menu side by side — see `applyBarLayout`.
    private lazy var settingsItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in self?.showSettings() }
        )
        item.accessibilityLabel = "Settings"
        return item
    }()

    /// Fit the bar to what this screen currently is: a screen of its own or a sidebar, and a
    /// bar across the top or a rail down the side.
    ///
    /// Side by side the sidebar is kept to the title, "+" and "…". The views (Highlights,
    /// Bookmarks, Uploads) and search are the conversation column's there, where the bar has
    /// room to show them as buttons rather than menu rows, and a copy here would be the same
    /// button twice on one screen. Settings folds into the "…" menu, which is left holding the
    /// app-wide entries — see `viewsMenuElements`.
    ///
    /// On its own screen this is the phone's list: the cog, the views menu and the search field,
    /// because nothing else on screen carries them.
    ///
    /// In an iPhone Duo's vertical rail there's height to spare, so the "…" opens out: every
    /// entry it would have held is a button of its own, in either layout.
    private func applyBarLayout() {
        let layout = BarLayout(sidebar: marksOpenBuffer, rail: traitCollection.hasVerticalBar)
        // Replaced only when the layout moves — replacing an item closes a menu it's showing,
        // and re-placing the search field under a live one can collapse it.
        guard layout != barLayout else { return }
        let sidebarChanged = layout.sidebar != barLayout?.sidebar
        barLayout = layout
        if sidebarChanged { applySearchPlacement() }
        // A sidebar's title reads from the leading edge, like a Duo rail's and like Mail's
        // mailbox column — centred over a narrow column it floats between the edge and the
        // buttons. `.browser` is the style that leads the title; the list is a root, so the
        // back-button behaviour that style also changes never comes up. On its own screen it
        // keeps the phone's centred title.
        navigationItem.style = layout.sidebar ? .browser : .navigator
        // First element is the *trailing-most*, so this reads "+ then …" left to right — the
        // views menu sits in the same corner it occupies on the chat screen, so the one button
        // that means the same thing on both screens is in the same place on both. Opened out,
        // the Lurker buffer keeps that corner.
        let views: [UIBarButtonItem] = !layout.rail ? [viewsItem]
            : layout.sidebar ? [lurkerItem, settingsItem]
            : [lurkerItem, uploadsItem, bookmarksItem, highlightsItem]
        // The cog changes sides when a rail's sidebar becomes a rail's stack or back, and an
        // item mustn't sit in both groups at once — so it leaves the left before the right is
        // set, and returns to the left only after.
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItems = views + [joinItem]
        if !layout.sidebar { navigationItem.leftBarButtonItem = settingsItem }
    }

    private struct BarLayout: Equatable {
        var sidebar: Bool
        var rail: Bool
    }

    /// What the bar was last laid out for.
    private var barLayout: BarLayout?

    /// Presented as a sheet, like every other secondary surface off this screen (buffer info,
    /// members, highlights) — Settings is somewhere you visit and leave, not somewhere the
    /// navigation stack should hold on to.
    private func showSettings() {
        guard presentedViewController == nil, navigationController?.presentedViewController == nil else { return }
        let sheet = UINavigationController(rootViewController: SettingsViewController(viewModel: viewModel))
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        sheet.sheetPresentationController?.detents = [.large()]
        present(sheet, animated: true)
    }

    // MARK: - Search

    /// The results, and the object that turns keystrokes into queries. Held so navigation can
    /// wire its jump once, at construction, exactly as it wires this screen's row taps.
    private(set) lazy var searchResults = MessageSearchViewController(
        viewModel: viewModel, presentation: .resultsController
    )

    private lazy var searchController = searchResults.makeHostedSearchController()

    /// Put the search field in the bottom bar, which on iOS 26 is where search goes on a
    /// phone — within reach of the thumb that's already holding the device, rather than at the
    /// top of the one screen you're most likely to be one-handed on.
    ///
    /// `.integrated` is what asks for that: on iPhone, UIKit folds an integrated search bar
    /// into the view controller's toolbar when it has one, and `searchBarPlacementBarButtonItem`
    /// is the slot saying where among the toolbar's items it lands. It's the only item, so it
    /// takes the bar.
    ///
    /// This is the exception to this screen's "no bottom toolbar" rule, and it's the case that
    /// rule was drawn around: the objection was to *a second floating bar to hold two buttons
    /// that already fit in the navigation bar*. A search field isn't a button — it can't live
    /// in the nav bar at a useful width, it's the one control here you use with your thumb, and
    /// the system puts it here. What the rule was really protecting (the toolbar can't survive
    /// the push into a chat screen, whose bottom is a composer) still holds and is still
    /// handled — see `viewWillAppear`.
    ///
    /// Side by side there's no field here at all: the conversation column carries it, at the
    /// trailing edge of its bar (`ChatViewController.applyBarLayout`). Not
    /// `searchBarPlacementAllowsExternalIntegration`, which draws this screen's field over there
    /// — measured on iPad, it then presents the results in THIS column, a 320pt strip beside the
    /// field you're typing into.
    ///
    /// Re-run whenever the split expands or collapses, since on an iPhone Duo that happens to a
    /// list that's already on screen.
    private func applySearchPlacement() {
        if marksOpenBuffer {
            // Taken down before the field is removed, and removed a turn later: this runs from
            // the split's layout pass, and pulling a search controller out from under its own
            // dismissal mid-transition is the shape of a UIKit crash NetNewsWire hit on expand.
            if searchController.isActive {
                searchController.isActive = false
                DispatchQueue.main.async { [weak self] in self?.applySearchPlacement() }
                return
            }
            navigationItem.searchController = nil
            toolbarItems = nil
        } else {
            navigationItem.searchController = searchController
            if usesBottomSearchBar {
                navigationItem.preferredSearchBarPlacement = .integrated
                toolbarItems = [navigationItem.searchBarPlacementBarButtonItem]
            } else {
                // An iPad list on its own screen — Slide Over, a narrow window.
                navigationItem.preferredSearchBarPlacement = .stacked
                toolbarItems = nil
            }
        }
        // The toolbar is the navigation controller's, and `viewWillAppear`/`Disappear` raise
        // and lower it on navigation — a layout change isn't a navigation, so do it here, but
        // only while this list is what that controller is showing. Collapsed with a chat on
        // top, the composer owns the bottom edge and the toolbar stays down.
        guard isOnScreen, navigationController?.topViewController === self else { return }
        navigationController?.setToolbarHidden(!usesBottomSearchBar, animated: false)
    }

    /// Whether the search field is riding a bottom toolbar this screen has to raise and lower.
    ///
    /// Only on an iPhone, and only while this list is its own screen. The idiom is right here
    /// where it's wrong for layout: folding an `.integrated` field into the toolbar is a
    /// behaviour UIKit has only on iPhone, and on iPad the same placement lands in the nav bar,
    /// where UIKit drops trailing items to fit it rather than overflowing them. Beside a
    /// conversation there's no field here and no toolbar — asking for one would raise an empty
    /// bar across the foot of the column.
    private var usesBottomSearchBar: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && !marksOpenBuffer
    }

    /// Take the search UI down — what a result tap calls once it's decided where to go. Not a
    /// dismiss: the results are presented *by* the search controller, so the thing to undo is
    /// its activation, which also empties the field for the next time search is opened.
    func dismissSearch() {
        searchController.isActive = false
    }

    /// The app-wide menu: the Lurker buffer, plus whatever else this layout has no other place
    /// for.
    ///
    /// On its own screen that's the views — Highlights, Bookmarks and Uploads, the same menu
    /// the chat screen carries minus the entries that need a buffer. They're app-scoped (they
    /// span every network), so being able to reach them only from inside some arbitrary
    /// conversation was an artifact of the chat screen having once been the only screen. Search
    /// isn't here: its field is already in the bottom bar.
    ///
    /// Side by side the conversation column shows the views as buttons of its own, so here
    /// they'd be the same thing twice on one screen; this menu holds Settings instead, the cog
    /// having left the sidebar to keep it to "+" and "…".
    ///
    /// **Deferred**, so which of the two it offers is decided when it opens rather than
    /// whenever the item was built — an iPhone Duo opens and closes under a live list.
    ///
    /// Members is deliberately absent: it describes a channel, and there isn't one here.
    private lazy var viewsItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.viewsMenuElements() ?? [])
                },
            ])
        )
        item.accessibilityLabel = "More"
        return item
    }()

    private func viewsMenuElements() -> [UIMenuElement] {
        // Set apart at the top because it's a buffer you open, not a view over all of them.
        let head = UIMenu(options: .displayInline, children: [
            AppView.lurker.action { [weak self] in self?.openSystemBuffer() },
        ])
        guard !marksOpenBuffer else {
            return [head, UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.showSettings()
            }]
        }
        return [
            head,
            AppView.highlights.action { [weak self] in self?.openHighlights() },
            AppView.bookmarks.action { [weak self] in self?.openBookmarks() },
            AppView.uploads.action { [weak self] in self?.openUploads() },
        ]
    }

    // The "…" menu's entries opened out, for a vertical rail (`applyBarLayout`). The Lurker
    // buffer has no row in the list; the menu, or this button, is its door.

    private lazy var lurkerItem = AppView.lurker.barItem { [weak self] in self?.openSystemBuffer() }
    private lazy var highlightsItem = AppView.highlights.barItem { [weak self] in self?.openHighlights() }
    private lazy var bookmarksItem = AppView.bookmarks.barItem { [weak self] in self?.openBookmarks() }
    private lazy var uploadsItem = AppView.uploads.barItem { [weak self] in self?.openUploads() }

    private func openHighlights() { showHighlights(viewModel: viewModel) }
    private func openBookmarks() { showBookmarks(viewModel: viewModel) }

    /// ⚠ No `onInsert`. There is no composer mounted behind this screen, so an "Add to Message"
    /// offered from here would land nowhere and report nothing. Copy Link and Share are the
    /// answers from the list, and both are in the same menu on the tile.
    private func openUploads() { showUploads(viewModel: viewModel) }

    // MARK: - Joining

    /// Join — "one more of these" — opposite the account menu.
    ///
    /// Its menu is **deferred**, so which networks it offers is decided when you tap it
    /// rather than whenever the item happened to be built. That's what lets this be a menu
    /// at all: the item is built once and never replaced, and it was *replacing* a bar item
    /// on every unread count that previously closed the menu out from under whoever had it
    /// open. Deferring is the fix; rebuilding is the bug.
    ///
    /// Carries "Add Network…" alongside the channels (#11): both are "one more of these", and
    /// the two are the same question at different scales — a channel on a network you have,
    /// or a network to have channels on. It sits last, under a separator, because it is the
    /// rarer of the two by a wide margin.
    private lazy var joinItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let self else { return completion([]) }
                    // Friends are made from a DM or member row now ("Add to
                    // Friends" — one favorites flag), so the + is joins and networks.
                    completion(self.joinElements() + [self.addNetworkElement()])
                },
            ])
        )
        item.accessibilityLabel = "Add"
        return item
    }()

    /// One entry, whatever the account looks like.
    ///
    /// It used to be a row per network, on the reasoning that a menu of one is a tap spent to
    /// learn nothing. But that put the *rarer* half of the decision first — which network is
    /// a question most accounts answer the same way every time — and made the menu grow with
    /// the account, so five networks meant five rows to read past on the way to the one text
    /// field you came for. The picker moved inside the sheet, under the channel name, where
    /// it has a default and can be ignored.
    ///
    /// Enabled even when nothing is connected: the sheet names each network's state and
    /// disables Join, which says why. A greyed-out menu row says nothing at all.
    private func joinElements() -> [UIMenuElement] {
        guard !state.networks.isEmpty else {
            return [UIAction(title: "No networks", attributes: .disabled) { _ in }]
        }
        return [UIAction(title: "Join Channel…", image: UIImage(systemName: "number")) { [weak self] _ in
            self?.showJoinChannel()
        }]
    }

    private func showJoinChannel() {
        guard presentedViewController == nil, navigationController?.presentedViewController == nil else { return }
        let sheet = UINavigationController(
            rootViewController: JoinChannelViewController(viewModel: viewModel) { [weak self] network, channel in
                self?.join(network: network, channel: channel)
            }
        )
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        // ⚠ Large, not medium. A sheet presentation doesn't change detent when the keyboard
        // comes up, and this sheet raises it on appear — at medium the keyboard would cover
        // the network picker entirely, which is the half of the sheet this whole change was
        // made to introduce. `showAddNetwork` already reached the same answer.
        sheet.sheetPresentationController?.detents = [.large()]
        present(sheet, animated: true)
    }

    /// "Add Network…" as its own inline section, so the separator does the work of saying it
    /// is a different kind of thing from the channel entries above it.
    private func addNetworkElement() -> UIMenuElement {
        UIMenu(options: .displayInline, children: [
            UIAction(title: "Add Network…", image: UIImage(systemName: "network")) { [weak self] _ in
                self?.showAddNetwork()
            },
        ])
    }

    /// Adding a network, in its own sheet — reached from here without going through Settings,
    /// because the account with no networks is exactly the one that can't find Settings'
    /// Networks row and shouldn't have to.
    ///
    /// Picker first, then the form pushed on top of it: a blank hostname field is the wrong
    /// first question for the person most likely to be asking it.
    private func showAddNetwork() {
        guard presentedViewController == nil, navigationController?.presentedViewController == nil else { return }
        let picker = NetworkPickerViewController(
            viewModel: viewModel,
            onCancel: { [weak self] in self?.dismiss(animated: true) }
        ) { [weak self] draft in
            // ⚠⚠ The sheet is reached through `self`, not through a captured local. Holding
            // it in a `var` the closure closes over is a retain cycle — the capture box holds
            // the navigation controller, which holds the picker, which holds this closure —
            // and it leaks the whole sheet (search controller, 95-row table, any pushed form)
            // on every single "Add Network", whether or not anything is picked.
            guard let self, let sheet = presentedViewController as? UINavigationController else { return }
            sheet.pushViewController(
                NetworkFormViewController(viewModel: viewModel, draft: draft) { [weak self] in
                    // The whole sheet goes: this screen isn't a networks list, so there is
                    // nothing here to come back to — the new network's buffers arriving IS
                    // the result.
                    self?.dismiss(animated: true)
                },
                animated: true
            )
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        navigation.sheetPresentationController?.detents = [.large()]
        present(navigation, animated: true)
    }

    /// Joining is also switching: you asked for a channel, so land in it — once the server says
    /// you're in (#57). Nothing is pushed before then. A join can be refused, and a screen for a
    /// channel you never got into had nothing to show and no way to learn it never would.
    /// `requestJoin` opens the channel when `channel-joined` lands, and says why when it doesn't.
    private func join(network: Network, channel typed: String) {
        // A bare sigil is not a name: `ensurePrefix("#")` would send a JOIN for "#".
        guard ChannelName.namesAChannel(typed) else { return }
        // ⚠ The TRIMMED name. `namesAChannel` trims before testing — that's the point of it
        // owning the rule — so passing the raw string on means " #swift" clears the guard and
        // then gets a sigil prepended to a leading space: `JOIN "# #swift"`. Latent only
        // because the join sheet happens to trim first.
        let channel = ChannelName.ensurePrefix(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        viewModel.requestJoin(networkId: network.id, channel: channel, opens: true)
    }

    // MARK: - Sections

    private func buildSections(_ state: ChatState) -> [Section] {
        // Partition the favorites list ONCE — the sections and the roster exclusion both
        // derive from the same two slices, so a future classification change can't update one
        // walk and miss another (the double-printed-DM bug the split exists to prevent).
        let orderedFavorites = orderedFavorites(state)
        let friendEntries = orderedFavorites.filter(Self.isFriendEntry)
        let channelEntries = orderedFavorites.filter { !Self.isFriendEntry($0) }
        // ⚠⚠ A favorite is a RELOCATION, not a shortcut. Its row under Friends or Favorites is
        // where it lives, so it's hidden from its network's group rather than printed twice —
        // matching the web, where `isFavoriteBuf` filters favorites out of both the pinned
        // and unpinned halves of every network group.
        let favoriteKeys = Set(orderedFavorites.map(\.key.id))

        let byNetwork = BufferOrder.byNetwork(state.buffers.values, excluding: favoriteKeys)
        // Before the favorites exclusion, because a network whose every open buffer is
        // favorited still exists and still has a log — see `withServerLog`.
        let networksInUse = Set(state.buffers.values.compactMap(\.networkId))

        var sections: [Section] = []

        var favorites = favoriteRows(channelEntries, state)
        var friends = friendRows(friendEntries, state)
        // Abbreviations are per-account, so they're computed once and shared by both groups;
        // they're measured against every network the user has, not the ones on screen, which
        // is also what the web computes for the same rows (see `NetworkAbbreviation`).
        let abbreviations = NetworkAbbreviation.shortestUniquePrefixes(state.networks.mapValues(\.displayName))
        Self.addNetworkHints(abbreviations, &friends)
        Self.addNetworkHints(abbreviations, &favorites)
        // Friends first, then Favorites — the web sidebar's order (FRIENDS above FAVORITES),
        // and the two are one list on the server, so the halves reading top-to-bottom
        // differently was a needless thing to have to re-learn per client. People also earn
        // the top slot on their own: theirs are the rows whose presence changes while you look.
        //
        // Both are reorderable since lurker#721 — the order is the server's global favorites
        // order, shared with the web client.
        if !friends.isEmpty {
            sections.append(Section(id: .friends, header: Header(title: "Friends"), rows: friends))
        }
        if !favorites.isEmpty {
            sections.append(Section(id: .favorites, header: Header(title: "Favorites"), rows: favorites))
        }

        // The user's own order, not ours: they arranged their networks on the web, and a
        // phone that re-alphabetises them is a phone you have to re-read every time you pick
        // it up. Same for the pins inside each one.
        var seen = Set<Int>()
        for network in BufferOrder.networks(state.networks) {
            seen.insert(network.id)
            // `withServerLog`, so a network in use always has its log and therefore a header —
            // the server row used to come and go with the connect burst's prune.
            let buffers = BufferOrder.withServerLog(
                byNetwork[network.id] ?? [],
                networkId: network.id,
                networkHasOpenBuffers: networksInUse.contains(network.id)
            )
            guard let section = networkSection(.network(network.id), network.id, network, buffers, state)
            else { continue }
            sections.append(section)
        }
        // Buffers whose network isn't in the roster yet (snapshot race). Sorted, because a
        // dictionary's order isn't stable from one rebuild to the next.
        //
        // With its log synthesized like a rostered network's, so the header is the way into the
        // log here too rather than a label you can't open.
        for networkId in byNetwork.keys.sorted() where !seen.contains(networkId) {
            let buffers = BufferOrder.withServerLog(
                byNetwork[networkId] ?? [], networkId: networkId, networkHasOpenBuffers: true
            )
            guard let section = networkSection(.unrostered(networkId), networkId, nil, buffers, state)
            else { continue }
            sections.append(section)
        }

        // The rule sits BETWEEN groups, so the first one doesn't draw it.
        for index in sections.indices.dropFirst() { sections[index].header.ruleAbove = true }
        return sections
    }

    /// One friend per favorited DM — the DM slice of the server's favorites list, in the user's
    /// global order (shared with the web client's FRIENDS section since lurker#721).
    private func friendRows(_ entries: [FavoriteEntry], _ state: ChatState) -> [Row] {
        entries.map { entry in
            // `buffer(for:)` resolves an existing DM (keeping its server-cased target and
            // unread count) or synthesizes an unhydrated one to open — the same handoff the
            // join flow uses, so tapping the row hydrates on the chat screen.
            let buffer = state.buffer(for: entry.key)
            return Row(
                buffer: buffer,
                networkName: state.networks[entry.networkId]?.displayName,
                presence: state.rowPresence(networkId: entry.networkId, nick: entry.target),
                isFriend: true,
                muted: Self.isMuted(buffer, state)
            )
        }
    }

    /// A favorites entry that belongs under Friends: a DM, classified the way the server
    /// does (so '&'/'+'/'!' channels never masquerade as people).
    ///
    /// `nonisolated` like `order`/`sortKey`, and for the same reason: it's a pure function of
    /// its argument, touching no view state. Without it, passing it to `filter` **by name**
    /// converts a main-actor-isolated function to a non-isolated function type, which Swift
    /// concurrency warns about — the `{ !Self.isFriendEntry($0) }` form beside it doesn't
    /// warn only because a non-escaping closure inherits the caller's isolation. Marking the
    /// function is the honest fix; wrapping it in a closure just hides the question.
    private nonisolated static func isFriendEntry(_ entry: FavoriteEntry) -> Bool {
        BufferKind.of(networkId: entry.networkId, target: entry.target) == .dm
    }

    /// Favorited channels — the channel slice of the server's global favorites order
    /// (lurker#721, shared with the web client's FAVORITES section; the old device-local
    /// UserDefaults list migrated up on first connect).
    private func favoriteRows(_ entries: [FavoriteEntry], _ state: ChatState) -> [Row] {
        entries.compactMap { entry -> Row? in
            let buffer = state.buffer(for: entry.key)
            guard buffer.kind != .system, buffer.kind != .server else { return nil }
            // No presence: this is the channel slice, and only a DM has a peer.
            return Row(
                buffer: buffer,
                networkName: buffer.networkId.flatMap { state.networks[$0]?.displayName },
                muted: Self.isMuted(buffer, state),
                parted: state.isParted(buffer.key)
            )
        }
    }

    /// `state.favorites` with the just-dropped-but-not-yet-echoed order applied. A drop
    /// permutes the local sections AND sends the reorder, but any frame that folded
    /// mid-drag releases a deferred rebuild the instant the drag ends — rebuilding from
    /// the store's PRE-drop order, which snapped the row home for a round-trip and made
    /// a quick second drag compute from the reverted base. The shadow order bridges the
    /// gap; ANY favorites change (the echo, or another device's edit) is authoritative
    /// and drops it.
    private func orderedFavorites(_ state: ChatState) -> [FavoriteEntry] {
        guard let order = optimisticFavoriteOrder else { return state.favorites }
        guard state.favorites == favoritesAtDrop else {
            optimisticFavoriteOrder = nil
            favoritesAtDrop = nil
            return state.favorites
        }
        let byId = Dictionary(state.favorites.map { ($0.bufferId, $0) }, uniquingKeysWith: { a, _ in a })
        var out = order.compactMap { byId[$0] }
        let placed = Set(order)
        out.append(contentsOf: state.favorites.filter { !placed.contains($0.bufferId) })
        return out
    }

    private func rosterRow(_ buffer: Buffer, _ state: ChatState) -> Row {
        Row(
            buffer: buffer, networkName: nil, presence: Self.peerPresence(buffer, state),
            muted: Self.isMuted(buffer, state), parted: state.isParted(buffer.key)
        )
    }

    /// A DM's peer presence, nil for anything that isn't a DM (#167). Every DM row reads it,
    /// not just Friends: a person who's away or offline looks it wherever their DM sits.
    private static func peerPresence(_ buffer: Buffer, _ state: ChatState) -> FriendPresence? {
        guard buffer.kind == .dm, let networkId = buffer.networkId else { return nil }
        return state.rowPresence(networkId: networkId, nick: buffer.target)
    }

    /// Tag the rows whose names collide **within this one group** with a short `li` network
    /// hint.
    ///
    /// Per group, not pooled across Friends and Favorites: a group is the set you actually scan
    /// as a set. Two identical names under one header are the confusion worth spending a label
    /// on; the same name under two different headers already reads as two different things.
    /// And only on a collision, because both groups are curated — you put each row there, so
    /// you know which network it's on until two of them read alike.
    ///
    /// Gated on the ACCOUNT having more than one network, which only changes when you add or
    /// remove one, so a label can't come and go under rows you never touched. The gate is a
    /// no-op for the collision itself — two rows sharing a name in one group are necessarily on
    /// different networks, a buffer key being network + target.
    ///
    /// `abbreviations` is computed once by the caller: it depends only on the account's
    /// networks, and a rebuild runs on every state change. It carries exactly one entry per
    /// network (see `NetworkAbbreviation`), which is what makes its count the gate above.
    private static func addNetworkHints(_ abbreviations: [Int: String], _ rows: inout [Row]) {
        guard abbreviations.count > 1 else { return }

        var counts: [String: Int] = [:]
        for row in rows { counts[row.buffer.target.lowercased(), default: 0] += 1 }
        let hinted = Set(counts.filter { $0.value > 1 }.keys)
        guard !hinted.isEmpty else { return }

        for index in rows.indices {
            guard hinted.contains(rows[index].buffer.target.lowercased()),
                  let networkId = rows[index].buffer.networkId,
                  let abbreviation = abbreviations[networkId]
            else { continue }
            rows[index].networkHint = abbreviation
        }
    }

    /// Whether this buffer's plain-unread signal is muted (lurker #359).
    ///
    /// Mute isn't a flag on the buffer — it's an ignore rule carrying `NOUNREAD`, which is
    /// what lets one rule mute a channel, a DM, or a whole network's worth of buffers at once.
    /// See `Row.displayUnread` for what the badge then shows.
    private static func isMuted(_ buffer: Buffer, _ state: ChatState) -> Bool {
        state.ignores.mutesUnread(networkId: buffer.networkId, target: buffer.target)
    }

    /// A network's group: its header, its pinned buffers, a break, then the rest. Nil when it
    /// has nothing to show.
    ///
    /// The server log isn't a row. It's the header — the web sidebar's shape — so the network's
    /// name is the way into its log, and the list doesn't spend a row per network saying
    /// "Server" under a header that already names the network.
    ///
    /// Pins used to be a section of their own under a "libera — pinned" header, because an iOS
    /// grouped list has no separator inside a section. A dashed break inside the group says the
    /// same thing without a second header, which is how the web draws it.
    ///
    /// `network` is nil for buffers whose network hasn't arrived in the roster yet. Its pins
    /// are read by id regardless: they ride the snapshot, not the roster, and a group drawn
    /// unpinned during the race would reshuffle the moment the roster landed.
    private func networkSection(
        _ id: SectionID, _ networkId: Int, _ network: Network?, _ buffers: [Buffer], _ state: ChatState
    ) -> Section? {
        guard !buffers.isEmpty else { return nil }
        let log = buffers.first { $0.kind == .server }
        let split = BufferOrder.split(
            buffers.filter { $0.kind != .server },
            pinned: state.pinned[networkId] ?? []
        )
        var header = Header(
            // NOT the literal "network" an unrostered group once said — that was #136's
            // placeholder surviving where its fix didn't reach, and it reads as a real name.
            title: network?.displayName ?? Network.unnamedDisplayName,
            log: log.map { rosterRow($0, state) }
        )
        if let network {
            // Layered outside-in like every other status light: while this app's own socket is
            // down, a network's last-known state is stale, and a green dot would be a claim we
            // can't make.
            header.light = StatusLight.of(
                reachable: state.reachable, connection: state.connection, network: network.state
            )
            // In words only when it's the NETWORK that isn't connected — `NetworkCopy`'s words,
            // lowercased for a header that's otherwise uppercase. When Lurker's own connection
            // is the problem, the banner already says so once for every network.
            let appUp = StatusLight.of(
                reachable: state.reachable, connection: state.connection, network: nil
            ) == .good
            if appUp, network.state != .connected { header.state = network.state.label.lowercased() }
        }
        return Section(
            id: id,
            header: header,
            pinned: split.pinned.map { rosterRow($0, state) },
            rows: split.rest.map { rosterRow($0, state) }
        )
    }

    // MARK: - Collection view delegate

    /// Buffer rows, and a network header, which opens its server log. Not the Friends and
    /// Favorites headers or the pinned break, which lead nowhere — a press that lights up and
    /// does nothing reads as broken.
    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        target(at: indexPath) != nil
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        target(at: indexPath) != nil
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = target(at: indexPath) else { return }
        // A friend's primary DM often isn't a materialized buffer — a DM that's closed
        // server-side has no row in `state.buffers`, and the chat screen's hydrate only fires
        // for a buffer that already has one. Send open-buffer explicitly here (as /query does)
        // so the server ships that DM's backlog and it opens, instead of hanging on the loading
        // spinner.
        //
        // Gated on the row being ABSENT, which is the only case that comment describes. It
        // used to fire on every friend tap, on the reasoning that a redundant one just
        // re-hydrates — no longer true, and it was the premise the read/write split overturned.
        // `open-buffer` is a WRITE: it now announces to every other device the user owns, it's
        // refused outright for a paused account, and the chat screen's own hydrate would fetch
        // the same backlog a second time. Gated on the explicit Friends-row flag, not a
        // presence proxy: presence is styling every DM row carries, not a fact about where
        // the buffer came from.
        if row.isFriend, state.buffers[row.buffer.key.id] == nil {
            viewModel.openBuffer(row.buffer.key)
        }
        onSelect?(row.buffer)
    }

    /// Trailing swipe on a network's row leaves/closes the buffer. Friends and Favorites get
    /// nothing: closing a favorite also unfavorites it, and a full swipe fires the action
    /// outright — too easy a way to drop a friend. Their long-press menu has Close.
    private func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard sectionID(at: indexPath)?.reorderable == false, let buffer = row(at: indexPath)?.buffer
        else { return nil }
        // The server log and the system buffer can't be closed.
        guard buffer.kind != .server, buffer.kind != .system else { return nil }
        // A parted channel has nothing to leave, so it's Close — as on the long-press menu.
        let title = buffer.kind == .channel && !state.isParted(buffer.key) ? "Leave" : "Close"
        let close = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, done in
            self?.close(buffer)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [close])
    }

    /// Leave a channel / close a DM. Shared by the swipe and the context menu rather than
    /// written twice: the `forgetLastBuffer` half is easy to leave out of a second copy and
    /// impossible to notice missing until a relaunch strands someone on a spinner.
    private func close(_ buffer: Buffer) {
        viewModel.closeBuffer(buffer.key)
        // Leaving here is the one moment the client *knows* a buffer is gone. Restoring into
        // one that isn't there lands on a spinner that never resolves (see
        // `SceneDelegate.launchBuffer`), and that path can't detect it — so tell it.
        UserPreferences.standard.forgetLastBuffer(ifMatching: buffer.key)
    }

    /// Long-press to pin. The Favorites section is only as real as the way to fill it, and
    /// a section with no path into it would just be a permanently empty box. Available on the
    /// network rows and on Friends and Favorites alike, so a favorite is also how you *un*favorite.
    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let buffer = row(at: indexPath)?.buffer, buffer.kind != .system,
              buffer.kind != .server, let networkId = buffer.networkId
        else { return nil }

        // One favorites flag, two vocabularies (matching the web client): a DM is a
        // "Friend", a channel a "Favorite". The server owns the list — no local mutation;
        // the favorites-changed echo rebuilds this screen (favoriting also drops any pin
        // the web client held on the buffer: one placement per buffer).
        let isDm = buffer.kind == .dm
        // A `=nick` DCC chat is neither: the server refuses to favorite one (a Friend is a person
        // whose presence is tracked, and a DCC peer has none — the socket is the whole story), so the
        // item would be a tap that does nothing (lurker#270).
        let favoritable = buffer.kind != .dcc
        let target = buffer.target
        let isFavorite = state.isFavorite(buffer.key)
        let title = isFavorite
            ? (isDm ? "Remove from Friends" : "Remove from Favorites")
            : (isDm ? "Add to Friends" : "Add to Favorites")
        let image = isFavorite
            ? UIImage(systemName: isDm ? "person.badge.minus" : "star.slash")
            : UIImage(systemName: isDm ? "person.badge.plus" : "star")
        // ⚠⚠ Close belongs on THIS menu, not only on the roster row's swipe. A favorited
        // buffer has no network row any more — its Favorites row is where it lives — so without this
        // there is no way to leave a favorited channel short of unfavoriting it first, and
        // the buffers people favorite are exactly the ones they keep. (Favorited DMs had
        // this hole already, having been lifted out since Friends landed.) The web reaches
        // the same conclusion by giving every row, favorites included, one menu ending in
        // Close.
        //
        // Its own inline section, so the separator sets a destructive action apart from the
        // favorite toggle above rather than leaving them a thumb-slip apart.
        //
        // A parted channel has nothing to leave, so for one it's Close.
        let parted = state.isParted(buffer.key)
        let leaveTitle = buffer.kind == .channel && !parted ? "Leave" : "Close"
        // Read as the menu opens, like the rest of it: a drop while the menu sits open leaves
        // Join enabled, and that JOIN goes nowhere — as a typed `/join` would.
        let canJoin = state.networks[networkId]?.state == .connected
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var children: [UIMenuElement] = []
            // A parted channel keeps its row and its history, and getting back in is the usual
            // reason to long-press one, so Join leads. Disabled while the network is down: a
            // JOIN needs a live connection, and the section header already says why. No
            // navigation — the row lighting up is the answer — and a refusal says why in a toast
            // (#57).
            if parted {
                children.append(UIMenu(options: .displayInline, children: [
                    UIAction(
                        title: "Join Channel",
                        image: UIImage(systemName: "number"),
                        attributes: canJoin ? [] : .disabled
                    ) { _ in self?.viewModel.requestJoin(networkId: networkId, channel: target, opens: false) },
                ]))
            }
            if favoritable {
                children.append(
                    UIAction(title: title, image: image, attributes: isFavorite && isDm ? .destructive : []) { _ in
                        guard let self else { return }
                        if isFavorite {
                            self.viewModel.unfavoriteBuffer(networkId: networkId, target: target)
                        } else {
                            self.viewModel.favoriteBuffer(networkId: networkId, target: target)
                        }
                    }
                )
            }
            children.append(UIMenu(options: .displayInline, children: [
                UIAction(
                    title: leaveTitle,
                    image: UIImage(systemName: "xmark"),
                    attributes: .destructive
                ) { _ in self?.close(buffer) },
            ]))
            return UIMenu(children: children)
        }
    }
}

// MARK: - Title

extension BufferListViewController {

    /// Fixed except for the subtitle: this screen is the app, not a buffer, so it always reads
    /// "Lurker" and follows the socket rather than any one network.
    var statusTitle: StatusTitle {
        StatusTitle(
            title: Buffer.system.displayName(),
            status: StatusLight.of(reachable: state.reachable, connection: state.connection, network: nil),
            detail: nil
        )
    }
}

// MARK: - Reordering favorites (#53)

/// Dragging a Favorites or Friends row into a new position.
///
/// The order is the SERVER's one global favorites list (lurker#721), shared with the web
/// client — a drop maps through `FavoriteOrder` onto the stored global order and sends the
/// full permuted bufferId list; the `favorites-changed` echo is what makes it stick on every
/// device.
///
/// Confined to the row's OWN group in both directions — the two are kind-filtered views of
/// one list (a channel isn't a person), and a row dropped anywhere foreign would snap back on
/// the next rebuild, which is a worse answer than not accepting the drop.
///
/// Each group opens with its header item, so a row's index among the group's `rows` is its
/// item index less `Section.firstRowItem`.
extension BufferListViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {

    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard reorderable(indexPath) else { return [] }
        // An empty provider: this drag offers nothing to anywhere else, and `dropSessionDidUpdate`
        // refuses any session that didn't start here. Reordering a local list is the whole
        // feature — a favorite dragged into Mail should do nothing rather than paste a key.
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = row(at: indexPath)?.buffer.key.id
        dragSourceSection = indexPath.section
        favoritesAtDragStart = state.favorites
        return [item]
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dragSessionIsRestrictedToDraggingApplication session: UIDragSession
    ) -> Bool { true }

    /// The same preview for the lift and for the landing. UIKit asks separately: this method is
    /// scoped to "the item being lifted from, or cancelling back to, the collection view", and
    /// the *drop* animation reads `dropPreviewParametersForItemAt` below — implementing only this
    /// one lifts a row on the list's ground and lands it on the system default.
    func collectionView(
        _ collectionView: UICollectionView,
        dragPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        (collectionView.cellForItem(at: indexPath) as? BufferRowCell)?.dragPreviewParameters
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        (collectionView.cellForItem(at: indexPath) as? BufferRowCell)?.dragPreviewParameters
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        // `hasActiveDrag`, not `session.localDragSession != nil`. The latter says only that the
        // drag began somewhere in this *app* — and this screen carries a search field, which is
        // a real in-app drag source for selected text. Dragging that over the list passed the
        // old check, so the layout opened an insertion gap for a drop that `performDropWith`
        // then silently refused (a foreign item has no `sourceIndexPath`).
        guard collectionView.hasActiveDrag else {
            return UICollectionViewDropProposal(operation: .cancel)
        }
        guard let destinationIndexPath,
              sections.indices.contains(destinationIndexPath.section)
        else {
            // No cell under the finger — the gutter, or below the last section. Cancel rather
            // than forbid: there's nothing here to refuse, and a badge over empty space reads
            // as an error where the honest answer is "nothing to drop onto".
            return UICollectionViewDropProposal(operation: .cancel)
        }
        guard sectionID(at: destinationIndexPath)?.reorderable == true else {
            // Over a network's group. `.forbidden` is the one that draws the
            // no-drop badge; `.cancel` is silent, which left the row looking droppable
            // everywhere right up until it flew home. The rule is only discoverable if the
            // gesture says so while it's being made.
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        // TWO sections reorder now (Favorites and Friends), but a row belongs to exactly
        // one — a channel isn't a person. A cross-section hover must say `.forbidden` HERE,
        // while the gesture is being made: `performDropWith` would refuse it anyway (the
        // key resolves against the destination's rows and misses), but only after the
        // layout opened an insertion gap and the UI said yes. Section identity, stashed
        // when the row lifted, not key membership: this runs per touch-move, and
        // sections are frozen for the drag's duration (rebuild defers), so the index
        // stays true — O(1) beats a per-event row scan and can't be fooled by a key that
        // ever appeared in two sections.
        if destinationIndexPath.section != dragSourceSection {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        // Above the header would put a row outside its group.
        if destinationIndexPath.item < Section.firstRowItem {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        // Deliberately not checking the drop index's far end: a drop past the last row is a
        // real gesture ("put it at the end") and UIKit can report it as an index one beyond
        // the last row. `performDropWith` clamps it.
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        // ⚠ Refused outright if the favorites changed while the row was in the air — another
        // device's edit, say. `rebuild` defers during a drag, so the rows the finger was moving
        // among are the drag-start order while `state` already holds the new one, and mapping
        // that stale arrangement onto the new order would send a reorder that overwrote the
        // other edit. Not calling `coordinator.drop` flies the row home, and `dragSessionDidEnd`
        // rebuilds from the current order.
        guard state.favorites == favoritesAtDragStart else { return }
        guard let item = coordinator.items.first,
              let proposed = coordinator.destinationIndexPath,
              let sectionID = sectionID(at: proposed), sectionID.reorderable,
              let sectionIndex = sections.firstIndex(where: { $0.id == sectionID })
        else { return }
        let rows = sections[sectionIndex].rows
        let visible = rows.map(\.buffer.key.id)

        // Resolved by KEY, not by `item.sourceIndexPath`. That index was captured when the row
        // was lifted, and `sections` can be rebuilt under a live drag — `rebuild()` now defers
        // while one is up, but the index would still be a fact about a model that may since
        // have been replaced, and this write goes to the only copy of the pin list there is.
        // The key is what the drag has actually been carrying all along.
        guard let key = item.dragItem.localObject as? String,
              let from = visible.firstIndex(of: key)
        else { return }
        // A drop past the last row reads as "put it at the end", so it's clamped to the last
        // row rather than refused — the row count doesn't change during a reorder, so the last
        // valid index is always `count - 1`. Both are ROW indices; the header is item 0.
        let to = min(max(proposed.item - Section.firstRowItem, 0), rows.count - 1)

        // The group shows a kind-filtered SUBSET of the server's one global favorites list
        // (this group's kinds only, and a favorite whose network is still connecting has
        // a slot and no row) — so the move is mapped onto the stored order rather than
        // applied by index. `FavoriteOrder` owns that, and answers the stored list
        // unchanged for anything it can't interpret. The FULL permuted list goes to the
        // server (a subset would float to the front and demote everything unmentioned —
        // the other section included); the favorites-changed echo is the authoritative
        // rebuild, and the in-place move below keeps the drop animation honest meanwhile.
        //
        // ⚠ The base is the order ON SCREEN — the store's with any unechoed drop applied — not
        // the store's alone. A second drag made before the first one's echo, putting the rows
        // back where the store still has them, diffed against the store as "no change": it
        // sent nothing, snapped back, and the first drop's echo then saved the order the user
        // had just undone.
        let stored = orderedFavorites(state).map(\.key.id)
        let reordered = FavoriteOrder.moved(stored, visible: visible, from: from, to: to)
        guard reordered != stored else { return }
        let idByKey = Dictionary(state.favorites.map { ($0.key.id, $0.bufferId) }, uniquingKeysWith: { a, _ in a })
        let reorderedIds = reordered.compactMap { idByKey[$0] }
        viewModel.reorderFavorites(bufferIds: reorderedIds)
        // Shadow the new order until the echo folds — the deferred rebuild released at
        // drag end would otherwise restore the store's pre-drop order (a visible snap
        // home, and a corrupt base for a quick second drag). See orderedFavorites(_:).
        favoritesAtDrop = state.favorites
        optimisticFavoriteOrder = reorderedIds

        // The model moves with the view rather than being rebuilt: the echo would reach the
        // same answer, but a full rebuild mid-drop drops the drag animation on the floor. A
        // move inside one group can't change any other, so the two are equivalent here.
        //
        // Re-made through `Section.init` rather than moved in place, so the guides follow:
        // the row that lands last becomes the `└─`, and the one that was last goes back to `├─`.
        var moved = rows
        moved.insert(moved.remove(at: from), at: to)
        let section = sections[sectionIndex]
        sections[sectionIndex] = Section(id: section.id, header: section.header, rows: moved)
        indexEntries(sections.map(\.entries))
        // Through the data source, not `collectionView.moveItem`: it owns the item order now,
        // and a view moved behind its back is a view the next snapshot would move back.
        var snapshot = dataSource.snapshot()
        let items = sections[sectionIndex].items
        snapshot.deleteItems(items)
        snapshot.appendItems(items, toSection: sectionID)
        snapshot.reconfigureItems(Array(items.dropFirst(Section.firstRowItem)))
        dataSource.apply(snapshot, animatingDifferences: false)
        coordinator.drop(
            item.dragItem, toItemAt: IndexPath(item: to + Section.firstRowItem, section: proposed.section)
        )
    }

    /// Runs on a completed drop *and* on a cancelled one, which is what makes it the right
    /// place to release a rebuild `rebuild()` deferred — a drag abandoned over the roster would
    /// otherwise leave the list frozen on whatever it held when the row was lifted.
    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        // Cleared FIRST: the deferred rebuild below is exactly the path that rebuilds
        // `sections`, after which a stashed section index would be a fact about a
        // model that no longer exists.
        dragSourceSection = nil
        favoritesAtDragStart = nil
        guard rebuildDeferredByDrag else { return }
        rebuild()
    }

    /// The buffer row at an index path, by identity — nil for a header or the pinned break.
    ///
    /// Every delegate callback goes through this rather than indexing `sections`: UIKit hands
    /// back positions, and a position is the one thing about this list that isn't stable.
    private func row(at indexPath: IndexPath) -> Row? {
        guard let id = dataSource.itemIdentifier(for: indexPath),
              case let .buffer(row)? = entriesByID[id]
        else { return nil }
        return row
    }

    /// What a tap on this index path opens: a buffer row's buffer, or a network header's
    /// server log. Nil for everything that leads nowhere.
    private func target(at indexPath: IndexPath) -> Row? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        switch entriesByID[id] {
        case let .buffer(row)?: return row
        case let .header(header)?: return header.log
        case .pinBreak?, nil: return nil
        }
    }

    /// What kind of section an index path lands in, by identity.
    private func sectionID(at indexPath: IndexPath) -> SectionID? {
        dataSource.sectionIdentifier(for: indexPath.section)
    }

    /// Whether this index path is a row in a section that can be reordered.
    private func reorderable(_ indexPath: IndexPath) -> Bool {
        sectionID(at: indexPath)?.reorderable == true && row(at: indexPath) != nil
    }
}

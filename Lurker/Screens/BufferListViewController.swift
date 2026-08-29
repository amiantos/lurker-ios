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
/// Not a directory: the buffers you actually move between are a handful you keep returning
/// to, so Friends, Favorites and Recent come first as two-across grids of cards you can hit
/// without looking, and the full grouped roster sits underneath. The grids are *shortcuts* — a
/// favorite or recent buffer also keeps its ordinary row in its network's section below, so
/// the roster stays a complete list rather than one with holes punched in it. Only the roster
/// rows carry swipe-to-leave, so the two never read as the same control.
///
/// A `UICollectionView` with a compositional layout rather than a table, because one scroll
/// view has to hold both full-width rows and a two-up grid — the layout is chosen per section
/// (`.list` vs. a grid group), which a table can't do and a hand-rolled scroll view would
/// have to reinvent.
///
/// "Denser" is spacing, not type size — one font size app-wide. The hierarchy is the card,
/// a network line on the grid chips, weight, and order.
///

/// Grid of chips, or inset-grouped list.
nonisolated private enum Layout {
    case list
    case grid
}

/// What a section *is*, independent of where it currently sits.
///
/// ⚠⚠ The fix for a class of bug that cost a long QA session. This screen's sections are
/// not interchangeable — Friends/Favorites/Recent are two-up grids of chips, the network
/// rosters are inset-grouped lists — and they arrive in a different order than they
/// finally sit in: during the connect burst the list is `Recent | libera | …` and
/// moments later `Friends | Favorites | Recent | libera | …`, so index 1 stops being a
/// list and becomes a grid.
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
    case recent
    /// A network's roster. `pinned` splits it into the two sections a network can have.
    case network(Int, pinned: Bool)
    /// Buffers whose network isn't in the roster yet (snapshot race).
    case unrostered(Int, pinned: Bool)

    var layout: Layout {
        switch self {
        case .friends, .favorites, .recent: .grid
        case .network, .unrostered: .list
        }
    }

    /// Whether these chips can be dragged into a new order (#53). Friends and Favorites,
    /// the two views of the server's one global favorites order (lurker#721) — not
    /// Recent, which is MRU-ordered, and not the rosters, which are the same sorted list
    /// this screen has always shown; a drag in either would be undone by the next
    /// rebuild.
    var reorderable: Bool { self == .friends || self == .favorites }
}

/// One row's identity. Section-qualified because the same buffer legitimately appears
/// twice — Recent keeps its rows in their network sections — and a diffable data source
/// requires item identifiers to be unique across the whole snapshot.
nonisolated private struct ItemID: Hashable {
    let section: SectionID
    let key: String
}

/// It reports the pick through `onSelect` and doesn't know what happens next.
final class BufferListViewController: UICollectionViewController {
    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    /// Called with the picked buffer. The presenter owns opening it.
    var onSelect: ((Buffer) -> Void)?

    /// How many recents to promote. A quick switcher that lists thirty "recent" buffers is
    /// just the roster again — this is a display cap, not a limit on what's remembered. Four,
    /// not three, so the two-across grid fills whole rows rather than leaving a ragged half.
    private static let recentLimit = 4


    private struct Row: Equatable {
        let buffer: Buffer
        /// The full network name. Grid chips carry it for their accessibility label; roster
        /// rows leave it nil, already sitting under their network's header.
        let networkName: String?
        /// The short `li` disambiguator drawn after the name, set by `addNetworkHints` only
        /// on chips whose name collides with another chip's. Separate from `networkName`
        /// because the two answer different questions: this one is "would you otherwise
        /// confuse this chip with the one beside it", and it's nil far more often.
        var networkHint: String?
        /// Set only on Friends chips (favorited DMs): the peer's presence dot state.
        /// Equatable so a presence change reconfigures the one chip.
        var presence: FriendPresence?
        /// A Friends chip — the one row kind whose buffer may be SYNTHESIZED (a
        /// favorite the store hasn't materialized), so a tap must open-buffer first.
        /// An explicit flag, not "has presence": the moment any other chip kind grows
        /// a presence dot, a proxy would quietly start firing a WRITE on its taps.
        var isFriendChip: Bool = false
        /// Whether an ignore rule mutes this buffer's plain-unread signal (lurker #359).
        /// Carried on the row — and therefore compared by `Equatable` — so muting or unmuting
        /// from another device reconfigures the one cell it affects.
        var muted: Bool = false

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
            isFriendChip: Bool = false,
            muted: Bool = false
        ) {
            self.buffer = buffer
            self.networkName = networkName
            self.presence = presence
            self.isFriendChip = isFriendChip
            self.muted = muted
        }
    }

    private struct Section {
        let id: SectionID
        let title: String?
        var rows: [Row]

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
        init(id: SectionID, title: String?, rows: [Row]) {
            self.id = id
            self.title = title
            var seen = Set<String>()
            self.rows = rows.filter { seen.insert($0.buffer.key.id).inserted }
        }

        var layout: Layout { id.layout }
        var reorderable: Bool { id.reorderable }
        /// One per row, and `rows` is unique by construction — see `init`.
        var items: [ItemID] { rows.map { ItemID(section: id, key: $0.buffer.key.id) } }
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
    /// Whether a state change arrived while a chip was being dragged and is still owed a
    /// rebuild (#53). See `rebuild()` for why it waits and `dragSessionDidEnd` for the release.
    private var rebuildDeferredByDrag = false
    /// The section a live drag was lifted from — chips reorder only within their own
    /// section, and this is the O(1) identity `dropSessionDidUpdate` checks per
    /// touch-move (sections are frozen during a drag; rebuild defers).
    private var dragSourceSection: Int?
    /// The just-dropped favorites order (bufferIds) awaiting its server echo, plus the
    /// store snapshot it permutes — see `orderedFavorites(_:)`.
    private var optimisticFavoriteOrder: [Int]?
    private var favoritesAtDrop: [FavoriteEntry]?

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        // The real layout needs `self` to read `sections`, which isn't available until after
        // `super.init`; it's swapped in from `viewDidLoad`.
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // `largeTitle`, NOT `title` — the two are separate on iOS 26, and `title` would also
        // render in the *small-title row*, which is exactly where the shared pill sits. The
        // pill used to be this screen's `titleView`, and a `titleView` suppresses the inline
        // title; now that it belongs to the bar instead, nothing does, and "Buffers" draws
        // underneath it as soon as the large title collapses on scroll.
        navigationItem.largeTitle = "Buffers"
        // The empty state's only button, and it has only one meaning here: this screen's
        // placeholder never asks anything else of the user.
        placeholderView.onAction = { [weak self] in self?.showAddNetwork() }
        // `title` is what the back button would have borrowed, so name it explicitly — it
        // still feeds the back button's long-press menu and VoiceOver.
        navigationItem.backButtonTitle = "Buffers"
        // …but only there. Setting `backButtonTitle` alone *promotes* the back button from
        // iOS 26's bare chevron to a 95pt "‹ Buffers" pill, which is not what this screen
        // looked like before and crowds the bar. `.minimal` keeps the title for the
        // long-press menu while drawing the indicator alone — measured identical to the
        // original: a 44pt button with no label.
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.largeTitleDisplayMode = .always
        collectionView.backgroundColor = .systemGroupedBackground
        // ⚠ Created BEFORE the layout, and explicitly rather than as a side effect of the
        // first thing that happens to touch it. `UICollectionViewController` installs itself
        // as the collection view's data source in `loadView`; constructing the diffable one
        // is what replaces it, and the layout's section provider asks the data source what a
        // section is — so a lazy first touch from inside that provider would be answering a
        // question about a data source that doesn't exist yet.
        _ = dataSource
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)

        // Drag-and-drop rather than `moveItemAt` + the standard interactive-movement gesture
        // (#53). That gesture is a long press, which is already the chip's context menu — the
        // two would race, and the one that lost would be the discoverable one. A drag session
        // is how UIKit reconciles them: a lift that *moves* reorders, a lift that stays put
        // opens the menu, which is what every reorderable grid on the system does.
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
        //    `addSubview` would let a chip draw over it. `zPosition` wins regardless of order,
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
        _ = listRegistration
        _ = chipRegistration
        _ = headerRegistration

        // Both in the navigation bar, and deliberately not in a bottom toolbar. A toolbar
        // would be a second floating bar over a scrolling list, and it can't persist across
        // the push into a chat screen — whose bottom is a composer — so it has to leave and
        // come back on every navigation, which is a lot of movement to buy two buttons.
        //
        // Set once here and never replaced: `apply` runs on every unread-count change, and
        // swapping a bar button item out closes any menu it happens to be showing.
        navigationItem.leftBarButtonItem = accountItem()
        // First element is the *trailing-most*, so this reads "+ then …" left to right —
        // the views menu sits in the same corner it occupies on the chat screen, so the one
        // button that means the same thing on both screens is in the same place on both.
        navigationItem.rightBarButtonItems = [viewsItem(), joinItem]
        installSearch()

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
                    // `backlog-complete` carries no state but this flag. On an account with
                    // nothing to list it moves nothing else at all, so leaving it out would
                    // drop the frame as a duplicate and spin "Loading buffers…" forever on
                    // exactly the account the empty state was written for.
                    && $0.backlogComplete == $1.backlogComplete
                    // The Friends/Favorites sections render off these two: the favorites
                    // list and the per-nick presence the dots read. A friend coming online
                    // is a presence change with no buffer change, so without these the
                    // chip's dot never moves.
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

    /// Coming back from a buffer rebuilds, always — not just when state moved under us.
    ///
    /// Recent order lives in `UserPreferences`, written by the chat screen on appear, and
    /// nothing publishes it. As a sheet this screen was built fresh on every summon so it
    /// always re-read it; as a reused root it would show the order from before you opened the
    /// buffer you just backed out of — which on a quiet connection is exactly the buffer
    /// missing from the top of a list whose whole job is putting it there.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        rebuild()
        // The toolbar carrying the search field belongs to the *navigation controller*, and the
        // screen pushed over this one ends in a composer — so it can't simply stay up. Asked
        // for on the way in and given back on the way out, which also means it animates with
        // the transition rather than appearing after it.
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshBanner()
        navigationController?.setToolbarHidden(true, animated: animated)
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
        let isFrontmost = view.window != nil && navigationController?.topViewController === self
        connectionBanner.update(isFrontmost ? bannerState : .hidden)
    }

    /// The new state is always kept — it's what the deferred menus and the next rebuild read —
    /// but the rebuild itself waits until anyone can see the result.
    private func apply(_ state: ChatState) {
        self.state = state
        // The pill is in the bar, not the list, so it tracks connection regardless of whether
        // the roster below is worth rebuilding — and `refresh` no-ops both when this screen
        // isn't the one on top and when nothing the pill shows has moved.
        navigationPill?.refresh(from: self)
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
    /// the odds of one during the seconds a chip is held are not small — and a `reloadData`
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
            rowsByID = [:]
            shownTitles = [:]
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

        let previous = rowsByID
        sections = buildSections(state)
        rowsByID = Dictionary(
            sections.flatMap { section in
                section.rows.map { (ItemID(section: section.id, key: $0.buffer.key.id), $0) }
            },
            // A section can't hold one buffer twice, and `ItemID` is section-qualified, so a
            // collision here is impossible rather than merely unlikely — keep the first and
            // move on rather than trapping on it in front of a user.
            uniquingKeysWith: { first, _ in first }
        )
        updatePlaceholder()

        var snapshot = NSDiffableDataSourceSnapshot<SectionID, ItemID>()
        snapshot.appendSections(sections.map(\.id))
        for section in sections { snapshot.appendItems(section.items, toSection: section.id) }
        // Identity alone can't see a row whose *contents* moved — an unread count, a friend's
        // presence dot — because those don't change the item's identifier. Naming them keeps
        // the cheap path cheap: everything else in the snapshot is left exactly as it is.
        let restyled = snapshot.itemIdentifiers.filter { id in
            guard let was = previous[id], let now = rowsByID[id] else { return false }
            return was != now
        }
        if !restyled.isEmpty { snapshot.reconfigureItems(restyled) }
        // ⚠⚠ And the same problem one level up, for HEADERS.
        //
        // A section's title is deliberately not part of its identity: a network's header
        // carries its connection state ("libera — offline"), so folding the title into
        // `SectionID` would delete and re-insert the whole section every time it reconnected.
        // The cost is that a snapshot diff can't see a title change either — the section is
        // "the same", so its header view is never re-requested and keeps whatever it last
        // drew.
        //
        // That is how a network shows as "Unnamed network" after its real name has arrived:
        // the roster landed, the model updated, the rows are right, and nothing asked the
        // header to say so. It looks fixed the moment you scroll the header off screen and
        // back, because that recycles the view. Same for a network that connects while you're
        // looking at it and keeps its "— offline" suffix.
        //
        // `reloadSections` re-requests the header. It reloads that section's cells too, which
        // is more than strictly needed — but only for the sections whose title actually moved,
        // which is a handful of rows on a rare event, and there is no "reconfigure
        // supplementary" to reach for.
        let renamed = sections.filter { section in
            // A section absent from `shownTitles` is being inserted, and draws fresh anyway.
            guard let shown = shownTitles[section.id] else { return false }
            return shown != section.title
        }
        shownTitles = Dictionary(
            sections.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }
        )
        if !renamed.isEmpty { snapshot.reloadSections(renamed.map(\.id)) }
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

    /// One scroll view, section by section: the per-network rosters lay out as grouped lists
    /// (with swipe-to-leave, under a native list header), and Friends/Favorites/Recent lay out
    /// as a two-column grid of cards (under a boundary header). Every section carries a title.
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            // ⚠⚠ By IDENTITY, not by index. This closure is called lazily and its result is
            // cached per index, so reading a positional array here is what let a section keep
            // another section's geometry when the two swapped places mid-burst.
            guard let self, let id = self.dataSource.sectionIdentifier(for: index) else {
                return nil
            }
            let hasTitle = self.sections.first { $0.id == id }?.title != nil
            let layoutSection: NSCollectionLayoutSection

            switch id.layout {
            case .list:
                var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                // The list's *own* header, not a manual boundary item: the native grouped
                // header sits tight to the first row, whereas a hand-added header stacks on
                // top of the list's top inset and leaves an oversized gap.
                config.headerMode = hasTitle ? .supplementary : .none
                config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                    self?.trailingSwipe(at: indexPath)
                }
                layoutSection = .list(using: config, layoutEnvironment: environment)

            case .grid:
                // Two-up grid. Unlike the deprecated `subitem:count:` (which forced equal-sized
                // items), `repeatingSubitem:count:` makes it *your* job to size the item to fit
                // `count` repetitions — so the item is `.fractionalWidth(0.5)`, half the group.
                // Left at `.fractionalWidth(1)` each item takes the full row and the second chip
                // is pushed off, collapsing the grid to one column. (See SO 77092978.)
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(0.5),
                    heightDimension: .fractionalHeight(1)
                ))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        // Estimated, not absolute: the chip's `card` floors at 44 but grows
                        // with its text, so at accessibility sizes the row expands to fit
                        // rather than clipping the name and its network hint.
                        heightDimension: .estimated(44)
                    ),
                    repeatingSubitem: item,
                    count: 2
                )
                group.interItemSpacing = .fixed(10)
                let grid = NSCollectionLayoutSection(group: group)
                grid.interGroupSpacing = 10
                // 16 matches the horizontal inset the insetGrouped list draws its cards at (and
                // the nav-bar buttons), so a chip's edge lines up with a row's edge; the extra
                // bottom inset spaces the grid off the section under it.
                grid.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 16, bottom: 18, trailing: 16)
                // A grid has no list header of its own, so it carries a boundary one — the
                // small gap this leaves reads fine above cards.
                if hasTitle {
                    let header = NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: NSCollectionLayoutSize(
                            widthDimension: .fractionalWidth(1),
                            heightDimension: .estimated(30)
                        ),
                        elementKind: UICollectionView.elementKindSectionHeader,
                        alignment: .top
                    )
                    grid.boundarySupplementaryItems = [header]
                }
                layoutSection = grid
            }
            return layoutSection
        }
    }

    // MARK: - Cell & header registrations

    private lazy var listRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> {
        cell, _, row in
        var content = UIListContentConfiguration.cell()
        // No `networkName` here, unlike the pill: every roster row already states its network
        // as its section header, so resolving a server log to its network's name would just
        // print "libera" above "libera".
        content.text = row.buffer.displayName()
        cell.contentConfiguration = content

        // The unread pill *replaces* the disclosure chevron, as the table did — a row either
        // says how much is waiting or it says "there's more inside", never both.
        if let badge = makeUnreadBadge(unread: row.displayUnread, highlights: row.buffer.highlights) {
            cell.accessories = [.customView(configuration: .init(customView: badge, placement: .trailing()))]
        } else {
            cell.accessories = [.disclosureIndicator()]
        }
    }

    private lazy var chipRegistration = UICollectionView.CellRegistration<BufferChipCell, Row> {
        cell, _, row in
        cell.configure(
            // `networkName` here, unlike the roster rows: a `.server` buffer has no target to
            // print, so `displayName` falls back to the literal "Server" without one. A roster
            // row can afford that (its section header names the network); a chip is lifted out
            // of its section, and it lost its network subtitle — so an unnamed one would read
            // as just "Server" with nothing anywhere on the card saying which.
            name: row.buffer.displayName(networkName: row.networkName),
            networkName: row.networkName,
            networkHint: row.networkHint,
            unread: row.displayUnread,
            highlights: row.buffer.highlights,
            presence: row.presence
        )
    }

    private lazy var headerRegistration = UICollectionView
        .SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            // ⚠⚠ Always assigned, even when there's nothing to say. Supplementary views are
            // RECYCLED, so an early `return` here left the previous section's title on a
            // header now sitting over a different section — which is what "the buffer list is
            // showing two `local` headers" turned out to be.
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section)
                .flatMap { id in self?.sections.first { $0.id == id }?.title }
            view.contentConfiguration = content
        }

    /// The list, handed over whole.
    ///
    /// ⚠⚠ Diffable rather than the manual data source this had, and the reason is identity.
    /// The old one answered `numberOfSections`/`cellForItemAt` out of an array, so a section
    /// *was* its index — and the indices shift as sections arrive during the connect burst.
    /// Everything keyed off position went with them: the layout's grid-or-list decision, the
    /// header's title, the collection view's cached self-sizing metrics. Rows stayed correct
    /// and the picture didn't.
    ///
    /// `SectionID`/`ItemID` make identity explicit, so a section that moves takes its layout
    /// and its geometry with it and UIKit computes the moves itself from one snapshot.
    private lazy var dataSource: UICollectionViewDiffableDataSource<SectionID, ItemID> = {
        let source = UICollectionViewDiffableDataSource<SectionID, ItemID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self, let row = rowsByID[item] else { return UICollectionViewCell() }
            switch item.section.layout {
            case .list:
                return collectionView.dequeueConfiguredReusableCell(
                    using: listRegistration, for: indexPath, item: row
                )
            case .grid:
                return collectionView.dequeueConfiguredReusableCell(
                    using: chipRegistration, for: indexPath, item: row
                )
            }
        }
        source.supplementaryViewProvider = { [weak self] _, _, indexPath in
            guard let self else { return nil }
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration, for: indexPath
            )
        }
        return source
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

    /// The title each section was last drawn with, so a rename can be spotted — see the note
    /// in `rebuild`. Not derivable from the snapshot, which holds identifiers and not titles.
    private var shownTitles: [SectionID: String?] = [:]

    /// Every row on screen, by identity — what the cell provider configures from, since a
    /// snapshot carries identifiers and not content.
    private var rowsByID: [ItemID: Row] = [:]

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
    private func accountItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in self?.showSettings() }
        )
        item.accessibilityLabel = "Settings"
        return item
    }

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

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: searchResults)
        controller.searchResultsUpdater = searchResults
        // The delegate is *this* screen, not the results: presenting search changes what this
        // screen looks like (the pill goes), and the search controller belongs to it. What the
        // results need from those callbacks, they're asked for directly — see the extension.
        controller.delegate = self
        // Show the results the moment search is activated, not once there's text in the field.
        //
        // UIKit's default is `automaticallyShowsSearchResultsController`, which presents the
        // results controller "based on the contents of its text property" — so an empty field
        // presents nothing at all, and tapping search just raised the keyboard and slid this
        // list up behind it. That default is right for a results controller that would be blank
        // until you type; ours opens on your recent highlights, so there is something to show
        // from the first tap. Setting this flips `automaticallyShowsSearchResultsController` to
        // false.
        controller.showsSearchResultsController = true
        controller.searchBar.placeholder = "Search messages"
        // The filter grammar is typed, not tapped: autocapitalization turns `from:` into
        // `From:` and autocorrect rewrites nicks and channel names into English words.
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        controller.searchBar.spellCheckingType = .no
        return controller
    }()

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
    private func installSearch() {
        navigationItem.searchController = searchController
        navigationItem.preferredSearchBarPlacement = .integrated
        toolbarItems = [navigationItem.searchBarPlacementBarButtonItem]
    }

    /// Take the search UI down — what a result tap calls once it's decided where to go. Not a
    /// dismiss: the results are presented *by* the search controller, so the thing to undo is
    /// its activation, which also empties the field for the next time search is opened.
    func dismissSearch() {
        searchController.isActive = false
    }

    /// The same views menu the chat screen carries, minus the entries that need a buffer.
    ///
    /// Highlights and Bookmarks are app-scoped — they span every network — so being able to
    /// reach them only from inside some arbitrary conversation was an artifact of the chat
    /// screen having once been the only screen. Search and uploads land here as they're built,
    /// which is the set the desktop client keeps in its bottom toolbar (#49).
    ///
    /// Members is deliberately absent: it describes a channel, and there isn't one here.
    private func viewsItem() -> UIBarButtonItem {
        let highlights = UIAction(title: "Highlights", image: UIImage(systemName: "at")) { [weak self] _ in
            guard let self else { return }
            showHighlights(viewModel: viewModel)
        }
        let bookmarks = UIAction(title: "Bookmarks", image: UIImage(systemName: "bookmark")) { [weak self] _ in
            guard let self else { return }
            showBookmarks(viewModel: viewModel)
        }
        let item = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [highlights, bookmarks])
        )
        item.accessibilityLabel = "More"
        return item
    }

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

    /// Joining is also switching: you asked for a channel, so land in it. The buffer won't
    /// exist yet — its row arrives with the server's `channel-joined` — so hand over a
    /// synthesized one exactly as a notification tap does, and let the chat screen's
    /// `hydrateIfNeeded` fill it in when the join completes.
    private func join(network: Network, channel typed: String) {
        // A bare sigil is not a name: `ensurePrefix("#")` would send a JOIN for "#".
        guard ChannelName.namesAChannel(typed) else { return }
        // ⚠ The TRIMMED name. `namesAChannel` trims before testing — that's the point of it
        // owning the rule — so passing the raw string on means " #swift" clears the guard and
        // then gets a sigil prepended to a leading space: `JOIN "# #swift"`. Latent only
        // because the join sheet happens to trim first.
        let channel = ChannelName.ensurePrefix(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        viewModel.joinChannel(networkId: network.id, channel: channel)
        // `buffer(for:)` rather than a hand-built one: the kind must come from the one
        // classifier (`BufferKind.of`, the full sigil set) — hardcoding `.channel` here
        // would hand the chat screen a row the store's own synthesis could disagree with.
        onSelect?(state.buffer(for: BufferKey(networkId: network.id, target: channel)))
    }

    // MARK: - Sections

    private func buildSections(_ state: ChatState) -> [Section] {
        // Partition the favorites list ONCE — the sections, the roster exclusion, and the
        // Recent dedupe all derive from the same two slices, so a future classification
        // change can't update one walk and miss another (the double-printed-DM bug the
        // split exists to prevent).
        let orderedFavorites = orderedFavorites(state)
        let friendEntries = orderedFavorites.filter(Self.isFriendEntry)
        let channelEntries = orderedFavorites.filter { !Self.isFriendEntry($0) }
        // ⚠⚠ A favorite is a RELOCATION, not a shortcut. Its chip is where it lives, so it's
        // hidden from its network's roster (and from Recent) rather than printed twice —
        // matching the web, where `isFavoriteBuf` filters favorites out of both the pinned
        // and unpinned halves of every network group.
        //
        // This used to be true of friends only, on the reasoning that a card and a row read
        // as different things so the duplication was a quick way in rather than a mistake.
        // In use it doesn't read that way: the buffers you favorite are the ones you look at
        // most, so the list you scan most is the one with every important row in it twice.
        let favoriteKeys = Set(orderedFavorites.map(\.key.id))

        let byNetwork = BufferOrder.byNetwork(state.buffers.values, excluding: favoriteKeys)
        // Before the favorites exclusion, because a network whose every open buffer is
        // favorited still exists and still has a log — see `withServerLog`.
        let networksInUse = Set(state.buffers.values.compactMap(\.networkId))

        var sections: [Section] = []

        // Friends and Favorites are a relocation (see `favoriteKeys` above); Recent is the
        // one shortcut left, and it keeps its rows in their network sections because it isn't
        // curated — it's just where you've been, and hiding a row from its network because
        // you happened to pass through it would make the list you scan depend on what you did
        // five minutes ago.
        var favorites = favoriteRows(channelEntries, state)
        var recents = recentRows(state, favoriteKeys: favoriteKeys)
        var friends = friendRows(friendEntries, state)
        // Each grid on its own — a collision is a fact about one section's rows. Recent hints
        // every chip rather than just its collisions: it's the one grid you didn't curate.
        // Abbreviations are per-account, so they're computed once and shared by all three;
        // they're measured against every network the user has, not the ones on screen, which
        // is also what the web computes for the same rows (see `NetworkAbbreviation`).
        let abbreviations = NetworkAbbreviation.shortestUniquePrefixes(state.networks.mapValues(\.displayName))
        Self.addNetworkHints(abbreviations, &friends)
        Self.addNetworkHints(abbreviations, &favorites)
        Self.addNetworkHints(abbreviations, &recents, everyRow: true)
        // Friends first, then Favorites — the web sidebar's order (FRIENDS above FAVORITES),
        // and the two are one list on the server, so the halves reading top-to-bottom
        // differently was a needless thing to have to re-learn per client. People also earn
        // the top slot on their own: a friend chip is the only row carrying live presence, so
        // it's the one grid whose contents change while you look at it.
        //
        // Both are reorderable since lurker#721 — the order is the server's global favorites
        // order, shared with the web client.
        if !friends.isEmpty {
            sections.append(Section(id: .friends, title: "Friends", rows: friends))
        }
        if !favorites.isEmpty {
            sections.append(Section(id: .favorites, title: "Favorites", rows: favorites))
        }
        // Recent stays last of the grids, and has no web counterpart: it's the iOS answer to
        // having no sidebar, so it sits below the two curated sections rather than pushing
        // them down with buffers you merely passed through.
        if !recents.isEmpty { sections.append(Section(id: .recent, title: "Recent", rows: recents)) }

        // The user's own order, not ours: they arranged their networks on the web, and a
        // phone that re-alphabetises them is a phone you have to re-read every time you pick
        // it up. Same for the pins inside each one.
        let networks = BufferOrder.networks(state.networks)
        var seen = Set<Int>()
        for network in networks {
            seen.insert(network.id)
            // `withServerLog`, so a network always has at least its log and therefore always
            // has a row — the web's network header is that buffer, and iOS's server row was
            // coming and going with the connect burst's prune.
            let rows = BufferOrder.withServerLog(
                byNetwork[network.id] ?? [],
                networkId: network.id,
                networkHasOpenBuffers: networksInUse.contains(network.id)
            )
            let split = BufferOrder.split(rows, pinned: state.pinned[network.id] ?? [])
            sections.append(contentsOf: networkSections(
                { .network(network.id, pinned: $0) }, header(for: network), split, state
            ))
        }
        // Buffers whose network isn't in the roster yet (snapshot race).
        for (networkId, buffers) in byNetwork where !seen.contains(networkId) {
            let split = BufferOrder.split(buffers, pinned: state.pinned[networkId] ?? [])
            // NOT the literal "network" this used to say — that was #136's placeholder
            // surviving in the one place the fix didn't reach, and it reads as a real name.
            sections.append(contentsOf: networkSections(
                { .unrostered(networkId, pinned: $0) }, Network.unnamedDisplayName, split, state
            ))
        }
        return sections
    }

    /// The buffers you've actually been in lately, newest first.
    ///
    /// The buffer you were *just* in is included, and sits at the top. As a sheet over the
    /// chat screen this list excluded it — the row you were already on would have been the
    /// first thing under your thumb, doing nothing. Backing out to a home screen inverts
    /// that: the conversation you just left is the single likeliest place you'd want to
    /// return to, and a list that hid it would be the thing that looked broken.
    ///
    /// Keys that no longer resolve (a closed buffer, a left channel) just fall out, and the
    /// system buffer is excluded because it already has its own row above.
    private func recentRows(_ state: ChatState, favoriteKeys: Set<String>) -> [Row] {
        // Favorites (both kinds — friend DMs have their own chip too) claim a buffer
        // before Recent does, so a favorite you just opened stays a single chip rather
        // than printing a second, identical one in the Recent grid right beside it.
        // (Channels still keep their ordinary roster row below — this only dedups
        // between the grids.)
        let excluded = favoriteKeys
        return UserPreferences.standard.recentBufferKeys
            .filter { !excluded.contains($0) }
            .compactMap { state.buffers[$0] }
            .filter { $0.kind != .system }
            .prefix(Self.recentLimit)
            .map { chipRow($0, state) }
    }

    /// One chip per friend — the DM slice of the server's favorites list, in the user's
    /// global order (shared with the web client's FRIENDS section since lurker#721).
    private func friendRows(_ entries: [FavoriteEntry], _ state: ChatState) -> [Row] {
        entries.map { entry in
            // `buffer(for:)` resolves an existing DM (keeping its server-cased target and
            // unread count) or synthesizes an unhydrated one to open — the same handoff the
            // join flow uses, so tapping the chip hydrates on the chat screen.
            let buffer = state.buffer(for: entry.key)
            return Row(
                buffer: buffer,
                networkName: state.networks[entry.networkId]?.displayName,
                presence: state.presence(networkId: entry.networkId, nick: entry.target),
                isFriendChip: true,
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
            return chipRow(buffer, state)
        }
    }

    /// `state.favorites` with the just-dropped-but-not-yet-echoed order applied. A drop
    /// permutes the local sections AND sends the reorder, but any frame that folded
    /// mid-drag releases a deferred rebuild the instant the drag ends — rebuilding from
    /// the store's PRE-drop order, which snapped the chip home for a round-trip and made
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

    private func chipRow(_ buffer: Buffer, _ state: ChatState) -> Row {
        Row(
            buffer: buffer,
            networkName: buffer.networkId.flatMap { state.networks[$0]?.displayName },
            muted: Self.isMuted(buffer, state)
        )
    }

    private func rosterRow(_ buffer: Buffer, _ state: ChatState) -> Row {
        Row(buffer: buffer, networkName: nil, muted: Self.isMuted(buffer, state))
    }

    /// Tag chips with a short `li` network hint — the ones whose names collide **within this
    /// one grid**, or every chip when `everyRow` is set.
    ///
    /// Per section, not pooled across all three, because Recent churns and Friends/Favorites
    /// don't. Pooling let a stable Favorites chip gain and lose its hint as unrelated buffers
    /// drifted in and out of Recent — a label changing under you with nothing you did to cause
    /// it, which is the same failure `NetworkAbbreviation` avoids by measuring uniqueness
    /// against every network rather than the visible ones. A section is also the set you
    /// actually scan as a set: two identical names under one header are the confusion worth
    /// spending a label on; the same name under two different headers already reads as two
    /// different things.
    ///
    /// `everyRow` is Recent's, and the asymmetry is the point. Friends and Favorites are
    /// **curated** — you put each one there, so you know which network it's on and the hint is
    /// only worth its space when two of them read alike. Recent is the grid you didn't choose:
    /// it's wherever you happened to be, in whatever order you were there, so which network a
    /// chip belongs to is context for *every* row rather than a tiebreaker between two.
    ///
    /// Both modes are gated on the ACCOUNT having more than one network — not on the rows in
    /// front of you spanning more than one, which is what this gate used to ask and which
    /// broke the very rule the paragraph above states. With the row-based gate, a Recent grid
    /// sitting entirely on one network showed no hints; opening a single buffer on a second
    /// network pushed the grid's network count 1 → 2 and made three untouched chips *all*
    /// sprout a label, then lose it again when that buffer aged out. Churn moving labels on
    /// chips the user never touched, in the churniest grid — exactly what per-section counting
    /// was meant to stop. The number of networks configured only changes when you add or
    /// remove one, so gating on that is stable by construction.
    ///
    /// The gate is a no-op for the collision path either way: two chips sharing a name in one
    /// section are necessarily on different networks, a buffer key being network + target.
    ///
    /// `abbreviations` is computed once by the caller and passed to all three grids: it
    /// depends only on the account's networks, so deriving it here would recompute the same
    /// answer up to three times per rebuild — and a rebuild runs on every state change.
    /// It carries exactly one entry per network (see `NetworkAbbreviation`), which is what
    /// makes its count the network-count gate above.
    private static func addNetworkHints(
        _ abbreviations: [Int: String],
        _ rows: inout [Row],
        everyRow: Bool = false
    ) {
        guard abbreviations.count > 1 else { return }

        let hinted: Set<String>
        if everyRow {
            hinted = Set(rows.map { $0.buffer.target.lowercased() })
        } else {
            var counts: [String: Int] = [:]
            for row in rows { counts[row.buffer.target.lowercased(), default: 0] += 1 }
            hinted = Set(counts.filter { $0.value > 1 }.keys)
        }
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

    /// A network's rows as one or two sections: its pinned buffers, then the rest.
    ///
    /// Two sections rather than one ordered list, because a list on iOS has no separator
    /// *inside* it — the section header is the separator. Pins ordered first within a single
    /// section would have been an arrangement with nothing to explain it, which reads as a
    /// sort bug rather than as the order you set.
    ///
    /// ⚠ **Both** headers are built from the network's own, with " — pinned" appended to the
    /// first. Putting the connection state on the unpinned header alone loses it entirely for
    /// a network whose every open buffer is pinned — which is not a corner case, it's what
    /// two pinned channels and nothing else looks like — and it would read as if the pinned
    /// half were online while the rest wasn't.
    ///
    /// Either section is dropped when empty, so a network with no pins looks exactly as it
    /// did, and a pin whose buffer isn't open costs nothing.
    private func networkSections(
        _ id: (Bool) -> SectionID,
        _ header: String,
        _ split: (pinned: [Buffer], rest: [Buffer]),
        _ state: ChatState
    ) -> [Section] {
        var sections: [Section] = []
        if !split.pinned.isEmpty {
            sections.append(Section(
                // Lowercase, matching the connection suffixes this header already carries
                // ("— offline", "— connecting…") — `UIListContentConfiguration.header()`
                // renders the string as given, so the two would otherwise disagree in the
                // same line: "Libera — offline — Pinned".
                id: id(true),
                title: "\(header) — pinned",
                rows: split.pinned.map { rosterRow($0, state) }
            ))
        }
        if !split.rest.isEmpty {
            sections.append(Section(
                id: id(false), title: header, rows: split.rest.map { rosterRow($0, state) }
            ))
        }
        return sections
    }

    private func header(for network: Network) -> String {
        switch network.state {
        case .connected: return network.displayName
        case .connecting: return "\(network.displayName) — connecting…"
        case .reconnecting: return "\(network.displayName) — reconnecting…"
        case .disconnected: return "\(network.displayName) — offline"
        }
    }

    // MARK: - Collection view data source

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = row(at: indexPath) else { return }
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
        // the same backlog a second time. Gated on the explicit Friends-chip flag, not a
        // presence proxy — the moment any other chip kind grows a presence dot, a proxy
        // would quietly start firing this write on its taps.
        if row.isFriendChip, state.buffers[row.buffer.key.id] == nil {
            viewModel.openBuffer(row.buffer.key)
        }
        onSelect?(row.buffer)
    }

    /// Trailing swipe on a roster row leaves/closes the buffer. Grid chips get nothing — the
    /// shortcut isn't the buffer's home, so leaving from it would be a surprise.
    private func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard sectionID(at: indexPath)?.layout == .list, let buffer = row(at: indexPath)?.buffer
        else { return nil }
        // The server log and the system buffer can't be closed.
        guard buffer.kind != .server, buffer.kind != .system else { return nil }
        let title = buffer.kind == .channel ? "Leave" : "Close"
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
    /// roster rows and on the chips alike, so a favorite is also how you *un*favorite.
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
        let target = buffer.target
        let isFavorite = state.isFavorite(buffer.key)
        let title = isFavorite
            ? (isDm ? "Remove from Friends" : "Remove from Favorites")
            : (isDm ? "Add to Friends" : "Add to Favorites")
        let image = isFavorite
            ? UIImage(systemName: isDm ? "person.badge.minus" : "star.slash")
            : UIImage(systemName: isDm ? "person.badge.plus" : "star")
        // ⚠⚠ Close belongs on THIS menu, not only on the roster row's swipe. A favorited
        // buffer has no roster row any more — its chip is where it lives — so without this
        // there is no way to leave a favorited channel short of unfavoriting it first, and
        // the buffers people favorite are exactly the ones they keep. (Favorited DMs had
        // this hole already, having been lifted out since Friends landed.) The web reaches
        // the same conclusion by giving every row, favorites included, one menu ending in
        // Close.
        //
        // Its own inline section, so the separator sets a destructive action apart from the
        // favorite toggle above rather than leaving them a thumb-slip apart.
        let leaveTitle = isDm ? "Close" : "Leave"
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: title, image: image, attributes: isFavorite && isDm ? .destructive : []) { _ in
                    guard let self else { return }
                    if isFavorite {
                        self.viewModel.unfavoriteBuffer(networkId: networkId, target: target)
                    } else {
                        self.viewModel.favoriteBuffer(networkId: networkId, target: target)
                    }
                },
                UIMenu(options: .displayInline, children: [
                    UIAction(
                        title: leaveTitle,
                        image: UIImage(systemName: "xmark"),
                        attributes: .destructive
                    ) { _ in self?.close(buffer) },
                ]),
            ])
        }
    }
}

// MARK: - The shared title pill

/// The same pill the chat screen wears, in the same centre spot — literally the same view,
/// owned by `NavigationPill`. The one control that means "Lurker, and how it's doing" is in
/// one place on both screens. It stands in for the Lurker row this list used to carry, moving
/// that status off a row (which read oddly above the grids) and into the bar.
extension BufferListViewController: PillPresenting {

    /// Fixed except for the light: this screen is the app, not a buffer, so it always reads
    /// "Lurker" and follows the socket rather than any one network.
    var pillContent: PillContent {
        PillContent(
            title: Buffer.system.displayName(),
            status: StatusLight.of(reachable: state.reachable, connection: state.connection, network: nil),
            hint: "Opens the Lurker buffer"
        )
    }

    /// Opens the system buffer rather than a buffer-info sheet, which is what the chat screen's
    /// tap does — this screen *is* the app, so there's no one buffer to describe.
    func pillTapped() {
        openSystemBuffer()
    }
}

// MARK: - Reordering favorites (#53)

/// Dragging a Favorites or Friends chip into a new position.
///
/// The order is the SERVER's one global favorites list (lurker#721), shared with the web
/// client — a drop maps through `FavoriteOrder` onto the stored global order and sends the
/// full permuted bufferId list; the `favorites-changed` echo is what makes it stick on every
/// device.
///
/// Confined to the chip's OWN section in both directions — the two grids are kind-filtered
/// views of one list (a channel isn't a person), Recent is MRU-ordered, and a chip dropped
/// anywhere foreign would snap back on the next rebuild, which is a worse answer than not
/// accepting the drop.
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
        return [item]
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dragSessionIsRestrictedToDraggingApplication session: UIDragSession
    ) -> Bool { true }

    /// The same shape for the lift and for the landing. UIKit asks separately: this method is
    /// scoped to "the item being lifted from, or cancelling back to, the collection view", and
    /// the *drop* animation reads `dropPreviewParametersForItemAt` below — so implementing only
    /// this one made a chip lift with rounded corners and land square, which is the artifact
    /// `BufferChipCell.dragPreviewParameters` exists to prevent.
    func collectionView(
        _ collectionView: UICollectionView,
        dragPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        (collectionView.cellForItem(at: indexPath) as? BufferChipCell)?.dragPreviewParameters
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        (collectionView.cellForItem(at: indexPath) as? BufferChipCell)?.dragPreviewParameters
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        // `hasActiveDrag`, not `session.localDragSession != nil`. The latter says only that the
        // drag began somewhere in this *app* — and this screen carries a search field, which is
        // a real in-app drag source for selected text. Dragging that over the grid passed the
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
            // Over Recent or a roster row. `.forbidden` is the one that draws the
            // no-drop badge; `.cancel` is silent, which left the chip looking droppable
            // everywhere right up until it flew home. The rule is only discoverable if the
            // gesture says so while it's being made.
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        // TWO sections reorder now (Favorites and Friends), but a chip belongs to exactly
        // one — a channel isn't a person. A cross-section hover must say `.forbidden` HERE,
        // while the gesture is being made: `performDropWith` would refuse it anyway (the
        // key resolves against the destination's rows and misses), but only after the
        // layout opened an insertion gap and the UI said yes. Section identity, stashed
        // when the chip lifted, not key membership: this runs per touch-move, and
        // sections are frozen for the drag's duration (rebuild defers), so the index
        // stays true — O(1) beats a per-event row scan and can't be fooled by a key that
        // ever appeared in two sections.
        if destinationIndexPath.section != dragSourceSection {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        // Deliberately not checking the drop *index*: a drop past the last chip is a real
        // gesture ("put it at the end") and UIKit can report it as an index one beyond the
        // last row. `performDropWith` clamps it.
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        guard let item = coordinator.items.first,
              let proposed = coordinator.destinationIndexPath,
              let sectionID = sectionID(at: proposed), sectionID.reorderable,
              let sectionIndex = sections.firstIndex(where: { $0.id == sectionID })
        else { return }
        let rows = sections[sectionIndex].rows
        let visible = rows.map(\.buffer.key.id)

        // Resolved by KEY, not by `item.sourceIndexPath`. That index was captured when the chip
        // was lifted, and `sections` can be rebuilt under a live drag — `rebuild()` now defers
        // while one is up, but the index would still be a fact about a model that may since
        // have been replaced, and this write goes to the only copy of the pin list there is.
        // The key is what the drag has actually been carrying all along.
        guard let key = item.dragItem.localObject as? String,
              let from = visible.firstIndex(of: key)
        else { return }
        // A drop past the last chip reads as "put it at the end", so it's clamped to the last
        // row rather than refused — the row count doesn't change during a reorder, so the last
        // valid index is always `count - 1`.
        let source = IndexPath(item: from, section: proposed.section)
        let destination = IndexPath(item: min(proposed.item, rows.count - 1), section: proposed.section)

        // The grid shows a kind-filtered SUBSET of the server's one global favorites list
        // (this section's kinds only, and a favorite whose network is still connecting has
        // a slot and no chip) — so the move is mapped onto the stored order rather than
        // applied by index. `FavoriteOrder` owns that, and answers the stored list
        // unchanged for anything it can't interpret. The FULL permuted list goes to the
        // server (a subset would float to the front and demote everything unmentioned —
        // the other section included); the favorites-changed echo is the authoritative
        // rebuild, and the in-place move below keeps the drop animation honest meanwhile.
        let entries = state.favorites
        let stored = entries.map(\.key.id)
        let reordered = FavoriteOrder.moved(stored, visible: visible, from: source.item, to: destination.item)
        guard reordered != stored else { return }
        let idByKey = Dictionary(entries.map { ($0.key.id, $0.bufferId) }, uniquingKeysWith: { a, _ in a })
        let reorderedIds = reordered.compactMap { idByKey[$0] }
        viewModel.reorderFavorites(bufferIds: reorderedIds)
        // Shadow the new order until the echo folds — the deferred rebuild released at
        // drag end would otherwise restore the store's pre-drop order (a visible snap
        // home, and a corrupt base for a quick second drag). See orderedFavorites(_:).
        favoritesAtDrop = entries
        optimisticFavoriteOrder = reorderedIds

        // The model moves with the view rather than being rebuilt: the echo would reach the
        // same answer, but a full rebuild mid-drop drops the drag animation on the floor. A
        // move inside one section can't change any other — Recent excludes favorites by
        // membership, not by order — so the two are equivalent here.
        sections[sectionIndex].rows.insert(
            sections[sectionIndex].rows.remove(at: source.item), at: destination.item
        )
        rowsByID = Dictionary(
            sections.flatMap { section in
                section.rows.map { (ItemID(section: section.id, key: $0.buffer.key.id), $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Through the data source, not `collectionView.moveItem`: it owns the item order now,
        // and a view moved behind its back is a view the next snapshot would move back.
        var snapshot = dataSource.snapshot()
        let moved = sections[sectionIndex].items
        snapshot.deleteItems(moved)
        snapshot.appendItems(moved, toSection: sectionID)
        dataSource.apply(snapshot, animatingDifferences: false)
        coordinator.drop(item.dragItem, toItemAt: destination)
    }

    /// Runs on a completed drop *and* on a cancelled one, which is what makes it the right
    /// place to release a rebuild `rebuild()` deferred — a drag abandoned over the roster would
    /// otherwise leave the list frozen on whatever it held when the chip was lifted.
    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        // Cleared FIRST: the deferred rebuild below is exactly the path that rebuilds
        // `sections`, after which a stashed section index would be a fact about a
        // model that no longer exists.
        dragSourceSection = nil
        guard rebuildDeferredByDrag else { return }
        rebuild()
    }

    /// Whether this index path is a chip in a section that can be reordered, and still
    /// addresses a row at all.
    /// The row at an index path, by identity.
    ///
    /// Every delegate callback goes through this rather than indexing `sections`: UIKit hands
    /// back positions, and a position is the one thing about this list that isn't stable.
    private func row(at indexPath: IndexPath) -> Row? {
        dataSource.itemIdentifier(for: indexPath).flatMap { rowsByID[$0] }
    }

    /// What kind of section an index path lands in, by identity.
    private func sectionID(at indexPath: IndexPath) -> SectionID? {
        dataSource.sectionIdentifier(for: indexPath.section)
    }

    private func reorderable(_ indexPath: IndexPath) -> Bool {
        sectionID(at: indexPath)?.reorderable == true && row(at: indexPath) != nil
    }
}

// MARK: - Search presentation

/// Search presents *over* this screen without changing the navigation stack, so everything the
/// bar is wearing stays put underneath it — including the pill, which belongs to the stack
/// rather than to any one screen.
///
/// The delegate lives here rather than on the results screen because these callbacks are about
/// what *this* screen does while it's covered. What the results need from them, they're asked
/// for directly: a plain method call reads better than forwarding a protocol, and it keeps the
/// results screen from having to know that a pill exists.
extension BufferListViewController: UISearchControllerDelegate {

    func willPresentSearchController(_ searchController: UISearchController) {
        // Before the results appear, so they never show an answer to a question the field
        // isn't asking — the results screen is reused across searches and can still be holding
        // the last one.
        searchResults.syncToField(searchController.searchBar.text ?? "")
        // "Lurker" floating over a search field belongs to neither: the pill names this screen,
        // and this screen is no longer the one you're looking at.
        navigationPill?.isSuppressed = true
    }

    func willDismissSearchController(_ searchController: UISearchController) {
        // On `willDismiss`, so the pill fades back in alongside the results leaving rather than
        // popping in after them. Note this also runs when a tapped result has *already*
        // navigated — the stack is on the chat screen by then, and the pill correctly returns
        // wearing that buffer's name, because suppression only ever hid what the stack asked
        // for rather than overwriting it.
        navigationPill?.isSuppressed = false
    }
}

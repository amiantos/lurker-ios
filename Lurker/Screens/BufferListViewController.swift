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
/// to, so Favorites and Recent come first as a two-across grid of cards you can hit without
/// looking, and the full grouped roster sits underneath. The grids are *shortcuts* — a
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

    private enum Layout {
        case list
        case grid
    }

    private struct Row: Equatable {
        let buffer: Buffer
        /// The network name, shown on grid chips where the buffer has been lifted out of its
        /// section and would otherwise be ambiguous across networks. Nil on roster rows,
        /// which already sit under their network's header.
        let subtitle: String?
        /// Set only on friend chips: the friend's presence dot state, the contact's display
        /// name (which may differ from the DM nick), and the contact id the row's edit/remove
        /// menu acts on. Equatable so a presence change reconfigures the one chip.
        var presence: FriendPresence?
        var displayName: String?
        var contactId: Int?

        init(
            buffer: Buffer,
            subtitle: String?,
            presence: FriendPresence? = nil,
            displayName: String? = nil,
            contactId: Int? = nil
        ) {
            self.buffer = buffer
            self.subtitle = subtitle
            self.presence = presence
            self.displayName = displayName
            self.contactId = contactId
        }
    }

    private struct Section {
        let title: String?
        let layout: Layout
        let rows: [Row]
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
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)

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
                    // The Friends section renders off these two: the contact list and the
                    // per-nick presence the dots read. A friend coming online is a presence
                    // change with no buffer change, so without these the chip's dot never moves.
                    && $0.contacts == $1.contacts
                    && $0.peerPresence == $1.peerPresence
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
    private func rebuild() {
        let previous = sections
        sections = buildSections(state)
        updatePlaceholder()
        guard Self.sameStructure(previous, sections) else {
            collectionView.reloadData()
            return
        }
        let changed = previous.indices.flatMap { section in
            sections[section].rows.indices.compactMap { row in
                // Compare the whole row, not just its buffer: a friend chip's presence and
                // display name live on the row, so a dot flip has to reconfigure too.
                previous[section].rows[row] != sections[section].rows[row]
                    ? IndexPath(item: row, section: section)
                    : nil
            }
        }
        if !changed.isEmpty { collectionView.reconfigureItems(at: changed) }
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
            placeholderView.configure(.init(
                symbol: "bubble.left.and.bubble.right",
                title: "No networks yet",
                subtitle: "Add a network to start a conversation."
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

    /// Whether two section models place the same buffers in the same order under the same
    /// headers — i.e. nothing but per-buffer contents (unread, highlights) could have moved,
    /// never the shape of the list. Compares buffer *keys*, not the buffers themselves, since
    /// a count change is exactly what we want to fall through to a reconfigure.
    private static func sameStructure(_ a: [Section], _ b: [Section]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.title == y.title, x.layout == y.layout, x.rows.count == y.rows.count else {
                return false
            }
            for (rx, ry) in zip(x.rows, y.rows) where rx.buffer.key != ry.buffer.key {
                return false
            }
        }
        return true
    }

    // MARK: - Layout

    /// One scroll view, section by section: the per-network rosters lay out as grouped lists
    /// (with swipe-to-leave, under a native list header), and Favorites/Recent lay out as a
    /// two-column grid of cards (under a boundary header). Every section carries a title.
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, index < self.sections.count else { return nil }
            let section = self.sections[index]
            let layoutSection: NSCollectionLayoutSection

            switch section.layout {
            case .list:
                var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                // The list's *own* header, not a manual boundary item: the native grouped
                // header sits tight to the first row, whereas a hand-added header stacks on
                // top of the list's top inset and leaves an oversized gap.
                config.headerMode = section.title != nil ? .supplementary : .none
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
                        // Estimated, not absolute: the chip's `card` floors at 64 but grows
                        // with its text, so at accessibility sizes the row expands to fit
                        // rather than clipping the name/network stack.
                        heightDimension: .estimated(64)
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
                if section.title != nil {
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
        if let badge = makeUnreadBadge(unread: row.buffer.unread, highlights: row.buffer.highlights) {
            cell.accessories = [.customView(configuration: .init(customView: badge, placement: .trailing()))]
        } else {
            cell.accessories = [.disclosureIndicator()]
        }
    }

    private lazy var chipRegistration = UICollectionView.CellRegistration<BufferChipCell, Row> {
        cell, _, row in
        cell.configure(
            // Friend chips carry the contact's display name (which may differ from the DM
            // nick); every other chip falls back to the buffer's own name.
            name: row.displayName ?? row.buffer.displayName(),
            network: row.subtitle,
            unread: row.buffer.unread,
            highlights: row.buffer.highlights,
            presence: row.presence
        )
    }

    private lazy var headerRegistration = UICollectionView
        .SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self, indexPath.section < self.sections.count else { return }
            var content = UIListContentConfiguration.header()
            content.text = self.sections[indexPath.section].title
            view.contentConfiguration = content
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

    /// The same views menu the chat screen carries, minus the entries that need a buffer.
    ///
    /// Highlights and Saved are app-scoped — they span every network — so being able to reach
    /// them only from inside some arbitrary conversation was an artifact of the chat screen
    /// having once been the only screen. Search and uploads land here as they're built, which
    /// is the set the desktop client keeps in its bottom toolbar (#49).
    ///
    /// Members is deliberately absent: it describes a channel, and there isn't one here.
    private func viewsItem() -> UIBarButtonItem {
        let highlights = UIAction(title: "Highlights", image: UIImage(systemName: "at")) { [weak self] _ in
            guard let self else { return }
            showHighlights(viewModel: viewModel)
        }
        let bookmarks = UIAction(title: "Saved", image: UIImage(systemName: "bookmark")) { [weak self] _ in
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
    /// #11 will add "Add Network…" alongside the channels.
    private lazy var joinItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let self else { return completion([]) }
                    // Join lives in its own inline group so "Add Friend…" reads as a separate
                    // kind of "add", not one more network to join.
                    let join = UIMenu(title: "", options: .displayInline, children: self.joinElements())
                    let addFriend = UIAction(
                        title: "Add Friend…",
                        image: UIImage(systemName: "person.badge.plus")
                    ) { [weak self] _ in
                        guard let self else { return }
                        ConfigureFriendViewController.present(from: self, viewModel: self.viewModel, editing: nil)
                    }
                    completion([join, addFriend])
                },
            ])
        )
        item.accessibilityLabel = "Add"
        return item
    }()

    /// One network makes the "+" a straight tap through to the prompt — a menu of one is a
    /// tap spent to learn nothing — and several make it a list to pick from.
    ///
    /// Networks that aren't connected are offered but disabled, matching the web's `net-add`:
    /// a JOIN with no socket to travel down goes nowhere, and nothing comes back to say so.
    /// Shown rather than hidden because the network is still yours, and a list that silently
    /// omits it just looks wrong.
    private func joinElements() -> [UIMenuElement] {
        let networks = state.networks.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard !networks.isEmpty else {
            return [UIAction(title: "No networks", attributes: .disabled) { _ in }]
        }
        if networks.count == 1, let only = networks.first {
            return [UIAction(
                title: "Join Channel…",
                attributes: only.state == .connected ? [] : .disabled
            ) { [weak self] _ in
                self?.presentJoinAlert(network: only)
            }]
        }
        return networks.map { network in
            UIAction(
                title: network.name,
                subtitle: network.state == .connected ? nil : "not connected",
                attributes: network.state == .connected ? [] : .disabled
            ) { [weak self] _ in
                self?.presentJoinAlert(network: network)
            }
        }
    }

    private func presentJoinAlert(network: Network) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Join channel", message: "on \(network.name)", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "#channel"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.spellCheckingType = .no
            $0.returnKeyType = .join
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Join", style: .default) { [weak self, weak alert] _ in
            let typed = (alert?.textFields?.first?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self?.join(network: network, channel: typed)
        })
        present(alert, animated: true)
    }

    /// Joining is also switching: you asked for a channel, so land in it. The buffer won't
    /// exist yet — its row arrives with the server's `channel-joined` — so hand over a
    /// synthesized one exactly as a notification tap does, and let the chat screen's
    /// `hydrateIfNeeded` fill it in when the join completes.
    private func join(network: Network, channel typed: String) {
        // A bare sigil is not a name: `ensurePrefix("#")` would send a JOIN for "#".
        guard !ChannelName.fold(typed).isEmpty else { return }
        let channel = ChannelName.ensurePrefix(typed)
        viewModel.joinChannel(networkId: network.id, channel: channel)
        // `buffer(for:)` rather than a hand-built one: `ensurePrefix` accepts the full
        // RFC-1459 sigil set, of which `BufferKind.of` classifies only `#` and `&` as
        // channels — so hardcoding `.channel` here would hand the chat screen a member list
        // its store row disagrees with.
        onSelect?(state.buffer(for: BufferKey(networkId: network.id, target: channel)))
    }

    // MARK: - Sections

    private func buildSections(_ state: ChatState) -> [Section] {
        // A friend's primary DM is shown as its friend chip, so it's hidden from its network's
        // roster (and from Recent) rather than printed twice — matching the web client, whose
        // FRIENDS group likewise lifts these DMs out of their network list.
        let friendDmKeys = Self.friendPrimaryDmKeys(state)

        var byNetwork: [Int: [Buffer]] = [:]
        for buffer in state.buffers.values {
            // The system buffer has no network and no row of its own here anymore — it's the
            // title pill in the bar — so it's simply not collected into a section.
            guard let networkId = buffer.networkId else { continue }
            if friendDmKeys.contains(buffer.key.id) { continue } // shown under Friends instead
            byNetwork[networkId, default: []].append(buffer)
        }

        var sections: [Section] = []

        // Favorites and Recent are shortcuts, not a relocation: a buffer here also keeps its
        // ordinary row in its network section below. The grid chip and the roster row read as
        // different things — a card vs. a row, and only the row leaves the channel on a swipe —
        // so the duplication is a quick way in, not a buffer printed twice by accident.
        let favorites = favoriteRows(state, friendDmKeys: friendDmKeys)
        let recents = recentRows(state, friendDmKeys: friendDmKeys)
        let friends = friendRows(state)
        if !favorites.isEmpty { sections.append(Section(title: "Favorites", layout: .grid, rows: favorites)) }
        if !recents.isEmpty { sections.append(Section(title: "Recent", layout: .grid, rows: recents)) }
        // Right under Recent, as its own two-up grid — the handful of people you keep coming
        // back to, with a live presence dot on each.
        if !friends.isEmpty { sections.append(Section(title: "Friends", layout: .grid, rows: friends)) }

        let networks = state.networks.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        var seen = Set<Int>()
        for network in networks {
            seen.insert(network.id)
            let buffers = (byNetwork[network.id] ?? []).sorted(by: Self.order)
            guard !buffers.isEmpty else { continue }
            sections.append(Section(title: header(for: network), layout: .list, rows: buffers.map(rosterRow)))
        }
        // Buffers whose network isn't in the roster yet (snapshot race).
        for (networkId, buffers) in byNetwork where !seen.contains(networkId) {
            let rest = buffers.sorted(by: Self.order)
            guard !rest.isEmpty else { continue }
            sections.append(Section(title: "network", layout: .list, rows: rest.map(rosterRow)))
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
    private func recentRows(_ state: ChatState, friendDmKeys: Set<String>) -> [Row] {
        // Favorites claim a buffer before Recent does, so a favorite you just opened stays a
        // single Favorites chip rather than printing a second, identical chip in the Recent
        // grid right beside it. Friend primary DMs are likewise excluded — they have their own
        // Friends chip. (All still keep their ordinary roster row below — this only dedups
        // between the grids.)
        let excluded = Set(UserPreferences.standard.favoriteBufferKeys).union(friendDmKeys)
        return UserPreferences.standard.recentBufferKeys
            .filter { !excluded.contains($0) }
            .compactMap { state.buffers[$0] }
            .filter { $0.kind != .system }
            .prefix(Self.recentLimit)
            .map { chipRow($0, state) }
    }

    /// One chip per friend, in the store's alphabetical order, each opening its primary DM.
    /// A target-less contact (which the server won't create) has no DM to open, so it's
    /// skipped rather than shown as a dead chip.
    private func friendRows(_ state: ChatState) -> [Row] {
        state.contacts.compactMap { contact -> Row? in
            guard let target = contact.primaryTarget else { return nil }
            let key = BufferKey(networkId: target.networkId, target: target.nick)
            // `buffer(for:)` resolves an existing DM (keeping its server-cased target and
            // unread count) or synthesizes an unhydrated one to open — the same handoff the
            // join flow uses, so tapping the chip hydrates on the chat screen.
            return Row(
                buffer: state.buffer(for: key),
                subtitle: state.networks[target.networkId]?.name,
                presence: state.primaryPresence(contact),
                displayName: contact.displayName,
                contactId: contact.id
            )
        }
    }

    /// `BufferKey.id`s of every friend's primary DM — the DMs shown as friend chips and
    /// therefore hidden from their network roster and Recent.
    private static func friendPrimaryDmKeys(_ state: ChatState) -> Set<String> {
        Set(state.contacts.compactMap { contact in
            contact.primaryTarget.map { BufferKey(networkId: $0.networkId, target: $0.nick).id }
        })
    }

    /// Pinned buffers, in the order they were pinned. Local to the device (UserDefaults),
    /// which is why they're app-level and span networks freely — unlike the web client's
    /// server pins, which are per-network.
    private func favoriteRows(_ state: ChatState, friendDmKeys: Set<String>) -> [Row] {
        // A friend's primary DM belongs to the Friends grid, so a DM favorited before it became
        // a friend isn't also printed as a Favorites chip beside its Friends chip.
        UserPreferences.standard.favoriteBufferKeys
            .filter { !friendDmKeys.contains($0) }
            .compactMap { state.buffers[$0] }
            .filter { $0.kind != .system }
            .map { chipRow($0, state) }
    }

    private func chipRow(_ buffer: Buffer, _ state: ChatState) -> Row {
        Row(
            buffer: buffer,
            subtitle: buffer.networkId.flatMap { state.networks[$0]?.name }
        )
    }

    private func rosterRow(_ buffer: Buffer) -> Row {
        Row(buffer: buffer, subtitle: nil)
    }

    private func header(for network: Network) -> String {
        switch network.state {
        case .connected: return network.name
        case .connecting: return "\(network.name) — connecting…"
        case .reconnecting: return "\(network.name) — reconnecting…"
        case .disconnected: return "\(network.name) — offline"
        }
    }

    /// Channels, then DMs, then the server log; alphabetical within each.
    ///
    /// Matches the web client's ordering: the alphabetical key strips leading channel sigils
    /// (`##anime` sorts as "anime", not before `#aardvark`), so the two clients list the same
    /// network the same way.
    private nonisolated static func order(_ lhs: Buffer, _ rhs: Buffer) -> Bool {
        func rank(_ kind: BufferKind) -> Int {
            switch kind {
            case .channel: 0
            case .dm: 1
            case .server: 2
            case .system: 3
            }
        }
        if rank(lhs.kind) != rank(rhs.kind) { return rank(lhs.kind) < rank(rhs.kind) }
        return sortKey(lhs.target).localizedCaseInsensitiveCompare(sortKey(rhs.target)) == .orderedAscending
    }

    private nonisolated static func sortKey(_ target: String) -> String {
        var name = Substring(target)
        while let first = name.first, first == "#" || first == "&" { name = name.dropFirst() }
        return String(name)
    }

    // MARK: - Collection view data source

    override func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let section = sections[indexPath.section]
        let row = section.rows[indexPath.row]
        switch section.layout {
        case .list:
            return collectionView.dequeueConfiguredReusableCell(using: listRegistration, for: indexPath, item: row)
        case .grid:
            return collectionView.dequeueConfiguredReusableCell(using: chipRegistration, for: indexPath, item: row)
        }
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
    }

    // MARK: - Collection view delegate

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
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
        // the same backlog a second time.
        if row.contactId != nil, state.buffers[row.buffer.key.id] == nil {
            viewModel.openBuffer(row.buffer.key)
        }
        onSelect?(row.buffer)
    }

    /// Trailing swipe on a roster row leaves/closes the buffer. Grid chips get nothing — the
    /// shortcut isn't the buffer's home, so leaving from it would be a surprise.
    private func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section < sections.count else { return nil }
        let section = sections[indexPath.section]
        guard section.layout == .list, indexPath.row < section.rows.count else { return nil }
        let buffer = section.rows[indexPath.row].buffer
        // The server log and the system buffer can't be closed.
        guard buffer.kind != .server, buffer.kind != .system else { return nil }
        let title = buffer.kind == .channel ? "Leave" : "Close"
        let close = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, done in
            self?.viewModel.closeBuffer(buffer.key)
            // Leaving here is the one moment the client *knows* a buffer is gone. Restoring
            // into one that isn't there lands on a spinner that never resolves (see
            // `SceneDelegate.launchBuffer`), and that path can't detect it — so tell it.
            UserPreferences.standard.forgetLastBuffer(ifMatching: buffer.key)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [close])
    }

    /// Long-press to pin. The Favorites section is only as real as the way to fill it, and
    /// a section with no path into it would just be a permanently empty box. Available on the
    /// roster rows and on the chips alike, so a favorite is also how you *un*favorite.
    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let row = sections[indexPath.section].rows[indexPath.row]

        // A friend chip's menu edits or removes the friend — favoriting a DM that's already a
        // friend chip would be redundant, and Remove is the friend equivalent of "leave".
        if let contactId = row.contactId {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "Edit Friend…", image: UIImage(systemName: "person.crop.circle")) { _ in
                        guard let self, let contact = self.state.contacts.first(where: { $0.id == contactId })
                        else { return }
                        ConfigureFriendViewController.present(from: self, viewModel: self.viewModel, editing: contact)
                    },
                    UIAction(
                        title: "Remove Friend",
                        image: UIImage(systemName: "person.badge.minus"),
                        attributes: .destructive
                    ) { _ in
                        guard let self, let contact = self.state.contacts.first(where: { $0.id == contactId })
                        else { return }
                        self.confirmRemoveFriend(contact)
                    },
                ])
            }
        }

        let buffer = row.buffer
        guard buffer.kind != .system else { return nil }
        let key = buffer.key.id

        // A DM gets friend actions where a channel gets Favorite: a friend is the "favorite
        // person" concept, so a DM favorite would just be a weaker duplicate of it. Edit if a
        // contact already watches this nick, else Add prefilled from it. A DM favorited before
        // this change still offers Unfavorite so it can't get stuck pinned.
        if buffer.kind == .dm, let networkId = buffer.networkId {
            let nick = buffer.target
            let existing = state.contacts.first { contact in
                contact.targets.contains { $0.networkId == networkId && $0.nick.lowercased() == nick.lowercased() }
            }
            let isFavorite = UserPreferences.standard.isFavorite(key)
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                var actions: [UIMenuElement] = [
                    UIAction(
                        title: existing == nil ? "Add Friend…" : "Edit Friend…",
                        image: UIImage(systemName: "person.badge.plus")
                    ) { _ in
                        guard let self else { return }
                        ConfigureFriendViewController.present(
                            from: self,
                            viewModel: self.viewModel,
                            editing: existing,
                            prefill: existing == nil ? (networkId, nick) : nil
                        )
                    },
                ]
                if isFavorite {
                    actions.append(UIAction(title: "Unfavorite", image: UIImage(systemName: "star.slash")) { _ in
                        guard let self else { return }
                        UserPreferences.standard.toggleFavorite(key)
                        self.apply(self.state)
                    })
                }
                return UIMenu(children: actions)
            }
        }

        let isFavorite = UserPreferences.standard.isFavorite(key)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: isFavorite ? "Unfavorite" : "Favorite",
                    image: UIImage(systemName: isFavorite ? "star.slash" : "star")
                ) { _ in
                    UserPreferences.standard.toggleFavorite(key)
                    guard let self else { return }
                    self.apply(self.state)
                },
            ])
        }
    }

    /// Confirm before removing a friend from a long-press — a stray tap shouldn't silently
    /// unfriend someone. (The editor's own Remove button, reached deliberately, doesn't.)
    private func confirmRemoveFriend(_ contact: Contact) {
        // An alert, not an action sheet: it needs no popover anchor, so it's safe on iPad from
        // a context-menu action that doesn't hand us a source rect.
        let alert = UIAlertController(
            title: "Remove \(contact.displayName)?",
            message: "This stops watching their nicks. Your DM history is kept.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.viewModel.deleteContact(id: contact.id)
        })
        present(alert, animated: true)
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

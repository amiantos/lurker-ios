// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Everything this account has ever uploaded, newest first — browse it, search it, and send one
/// again without re-uploading it (#138).
///
/// **Re-sharing is why this is worth having on a phone.** Every other surface here is a way of
/// reading; this one is a way of sending. A file you posted from your phone last week was, until
/// now, findable only by scrolling back through the buffer you posted it to — and if you found it
/// you still had to copy the address out of a message by hand. From here it goes into the
/// composer of the conversation you came from in one tap, with no second copy of the bytes
/// anywhere.
///
/// **Tap copies the address; press-and-hold carries everything else, viewing included.** The other
/// way round is the obvious arrangement and the wrong one here — you come to this screen to SEND
/// something you already have, so the free gesture should be the one that gets it into a message.
/// Viewing is the occasional case (*which* of these three screenshots was it), and that is what a
/// press-and-hold is for.
///
/// A REST read like Bookmarks and Search (`GET /api/uploads`), paged by a `before` cursor. It is
/// deliberately NOT a `HistoryFeedViewController` despite the family resemblance: that base is
/// built around a message row and its jump-to-conversation, and an upload is a file rather than a
/// line — a grid of thumbnails, with actions ON the row instead of a way out of it.
///
/// **The filters are the server's.** Filename search, kind and starred all go on the wire, which
/// is the documented exception to this app's filters-are-client-side rule: this screen holds only
/// the pages it has scrolled through, and the whole point of the search is finding one it hasn't.
/// See `UploadsRequest`.
final class UploadsViewController: UIViewController, UISearchResultsUpdating {

    private let viewModel: ChatViewModel

    /// Put this URL in the composer. Set only by a presenter that HAS one.
    ///
    /// ⚠⚠ Nil is what gates the affordance, and it has to be gated: the buffer list reaches this
    /// screen too, and there is no composer mounted behind it. An "Add to Message" offered there
    /// would land nowhere and report nothing — a button that silently works on one screen and not
    /// the other. Copy Link is the answer from the list, and it is right there in the same menu.
    var onInsert: ((String) -> Void)?

    private var items: [UploadItem] = []
    private var filter = UploadsFilter()
    /// The filter the rows currently on screen are the answer to.
    ///
    /// ⚠⚠ Not the same thing as `filter`, and the gap between them is the whole point: while a
    /// filter change is in flight the grid still shows the PREVIOUS question's rows, which is
    /// right — blanking a readable grid on every keystroke is worse than a moment of staleness —
    /// and becomes a lie the instant that request FAILS. Without this there was nothing left to
    /// tell "these are the matches for what you typed" from "these are what was here before".
    private var shownFilter = UploadsFilter()
    /// The smallest id seen, which is the next page's `before`. Nil once there is nothing to
    /// page from.
    private var cursor: Int?
    private var hasMore = true
    /// The starred view came back at the server's ceiling, so there may be more it didn't send.
    private var isTruncated = false
    private var isLoading = false
    /// The first fetch failed with nothing to show — distinct from an empty result, so the
    /// placeholder can offer a retry rather than claim the history is empty.
    private var loadFailed = false
    /// Bumped by every `reload()`. A page carries the generation it was requested under, and one
    /// that lands under a newer generation is dropped — the list it was fetched for no longer
    /// exists. The counter is the correctness mechanism; cancelling the task is the cost saving.
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    /// The keystroke waiting to become a query, cancelled and replaced by the next one.
    private var debounce: Task<Void, Never>?

    private let placeholder = StateView()
    private lazy var collectionView = UICollectionView(
        frame: .zero,
        // Read at layout time rather than captured: the disclosure comes and goes with the
        // starred filter, and the section provider re-runs on every `reloadData`.
        collectionViewLayout: UploadsGrid.makeLayout { [weak self] in self?.isTruncated ?? false }
    )

    /// Fetch the next page once a tile this far from the end comes on screen, so the grid extends
    /// before the reader hits the bottom rather than stalling on it.
    private static let prefetchThreshold = 12

    /// Long enough that a typed word is one request rather than eight, short enough that the grid
    /// still feels like it is responding.
    ///
    /// ⚠ Shorter than message search's 350ms on purpose. That one is throttling an FTS query over
    /// every message the account has ever seen, running synchronously on the event loop that also
    /// services every IRC connection on the cell; this is a `LIKE` over one user's own upload
    /// rows. Same shape, an order of magnitude apart in what a wasted request costs.
    private static let debounceMilliseconds = 250

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Uploads"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.leftBarButtonItem = filterItem

        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        // Scrolling puts the keyboard away: this screen is read *while typing at it*, so the
        // keyboard covers a chunk of what was just fetched and the gesture for getting rid of it
        // should be the one the reader is already making.
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(UploadTileCell.self, forCellWithReuseIdentifier: UploadTileCell.reuseID)
        collectionView.register(
            UploadsFooterView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
            withReuseIdentifier: UploadsFooterView.reuseID
        )
        collectionView.backgroundView = placeholder
        collectionView.refreshControl = UIRefreshControl()
        collectionView.refreshControl?.addAction(
            UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)

        // ⚠⚠ Pinned to the VIEW's edges, not the safe area's. The grid has to run underneath the
        // navigation bar at the top and the search bar at the bottom so content scrolls under the
        // translucent chrome, which is what every scrolling screen on this platform does — the
        // safe area's job here is the content INSET (which UIKit adjusts itself), not a clip.
        // Constrained to the safe area, the grid stopped dead above the search field and the
        // last row sat against a hard edge with nothing passing behind it.
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        installSearchBar()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The toolbar holding the search field belongs to the navigation controller, not to this
        // screen, so it has to be asked for on the way in — and put back on the way out, since
        // the sheet may show other screens that have no business with a bottom bar.
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // ⚠ Only on the way OUT, not on the way behind something. Presenting the media viewer or
        // a share sheet over this screen must not cancel the page it is loading; the guard is
        // what tells the two apart.
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        debounce?.cancel()
        cancelLoad()
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    // MARK: - Filters

    /// The filter menu, opposite Done.
    ///
    /// A menu rather than a row of chips, which is what the web client uses. Five kinds plus a
    /// starred toggle is more than fits across a phone without wrapping to a second row, and the
    /// bar under the title is the one piece of vertical space a browsing grid can least afford.
    /// It is also simply where iOS puts filtering — Photos, Files and Mail all do this.
    ///
    /// ⚠ The cost is that an active filter is invisible until the menu is opened, so the button
    /// fills in when anything is set and the empty state names the filter in words. A grid that
    /// looks empty for a reason the reader cannot see is the one failure mode this owes them.
    ///
    /// ⚠ Its contents are DEFERRED, so the checkmarks are computed when the button is pressed
    /// rather than baked in whenever the item happened to be built. Rebuilding the item instead
    /// would close the menu out from under whoever had it open.
    private lazy var filterItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.filterMenu() ?? [])
                }
            ])
        )
        item.accessibilityLabel = "Filter"
        return item
    }()

    private func filterMenu() -> [UIMenuElement] {
        let all = UIAction(title: "All") { [weak self] _ in self?.setFilter { $0.kind = nil } }
        all.state = filter.kind == nil ? .on : .off
        let kinds = UploadKind.allCases.map { kind in
            let action = UIAction(title: kind.label) { [weak self] _ in
                self?.setFilter { $0.kind = kind }
            }
            action.state = filter.kind == kind ? .on : .off
            return action
        }
        // ⚠⚠ Starred is its OWN section, not a sixth kind. It composes with a kind — "my starred
        // gifs" is a view somebody wants — so putting it among five mutually-exclusive options
        // would be lying about what tapping it does. `.singleSelection` on the kinds is what says
        // those five ARE exclusive.
        let starred = UIAction(
            title: "Starred Only",
            image: UIImage(systemName: filter.favoritesOnly ? "star.fill" : "star")
        ) { [weak self] _ in
            self?.setFilter { $0.favoritesOnly.toggle() }
        }
        starred.state = filter.favoritesOnly ? .on : .off
        return [
            UIMenu(title: "", options: [.displayInline, .singleSelection], children: [all] + kinds),
            UIMenu(title: "", options: .displayInline, children: [starred]),
        ]
    }

    private func setFilter(_ change: (inout UploadsFilter) -> Void) {
        var next = filter
        change(&next)
        guard next != filter else { return }
        filter = next
        filterItem.image = UIImage(
            systemName: next.isNarrowed
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        reload()
    }

    // MARK: - Search

    /// Own the search field, in the bottom bar — the same arrangement message search uses, and
    /// for the same reason: on a phone that is where a thumb already is.
    private func installSearchBar() {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchResultsUpdater = self
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = "Search filenames"
        // A filename is not English. Autocapitalizing turns `img_4821` into `Img_4821` and
        // autocorrect rewrites the stems people actually type.
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        controller.searchBar.spellCheckingType = .no
        navigationItem.searchController = controller
        navigationItem.preferredSearchBarPlacement = .integrated
        toolbarItems = [navigationItem.searchBarPlacementBarButtonItem]
    }

    /// Fires for activation and dismissal as well as for edits, so unchanged text is dropped —
    /// otherwise merely focusing the field would re-run the search already on screen and scroll
    /// the grid back to the top.
    func updateSearchResults(for searchController: UISearchController) {
        // ⚠ Trimmed here rather than in the field: leading and trailing spaces are almost always
        // an accident of typing, and a search for " " should not be a search.
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        // Cancel BEFORE the up-to-date check. `filter.query` only advances when the debounce
        // fires, so editing back to the committed text inside the window — type `cat`, backspace
        // to `ca` — reaches this having already scheduled `cat`. Returning without cancelling
        // leaves that armed, and a moment later the grid searches for text the field no longer
        // holds.
        debounce?.cancel()
        guard text != filter.query else { return }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            guard !Task.isCancelled else { return }
            self?.setFilter { $0.query = text }
        }
    }

    // MARK: - Loading

    /// (Re)fetch from the newest page. Used on first appearance, by pull-to-refresh, and every
    /// time the filter changes.
    private func reload() {
        // ⚠ Deliberately does NOT bail while a load is in flight: a filter change must SUPERSEDE
        // the request it replaces, or the grid settles on the answer to the previous keystroke.
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let filter = self.filter
        let limit = UploadsRequest.limit(for: filter)
        isLoading = true
        loadFailed = false
        // Cleared now, not when the page lands: it describes the list the PREVIOUS filter
        // produced, and leaving it up under a grid that is being replaced would caption the wrong
        // one for as long as the request takes. The layout has to be told, since the section
        // provider only re-runs on a reload it has no reason to do yet.
        if isTruncated {
            isTruncated = false
            collectionView.collectionViewLayout.invalidateLayout()
        }
        renderPlaceholder()
        loadTask = Task { [weak self] in
            guard let self, generation == loadGeneration else { return }
            let page = await viewModel.fetchUploads(filter: filter, limit: limit)
            // ⚠ A cancelled fetch reports nil, which is indistinguishable from a failure here —
            // and the handler would put an error placeholder up for a request the reader
            // superseded by typing.
            guard !Task.isCancelled else { return }
            handleFirstPage(page, generation: generation, filter: filter, limit: limit)
        }
    }

    /// Give up on the page in flight because nobody is waiting for it any more.
    private func cancelLoad() {
        guard loadTask != nil else { return }
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        collectionView.refreshControl?.endRefreshing()
    }

    private func loadMore() {
        guard !isLoading, hasMore, let before = cursor else { return }
        let generation = loadGeneration
        let filter = self.filter
        let limit = UploadsRequest.limit(for: filter)
        isLoading = true
        loadTask = Task { [weak self] in
            // Re-checked once the task actually starts, not only when its answer arrives: the
            // filter can have moved on in the turn between capturing the cursor and running.
            guard let self, generation == loadGeneration else { return }
            let page = await viewModel.fetchUploads(filter: filter, before: before, limit: limit)
            guard !Task.isCancelled else { return }
            appendPage(page, generation: generation, filter: filter, limit: limit)
        }
    }

    @MainActor
    private func handleFirstPage(
        _ page: UploadsPage?, generation: Int, filter: UploadsFilter, limit: Int
    ) {
        // Superseded: a newer reload owns the grid now and will report its own result. Returning
        // before touching `isLoading` matters — clearing it here would let a scroll page the old
        // filter's cursor into the new filter's list.
        guard generation == loadGeneration else { return }
        isLoading = false
        collectionView.refreshControl?.endRefreshing()
        let changedQuestion = filter != shownFilter
        guard let page else {
            loadFailed = true
            // ⚠⚠ A failed load of a DIFFERENT question has to take the old rows with it. Left up,
            // the whole unfiltered history stands in as "the matches for cat" with nothing said —
            // and the stale `cursor`/`hasMore` then page the real matches onto the end of it.
            // A failed REFRESH keeps its rows: same question, and there is something to read.
            if changedQuestion {
                items = []
                cursor = nil
                hasMore = false
                isTruncated = false
                shownFilter = filter
                collectionView.reloadData()
            }
            renderPlaceholder()
            return
        }
        items = page.items
        cursor = items.last?.id
        hasMore = UploadsRequest.hasMore(filter: filter, received: page.items.count, limit: limit)
        isTruncated = UploadsRequest.isTruncated(filter: filter, received: page.items.count)
        shownFilter = filter
        collectionView.reloadData()
        // ⚠ Back to the top, but only for a new question. `reloadData` keeps the content offset
        // (clamped to the new height), so searching from deep in a long grid landed the reader on
        // the OLDEST few matches with the newest scrolled off above — which reads as the search
        // having found the wrong ones. A refresh is already at the top, so it is left alone rather
        // than fighting a reader who pulled from somewhere else.
        if changedQuestion {
            collectionView.setContentOffset(
                CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        }
        renderPlaceholder()
    }

    @MainActor
    private func appendPage(
        _ page: UploadsPage?, generation: Int, filter: UploadsFilter, limit: Int
    ) {
        guard generation == loadGeneration else { return }
        isLoading = false
        guard let page else {
            // A failed *continuation* leaves what is on screen alone — there is a grid to read,
            // and blanking it for the sake of a page that didn't arrive would be worse than
            // stopping. Scrolling re-fires the request.
            return
        }
        let start = items.count
        items.append(contentsOf: page.items)
        cursor = items.last?.id
        hasMore = UploadsRequest.hasMore(filter: filter, received: page.items.count, limit: limit)
        collectionView.insertItems(
            at: (start..<items.count).map { IndexPath(item: $0, section: 0) })
        renderPlaceholder()
    }

    /// The three states a grid with nothing in it can be in, plus the starred view's truncation
    /// disclosure. Every path that changes `items` ends here.
    private func renderPlaceholder() {
        guard items.isEmpty else {
            placeholder.isHidden = true
            return
        }
        placeholder.isHidden = false
        placeholder.onAction = nil
        if isLoading {
            placeholder.configure(StateView.Model(title: "Loading uploads…", isLoading: true))
        } else if loadFailed {
            placeholder.configure(
                StateView.Model(
                    symbol: "exclamationmark.triangle",
                    title: "Couldn't load uploads",
                    subtitle: "Pull to try again."
                ))
        } else if !filter.query.isEmpty {
            // ⚠ Names what is filtered, in words. With the filter living in a menu the reader
            // can't see it, an unqualified "no matches" would send someone hunting for files that
            // are right there behind a narrowing they forgot they set — so the line says which
            // uploads were searched as well as what for.
            placeholder.configure(
                StateView.Model(
                    symbol: "magnifyingglass",
                    title: "No matches",
                    subtitle: filter.noMatchesLine
                ))
        } else if filter.favoritesOnly {
            // Names the gesture, the way the Bookmarks feed does. An empty starred view is what
            // somebody who has never starred anything sees, and telling them the list is empty
            // without telling them how to put something in it is the least useful true statement
            // available.
            placeholder.configure(
                StateView.Model(
                    symbol: "star",
                    title: "No \(filter.scope)",
                    subtitle: "Press and hold an upload, then Star, to keep it here."
                ))
        } else if filter.isNarrowed {
            placeholder.configure(
                StateView.Model(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "No \(filter.scope)",
                    subtitle: "Nothing you've uploaded is under this filter."
                ))
        } else {
            placeholder.configure(
                StateView.Model(
                    symbol: "photo.on.rectangle",
                    title: "No uploads yet",
                    subtitle: "Files you send with the paperclip in a conversation are kept here."
                ))
        }
    }

    // MARK: - Opening

    /// Put the file's address on the pasteboard, and say so.
    ///
    /// ⚠ The toast is not decoration. Copying changes nothing on screen, so without a word for it
    /// the tap is indistinguishable from a missed touch and the reader taps again — which, for the
    /// primary gesture on every tile of this screen, is the difference between the feature working
    /// and the feature seeming broken.
    private func copyLink(_ item: UploadItem) {
        guard !item.removed else { return reportTombstone() }
        UIPasteboard.general.string = item.url
        ToastView.show("Link Copied", symbol: "link", over: view)
    }

    /// The bytes are gone, so there is nothing to copy, view, or share. Said rather than left as a
    /// gesture that visibly did nothing — the tile is dimmed and captioned "Removed", but a tap
    /// that silently does nothing still reads as a missed touch.
    private func reportTombstone() {
        report(
            title: "Upload Removed",
            message: "This file was removed by the server's operator. The record is kept, but the "
                + "file itself is gone."
        )
    }

    /// Look at the file, from the menu.
    ///
    /// The viewer opens as a GALLERY over every viewable row currently in the grid, positioned on
    /// the one that was picked — which means the filters double as a way to scope it: narrow to
    /// Images, search "march", and left/right walks exactly those.
    private func open(_ item: UploadItem) {
        guard !item.removed else { return reportTombstone() }
        let gallery = items.compactMap(Self.preview)
        if let start = gallery.firstIndex(where: { $0.url == item.url }) {
            present(
                MediaViewerController(previews: gallery, startAt: start, model: viewModel),
                animated: true)
            return
        }
        // Nothing the viewer can present — a text file, a PDF, or an address this app is not
        // allowed to load. The browser can, and handing it over beats a tap that does nothing.
        guard let url = URL(string: item.url) else { return }
        UIApplication.shared.open(url)
    }

    /// An upload as the media viewer's descriptor, or nil for one it cannot show.
    ///
    /// ⚠⚠ An image's `src` is the upload's OWN address, not a proxy path — the one place in this
    /// app that is true. Preview `src` is proxied so that rendering a stranger's link can't report
    /// the reader to that stranger's host; here the host is the uploader this account chose and
    /// the file is one this account put there, so there is no third party to be hidden from. The
    /// media request builder takes an absolute URL, and deliberately sends it no bearer token.
    ///
    /// ⚠ Video and audio pass `thumb` and never `src`, matching the rule `LinkPreview.inlinePicture`
    /// documents: those are streamed from their origin by the player rather than fetched as bytes.
    /// Text has no viewer page at all, so it falls through to the browser.
    ///
    /// ⚠ `nonisolated` because it is passed as a function reference to `compactMap`, whose
    /// closure is not on the main actor. It reads only its argument, so isolating it buys
    /// nothing (the same reasoning `LurkerClient.mediaRequest` documents).
    nonisolated private static func preview(_ item: UploadItem) -> LinkPreview? {
        guard !item.removed, let kind = item.kind else { return nil }
        let preview: LinkPreview? =
            switch kind {
            case .image:
                LinkPreview(
                    url: item.url, status: .ok, kind: .image, title: item.filename,
                    src: item.url, mime: item.mime)
            case .video:
                LinkPreview(
                    url: item.url, status: .ok, kind: .video, title: item.filename,
                    thumb: item.thumbnailPath, mime: item.mime)
            case .audio:
                LinkPreview(
                    url: item.url, status: .ok, kind: .audio, title: item.filename,
                    thumb: item.thumbnailPath, mime: item.mime)
            case .text:
                nil
            }
        // The same gate the message list uses, so a clip this app cannot legally load (cleartext
        // to a public host, refused by App Transport Security) falls through to the browser
        // rather than promising a player and failing deep inside AVFoundation.
        guard let preview, preview.isViewable else { return nil }
        return preview
    }

    // MARK: - Row actions

    /// Star or unstar, optimistically.
    ///
    /// The row flips now and reverts if the server refuses. Starring is cheap and reversible, and
    /// a state badge that waits on a round trip before changing reads as a missed tap.
    private func toggleStar(_ item: UploadItem) {
        let wanted = !item.favorite
        // ⚠ Unstarring inside the starred view removes the row: it no longer belongs to the list
        // being shown. Leaving it there would put an unstarred file in a view whose only rule is
        // that everything in it is starred.
        let leavesTheView = filter.favoritesOnly && !wanted
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let original = items[index]
        if leavesTheView {
            removeRow(at: index)
        } else {
            items[index] = original.settingFavorite(wanted)
            collectionView.reconfigureItems(at: [IndexPath(item: index, section: 0)])
        }
        // ⚠⚠ The list this revert belongs to. `restore` puts a missing row back BY INDEX, which is
        // what an unstar-in-the-starred-view needs — and which, against a list that has since been
        // replaced, splices a foreign row into it and sets `cursor` to an id from a list that no
        // longer exists. Star a row, switch the filter to Video, then have the request fail: the
        // image lands in the video grid and the next page is fetched from its id.
        let generation = loadGeneration
        Task { [weak self] in
            guard let self, let message = await viewModel.setUploadFavorite(id: item.id, favorite: wanted)
            else { return }
            // It didn't take. Put the row back exactly as it was and say why — a star that
            // silently un-flips a second later is worse than one that never moved. The row is only
            // restored into the list it came from; the failure is reported either way, because the
            // server state is unchanged whichever list is on screen now.
            if generation == loadGeneration { restore(original, at: index) }
            report(title: wanted ? "Couldn't Star" : "Couldn't Unstar", message: message)
        }
    }

    /// Destroy the stored bytes, after asking.
    ///
    /// ⚠ Only ever offered for a row whose `canDelete` is set — see `UploadItem.canDelete`. And
    /// only after a confirmation, because unlike everything else on this screen it is not a change
    /// to a list: the file goes, and any message that ever linked it now links nothing.
    private func confirmDelete(_ item: UploadItem) {
        let alert = UIAlertController(
            title: "Delete \(item.displayName)?",
            message: "The file is removed from storage. Links to it in past messages will stop working.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                self?.delete(item)
            })
        presentOverTop(alert)
    }

    private func delete(_ item: UploadItem) {
        Task { [weak self] in
            guard let self else { return }
            if let message = await viewModel.deleteUpload(id: item.id) {
                // The bytes weren't destroyed, so the row stays and the reason surfaces.
                report(title: "Couldn't Delete", message: message)
                return
            }
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            removeRow(at: index)
        }
    }

    private func removeRow(at index: Int) {
        items.remove(at: index)
        cursor = items.last?.id
        collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
        renderPlaceholder()
    }

    /// Put a row back where it was after a failed optimistic change.
    private func restore(_ item: UploadItem, at index: Int) {
        if let existing = items.firstIndex(where: { $0.id == item.id }) {
            items[existing] = item
            collectionView.reconfigureItems(at: [IndexPath(item: existing, section: 0)])
            return
        }
        let at = min(index, items.count)
        items.insert(item, at: at)
        cursor = items.last?.id
        collectionView.insertItems(at: [IndexPath(item: at, section: 0)])
        renderPlaceholder()
    }

    /// Say something went wrong, over whatever is currently up.
    ///
    /// ⚠⚠ Presented from the frontmost VC in this screen's chain, not from `self`. These reports
    /// land after an await, by which time the reader may have opened the media viewer or a share
    /// sheet — and UIKit silently drops a `present` on a controller that is already presenting.
    /// The star would visibly un-flip with no explanation, which is the exact outcome this path
    /// exists to prevent.
    private func report(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentOverTop(alert)
    }

    /// Put `controller` up over whatever is frontmost in this screen's chain.
    private func presentOverTop(_ controller: UIViewController) {
        var host: UIViewController = self
        while let presented = host.presentedViewController { host = presented }
        host.present(controller, animated: true)
    }
}

// MARK: - Data source & delegate

extension UploadsViewController: UICollectionViewDataSource, UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: UploadTileCell.reuseID, for: indexPath)
        if let tile = cell as? UploadTileCell, items.indices.contains(indexPath.item) {
            tile.configure(items[indexPath.item], model: viewModel)
        }
        return cell
    }

    /// The starred view's truncation disclosure, at the END of the grid.
    ///
    /// ⚠ In the content rather than pinned under it. The line says "there may be more starred
    /// uploads than these", which is an answer to having reached the bottom — so the bottom is
    /// where it should be read. Pinning it above the search bar also meant the grid could not run
    /// underneath that bar, which cost every screenful the scroll-under the platform expects.
    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: UploadsFooterView.reuseID, for: indexPath)
        (view as? UploadsFooterView)?.text =
            "Showing your \(items.count) most recently starred uploads."
        return view
    }

    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        if indexPath.item >= items.count - Self.prefetchThreshold { loadMore() }
    }

    /// Tap copies the address. Looking at the file is in the menu.
    ///
    /// The other way round is the obvious arrangement and the wrong one for this screen. You come
    /// here to SEND something you already have — you know what the file is, you had it — so the
    /// gesture that costs nothing should be the one that gets it into a message, not the one that
    /// puts it full-screen. Viewing is the occasional case (which of these three screenshots was
    /// it), and the occasional case is what a press-and-hold is for.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard items.indices.contains(indexPath.item) else { return }
        copyLink(items[indexPath.item])
    }

    /// Everything you can do to one file, on a press-and-hold.
    ///
    /// The web puts these as buttons over each tile, revealed on hover. There is no hover here,
    /// and three finger-sized buttons will not fit on a tile a third of a phone wide — the
    /// context menu is where iOS already puts per-item actions, and it can afford words.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard items.indices.contains(indexPath.item) else { return nil }
        let item = items[indexPath.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: self?.actions(for: item) ?? [])
        }
    }

    private func actions(for item: UploadItem) -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        // First, because it is what the tap used to do — the menu is where viewing lives now, and
        // the entry a reader who taps and gets a "Link Copied" toast will come looking for.
        //
        // ⚠ Named for what will actually happen. Text uploads and anything App Transport Security
        // refuses have no page in the viewer and hand off to the browser instead, and a "View"
        // that leaves the app is a worse surprise than a button that says so.
        if !item.removed {
            let viewable = Self.preview(item) != nil
            actions.append(
                UIAction(
                    title: viewable ? "View" : "Open in Browser",
                    image: UIImage(systemName: viewable ? "eye" : "safari")
                ) { [weak self] _ in self?.open(item) })
        }
        if let onInsert, !item.removed {
            actions.append(
                UIAction(title: "Add to Message", image: UIImage(systemName: "arrow.turn.down.left")) {
                    [weak self] _ in
                    // Out of the way on the way out: you asked for this file, so the browse is
                    // over, and leaving the sheet up over the composer you just typed into would
                    // be in the way.
                    self?.dismiss(animated: true) { onInsert(item.url) }
                })
        }
        // ⚠⚠ `!removed || favorite`, not just `!removed`. A takedown does not clear the star —
        // the server keeps it, so the state survives a restore — which means a tombstone can
        // arrive already starred. Hiding the control on every removed row would strand that star
        // with no way in any UI to clear it. Nothing new can be starred from a tombstone; an
        // existing one can be undone.
        if !item.removed || item.favorite {
            actions.append(
                UIAction(
                    title: item.favorite ? "Unstar" : "Star",
                    image: UIImage(systemName: item.favorite ? "star.slash" : "star")
                ) { [weak self] _ in self?.toggleStar(item) })
        }
        if !item.removed {
            // Kept even though a tap does it: the menu is meant to be the complete list of what
            // can be done to a file, and a reader who opens it looking for "copy" should find one
            // rather than have to know about the gesture.
            actions.append(
                UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) {
                    [weak self] _ in self?.copyLink(item)
                })
            actions.append(
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) {
                    [weak self] _ in self?.share(item)
                })
        }
        if item.canDelete {
            actions.append(
                UIAction(
                    title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
                ) { [weak self] _ in self?.confirmDelete(item) })
        }
        return actions
    }

    private func share(_ item: UploadItem) {
        guard let url = URL(string: item.url) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        present(sheet, animated: true)
    }
}

extension UploadItem {
    /// The same row with its star flipped, for an optimistic update.
    fileprivate func settingFavorite(_ favorite: Bool) -> UploadItem {
        UploadItem(
            id: id, url: url, filename: filename, mime: mime, byteSize: byteSize,
            createdAt: createdAt, favorite: favorite, canDelete: canDelete,
            thumbnailPath: thumbnailPath, removed: removed)
    }
}

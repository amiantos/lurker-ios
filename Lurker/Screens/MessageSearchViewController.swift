// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Full-text search over everything the account has ever said or been told, across every
/// buffer at once. Tapping a match jumps to it in its conversation.
///
/// The results ARE a `HistoryFeedViewController` — the same rows, the same channel+day
/// headers, the same cursor paging, the same jump — because a search result and a highlight
/// and a bookmark are the same thing three ways: a line from somewhere else, shown out of
/// context, that you want to go to. That base was written expecting this ("Search and uploads
/// are the next two that fit here"); what's left here is the query.
///
/// **Two ways this screen is used, and one of them is the point.**
///
///  - `.resultsController` — it's the `searchResultsController` of somebody else's
///    `UISearchController`, and the search field lives on that screen. This is how the buffer
///    list uses it: the field sits in the bottom bar, and these results slide up over the list
///    as soon as you type. The iOS 26 arrangement, and the reachable one — the field is under
///    your thumb rather than at the top of a screen you have to stretch for.
///  - `.standalone` — it owns its own search field, for when search is *presented* rather than
///    lived in: "Search in Buffer" from a conversation, which opens pre-scoped to it.
///
/// Either way this object is the `UISearchResultsUpdating`, so the debounce, the query and the
/// paging have exactly one implementation.
final class MessageSearchViewController: HistoryFeedViewController, UISearchResultsUpdating {

    enum Presentation {
        /// Someone else owns the search field; this screen is only the results.
        case resultsController
        /// This screen owns its own search field, in its own bottom bar.
        case standalone
    }

    private let presentation: Presentation

    /// The query the currently-shown results answer. Committed by the debounce, not by the
    /// keystroke — `fetchPage` reads it, and paging must not chase a field that has moved on
    /// since the page it's extending.
    private var query = ""

    /// The keystroke waiting to become a query. Cancelled and replaced by the next one, so a
    /// burst of typing costs one search rather than one per character.
    private var debounce: Task<Void, Never>?

    /// Set by `standalone` only. In `resultsController` mode the field belongs to the host.
    private var ownSearchController: UISearchController?

    /// The text the field starts with — a scope prefix (`in:#chan on:libera `) for a search
    /// opened from a conversation. Applied once, when the field is created.
    private let seed: String

    init(viewModel: ChatViewModel, presentation: Presentation, seed: String = "") {
        self.presentation = presentation
        self.seed = seed
        super.init(viewModel: viewModel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    // MARK: - Feed

    override var feedTitle: String { "Search" }

    /// Each keystroke asks a different question, so a reload must replace the one in flight
    /// rather than be dropped — otherwise the list settles on the answer to a prefix of what
    /// the user typed. See `HistoryFeedViewController.reloadSupersedes`.
    override var reloadSupersedes: Bool { true }

    /// One page of matches. An empty query is answered locally with an empty page rather than
    /// asked (`searchMessages` short-circuits it), which is what puts the "type to search"
    /// prompt up instead of a spinner.
    override func fetchPage(before: Int?) async -> HighlightsPage? {
        await viewModel.searchMessages(query, before: before)
    }

    override var loadingModel: StateView.Model {
        StateView.Model(title: "Searching…", isLoading: true)
    }

    /// Two different empties, and telling them apart is the whole job of this placeholder: a
    /// field nobody has typed in yet is a prompt, and a field with a query in it that matched
    /// nothing is an answer. Collapsing them would greet every open with "No matches" for a
    /// search that was never run.
    override var emptyModel: StateView.Model {
        query.isEmpty
            ? StateView.Model(
                symbol: "magnifyingglass",
                title: "Search your history",
                subtitle: "Everything you've seen, across every network. "
                    + "Narrow it with from:nick, in:#channel, or on:network."
            )
            : StateView.Model(
                symbol: "magnifyingglass",
                title: "No matches",
                subtitle: "Nothing in your history matches \(query)."
            )
    }

    /// Deliberately does not say "pull to try again" the way Highlights and Bookmarks do.
    /// A search can fail for a reason a pull won't fix — the socket is the transport here, so
    /// offline means there is nothing to retry against — and the field is right there, which
    /// is the more natural thing to reach for anyway.
    override var errorModel: StateView.Model {
        StateView.Model(
            symbol: "exclamationmark.triangle",
            title: "Couldn't search",
            subtitle: "Your connection to the server dropped. Try again once it's back."
        )
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Scrolling the results puts the keyboard away. Unlike the other two feeds this screen
        // is read *while typing at it*, so the keyboard covers half of what was just fetched
        // and the gesture for getting rid of it should be the one the user is already making.
        tableView.keyboardDismissMode = .onDrag
        // As somebody else's results controller this screen has no bar of its own to put them
        // in, and the base's Done button would be dismissing a screen it isn't presenting.
        if presentation == .resultsController {
            navigationItem.rightBarButtonItem = nil
        } else {
            installOwnSearchBar()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Opened *to* search: put the keyboard up rather than making the user tap the field
        // they just asked for. Only in standalone mode — as a results controller this screen
        // appears because the host's field is already focused and typing into it.
        guard presentation == .standalone, let bar = ownSearchController?.searchBar,
              !bar.isFirstResponder
        else { return }
        ownSearchController?.isActive = true
        bar.becomeFirstResponder()
    }

    // MARK: - Search field (standalone)

    /// Own the search field, in the bottom bar.
    ///
    /// `.integrated` plus a toolbar is what puts it there: on iPhone, UIKit folds an integrated
    /// search bar into the view controller's toolbar when it has one, and
    /// `searchBarPlacementBarButtonItem` is the slot that says where among the toolbar's items
    /// it goes. It's the only item here, so it takes the whole bar.
    ///
    /// `obscuresBackgroundDuringPresentation` is off because there is nothing to obscure — the
    /// results and the field are on the same screen, and the default dimming would grey out
    /// the very list the user is reading.
    private func installOwnSearchBar() {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchResultsUpdater = self
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = "Search messages"
        // The filter grammar is typed, not tapped, so the field must not fight it:
        // autocapitalizing turns `from:` into `From:`, and autocorrect rewrites nicks and
        // channel names into English words.
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        controller.searchBar.spellCheckingType = .no
        if !seed.isEmpty {
            controller.searchBar.text = seed
            // Commit it directly rather than waiting for the updater: a seeded search should
            // already be showing its results when the screen appears.
            commit(seed)
        }
        navigationItem.searchController = controller
        navigationItem.preferredSearchBarPlacement = .integrated
        toolbarItems = [navigationItem.searchBarPlacementBarButtonItem]
        ownSearchController = controller
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The toolbar belongs to the navigation controller, not to this screen, so it has to
        // be asked for on the way in — and put back on the way out, since the sheet this sits
        // in may show other screens that have no business with a bottom bar.
        if presentation == .standalone {
            navigationController?.setToolbarHidden(false, animated: animated)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if presentation == .standalone {
            navigationController?.setToolbarHidden(true, animated: animated)
        }
    }

    // MARK: - UISearchResultsUpdating

    /// Debounced, at the web client's own 200ms: a search is an FTS scan on the server and a
    /// round trip, and dispatching one per character would spend most of them on prefixes
    /// nobody wanted the answer to.
    ///
    /// Fires for activation and dismissal too, not only for edits, so unchanged text is
    /// dropped — otherwise merely focusing the field would re-run the search that's already
    /// on screen and scroll it back to the top.
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            guard !Task.isCancelled else { return }
            self?.commit(text)
        }
    }

    /// Adopt `text` as the query and run it. `reload()` supersedes anything in flight, so the
    /// last committed query is always the one whose answer lands.
    private func commit(_ text: String) {
        query = text
        reload()
    }

    private static let debounceMilliseconds = 200
}

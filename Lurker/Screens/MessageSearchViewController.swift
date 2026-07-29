// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Full-text search over everything the account has ever said or been told, across every
/// buffer at once. Tapping a match jumps to it in its conversation.
///
/// **With nothing typed, it shows your bookmarks.** iMessage's search opens the same way — not
/// on a blank prompt but on a quick-jump surface (recent chats, pinned links) that happens to
/// be *reachable* rather than *searched for*. Saved messages are this app's version of that:
/// the lines you already decided were worth coming back to, which is exactly the set worth
/// putting one tap from the search field. It also means the screen is never the empty box that
/// prompted this — opening search always lands on something you can act on.
///
/// Bookmarks are what that landing view holds *today*, not a definition of it — the surface is
/// "what's worth jumping to before you've asked for anything", and other things may earn a
/// place in it. It carries no heading for that reason: a list titled "Bookmarks" would be a
/// claim about the whole view rather than about one thing in it, and would have to be unwound
/// the first time something else appeared alongside them.
///
/// Swapping between the two costs nothing, because this screen is a
/// `HistoryFeedViewController` and both are the same kind of thing to it: lines from
/// elsewhere, newest first, tap to go there. Same rows, same channel+day headers, same cursor
/// paging, same jump — the base was written expecting exactly this ("Search and uploads are the
/// next two that fit here"). Only where a page comes from differs, and both arrive as a
/// `HighlightsPage`. What's left in this file is the query.
///
/// Typing is deliberately NOT a filter over the bookmarks. Bookmarks are the landing surface,
/// not the corpus — narrowing to them would make the most useful search in the app (everything
/// you have ever seen) the one search you couldn't run from here.
///
/// Rows are read-only, unlike the Bookmarks screen's swipe-to-remove. This is somewhere you
/// pass *through* on the way to a conversation; unsaving is a deliberate act, and it belongs on
/// the screen devoted to them.
///
/// **Where the search field lives** is the one structural choice, and the reason this class has
/// a `Presentation`:
///
///  - `.resultsController` — the field belongs to another screen and this is only its
///    `searchResultsController`. How the buffer list uses it: the field sits in that screen's
///    bottom bar and these results slide up over the list as soon as you type. The iOS 26
///    arrangement, and the reachable one — the field is under your thumb rather than at the top
///    of a screen you'd have to stretch for.
///  - `.standalone` — it owns a field of its own, in its own bottom bar, for when search is
///    *presented* rather than lived in: "Search This Conversation", which opens pre-scoped.
///
/// Either way this object is the `UISearchResultsUpdating`, so the debounce, the query and the
/// paging have exactly one implementation.
final class MessageSearchViewController: HistoryFeedViewController, UISearchResultsUpdating,
                                         UISearchControllerDelegate {

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

    /// Which mode the list is currently in. Derived from the query at commit time and then
    /// *held*, rather than recomputed wherever it's needed: a page arriving from the wire has
    /// to be interpreted as whatever was asked for, not as whatever the field says by the time
    /// it lands. Starts true — a screen that hasn't been typed in yet is showing bookmarks.
    private var isBrowsingSaved = true

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
        // Adopt the seed as the query *before* the base's first load, so a scoped open fetches
        // its search directly. Committing it later would work — a reload supersedes — but it
        // would spend a bookmarks round trip on a screen that was never going to show them.
        query = seed
        isBrowsingSaved = SearchQuery.parse(seed).isEmpty
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    // MARK: - Feed

    override var feedTitle: String { "Search" }

    /// Each keystroke asks a different question, so a reload must replace the one in flight
    /// rather than be dropped — otherwise the list settles on the answer to a prefix of what
    /// the user typed. See `HistoryFeedViewController.reloadSupersedes`.
    override var reloadSupersedes: Bool { true }

    /// One page — of bookmarks while the field is empty, of matches once it isn't.
    ///
    /// The two travel by different roads: bookmarks are a REST read with a real `nextBefore`
    /// cursor, search is a WS request/reply whose cursor is synthesized. Both arrive as a
    /// `HighlightsPage`, which is the whole reason this screen can switch between them without
    /// the list knowing.
    override func fetchPage(before: Int?) async -> HighlightsPage? {
        isBrowsingSaved
            ? await viewModel.fetchBookmarks(before: before)
            : await viewModel.searchMessages(query, before: before)
    }

    override var loadingModel: StateView.Model {
        StateView.Model(
            title: isBrowsingSaved ? "Loading saved messages…" : "Searching…",
            isLoading: true
        )
    }

    /// Three different empties, and telling them apart is most of this placeholder's job.
    ///
    /// The first is the one that matters: a new account has no bookmarks, so the landing
    /// surface is empty for exactly the people who most need telling what this screen does. So
    /// it says both things — that you can search, and that saving a message puts it here —
    /// rather than leaving the second to be discovered.
    override var emptyModel: StateView.Model {
        guard !isBrowsingSaved else {
            return StateView.Model(
                symbol: "magnifyingglass",
                title: "Search your history",
                subtitle: "Type to search every network — narrow it with from:nick, "
                    + "in:#channel, or on:network. Messages you save show up here too."
            )
        }
        return StateView.Model(
            symbol: "magnifyingglass",
            title: "No matches",
            subtitle: "Nothing in your history matches \(query)."
        )
    }

    /// The search half deliberately does not say "pull to try again" the way Highlights and
    /// Bookmarks do: search rides the socket, so offline means there is nothing to retry
    /// against, and the field is right there — the more natural thing to reach for anyway.
    /// Browsing bookmarks is an ordinary REST read, so it gets the ordinary advice.
    override var errorModel: StateView.Model {
        isBrowsingSaved
            ? StateView.Model(
                symbol: "exclamationmark.triangle",
                title: "Couldn't load saved messages",
                subtitle: "Pull to try again."
            )
            : StateView.Model(
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
        // The query is already `seed` (see `init`), so this only puts it in the field — the
        // updater sees text it already has and does nothing, which is what we want: the search
        // is running, and re-committing here would just restart it.
        if !seed.isEmpty { controller.searchBar.text = seed }
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

    // MARK: - UISearchControllerDelegate

    /// Reconcile with the field *before* the results appear, so search is never presented
    /// showing an answer to a question the field isn't asking.
    ///
    /// This screen outlives a single search: it's the buffer list's results controller, built
    /// once and reused, still holding the last query's rows when search is opened again. Whether
    /// the field still holds that query on reopen is UIKit's call, not ours — so rather than
    /// assume either way, adopt whatever it says.
    ///
    /// Both outcomes are then right for free. If the text survived, it matches `query` and
    /// nothing happens: the results stay, which is what you want for "search → read one →
    /// come back for the next one" (the web client persists its query across opens for exactly
    /// that flow). If UIKit cleared it, this snaps back to the bookmarks *now* rather than
    /// after the debounce, which would have flashed the stale results on the way.
    func willPresentSearchController(_ searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        debounce?.cancel()
        commit(text)
    }

    /// Adopt `text` as the query and run it. `reload()` supersedes anything in flight, so the
    /// last committed query is always the one whose answer lands.
    ///
    /// This is also where the screen changes mode, and it reads the *parsed* query rather than
    /// the raw string so that "empty" means the same thing here as it does to the server: a
    /// field holding only spaces is empty, and one holding only `in:#dev` is not. Deleting back
    /// to nothing returns to the bookmarks, which is what makes the field feel like a filter
    /// you can back out of rather than a mode you entered.
    private func commit(_ text: String) {
        query = text
        isBrowsingSaved = SearchQuery.parse(text).isEmpty
        reload()
    }

    private static let debounceMilliseconds = 200
}

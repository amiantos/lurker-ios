// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Full-text search over everything the account has ever said or been told, across every
/// buffer at once. Tapping a match jumps to it in its conversation.
///
/// **With nothing typed, it shows your recent highlights.** iMessage's search opens the same
/// way — not on a blank prompt but on a quick-jump surface (recent chats, pinned links) that
/// happens to be *reachable* rather than *searched for*. Highlights are this app's version of
/// that: the lines that were addressed to you since you last looked, which is both the set most
/// likely to be what you came to find and the set that goes stale if you don't. It also means
/// the screen is never the empty box that prompted this — opening search always lands on
/// something you can act on.
///
/// Highlights are what that landing view holds *today*, not a definition of it — the surface is
/// "what's worth jumping to before you've asked for anything", and it held bookmarks first.
/// Hence `Showing.landing` rather than a case named after its contents, and hence no heading: a
/// list titled "Highlights" would be a claim about the whole view rather than about one thing
/// in it, and would have to be unwound the first time something else appeared alongside them.
///
/// Swapping between the two costs nothing, because this screen is a
/// `HistoryFeedViewController` and both are the same kind of thing to it: lines from
/// elsewhere, newest first, tap to go there. Same rows, same channel+day headers, same cursor
/// paging, same jump — the base was written expecting exactly this ("Search and uploads are the
/// next two that fit here"). Only where a page comes from differs, and both arrive as a
/// `HighlightsPage`. What's left in this file is the query.
///
/// Typing is deliberately NOT a filter over the landing view. It is the landing surface, not
/// the corpus — narrowing to it would make the most useful search in the app (everything you
/// have ever seen) the one search you couldn't run from here.
///
/// Rows are read-only. This is somewhere you pass *through* on the way to a conversation, so
/// acting on a line belongs where the line is, or on the screen devoted to it.
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
final class MessageSearchViewController: HistoryFeedViewController, UISearchResultsUpdating {

    enum Presentation {
        /// Someone else owns the search field; this screen is only the results.
        case resultsController
        /// This screen owns its own search field, in its own bottom bar.
        case standalone
    }

    private let presentation: Presentation

    /// What the list is currently showing. Decided at commit time and then *held*, rather than
    /// recomputed wherever it's needed: a page arriving from the wire has to be interpreted as
    /// an answer to whatever was asked for, not to whatever the field says by the time it lands.
    private enum Showing {
        /// Nothing typed — the landing view (recent highlights).
        case landing
        /// Something typed, but not yet enough to be worth asking the server. See
        /// `Showing.of(_:)`.
        case tooShort
        /// A real query, dispatched.
        case results

        /// What a parsed query should put on screen. The two rules it reads — "is there
        /// anything to search on" and "is it enough to be worth asking" — belong to the query
        /// itself and live on `SearchQuery`, so this is only the mapping to a view state.
        static func of(_ query: SearchQuery) -> Showing {
            if query.isEmpty { return .landing }
            if query.needsMoreText { return .tooShort }
            return .results
        }
    }

    private var showing: Showing = .landing

    /// The raw text the currently-shown list answers, for the "no matches for …" copy.
    private var query = ""

    /// …and its parsed form, which is what actually decides whether a keystroke is worth a
    /// round trip. Two raw strings that parse the same ask the server the same question, so
    /// only this moving is a reason to search again.
    private var parsed = SearchQuery(text: "", from: [], target: "", network: "")

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
        // would spend a landing-view round trip on a screen that was never going to show it.
        query = seed
        parsed = SearchQuery.parse(seed)
        showing = Showing.of(parsed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    // MARK: - Feed

    override var feedTitle: String { "Search" }

    /// Each keystroke asks a different question, so a reload must replace the one in flight
    /// rather than be dropped — otherwise the list settles on the answer to a prefix of what
    /// the user typed. See `HistoryFeedViewController.reloadSupersedes`.
    override var reloadSupersedes: Bool { true }

    /// One page — of highlights while the field is empty, of matches once it holds a real query.
    ///
    /// The two travel by different roads: highlights are a REST read with a real `nextBefore`
    /// cursor, search is a WS request/reply whose cursor is synthesized. Both arrive as a
    /// `HighlightsPage`, which is the whole reason this screen can switch between them without
    /// the list knowing.
    ///
    /// `.tooShort` is answered here, locally, and never reaches the wire — that's the point of
    /// the state. Answering it with an empty page (rather than nil) matters: nil means "we
    /// couldn't ask", which would put an error in front of someone who is simply mid-word.
    override func fetchPage(before: Int?) async -> HighlightsPage? {
        switch showing {
        case .landing: await viewModel.fetchHighlights(before: before)
        case .tooShort: HighlightsPage(items: [], nextBefore: nil)
        case .results: await viewModel.searchMessages(query, before: before)
        }
    }

    override var loadingModel: StateView.Model {
        StateView.Model(
            title: showing == .landing ? "Loading highlights…" : "Searching…",
            isLoading: true
        )
    }

    /// Three different empties, and telling them apart is most of this placeholder's job.
    ///
    /// `.landing` is the one that matters most: a quiet account has no highlights, so the
    /// landing surface is empty for exactly the people who most need telling what this screen
    /// does. So it says both things — that you can search, and what the list would otherwise
    /// have held — rather than leaving the second to be discovered.
    override var emptyModel: StateView.Model {
        switch showing {
        case .landing:
            StateView.Model(
                symbol: "magnifyingglass",
                title: "Search your history",
                subtitle: "Type to search every network — narrow it with from:nick, "
                    + "in:#channel, or on:network. Messages that match your highlight "
                    + "rules show up here too."
            )
        case .tooShort:
            // Says the rule rather than just withholding results, so a field that has visibly
            // stopped responding is explained instead of looking broken.
            StateView.Model(
                symbol: "ellipsis",
                title: "Keep typing",
                subtitle: "Searches start at two characters."
            )
        case .results:
            StateView.Model(
                symbol: "magnifyingglass",
                title: "No matches",
                subtitle: "Nothing in your history matches \(query)."
            )
        }
    }

    /// The search half deliberately does not say "pull to try again" the way Highlights and
    /// Bookmarks do: search rides the socket, so offline means there is nothing to retry
    /// against, and the field is right there — the more natural thing to reach for anyway.
    /// The landing view is an ordinary REST read, so it gets the ordinary advice.
    override var errorModel: StateView.Model {
        showing == .landing
            ? StateView.Model(
                symbol: "exclamationmark.triangle",
                title: "Couldn't load highlights",
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

    /// Debounced, and deliberately longer than the web client's 200ms.
    ///
    /// **A search is the most expensive thing this client can ask for.** `better-sqlite3` is
    /// synchronous, so the FTS query runs *on the server's event loop* — the same loop
    /// servicing every IRC connection on that cell. That is not a theoretical cost: the
    /// snapshot builder had to be chunked for exactly this reason, after long synchronous reads
    /// starved socket I/O badly enough to trip IRC ping timeouts (#460, #469). Riding a
    /// WebSocket makes the *transport* cheap and changes nothing about the query behind it.
    ///
    /// So the debounce has to be longer than the gap between keystrokes, or it isn't coalescing
    /// anything. 200ms isn't: thumb-typing lands in roughly the 150–300ms range, so a fair
    /// share of characters cleared the old window and each one bought a full query. 350ms sits
    /// above that band while staying below the point where the field feels laggy.
    ///
    /// Nothing can cancel a search already on the wire — the protocol has no cancel frame, so a
    /// superseded query still runs to completion server-side and we merely discard the reply.
    /// Not dispatching it in the first place is the only lever there is.
    ///
    /// Fires for activation and dismissal too, not only for edits, so unchanged text is
    /// dropped — otherwise merely focusing the field would re-run the search that's already
    /// on screen and scroll it back to the top.
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        // Cancel BEFORE the up-to-date check, not after. `query` only advances when the debounce
        // fires, so editing back to the committed text inside the window — type `hip`, backspace
        // to `hi` — reaches this having already scheduled `hip`. Returning without cancelling
        // leaves that task armed, and 350ms later the screen searches for text the field no
        // longer contains. Cancelling first makes "the field already matches what's shown" mean
        // exactly that, including that nothing else is on its way.
        debounce?.cancel()
        guard text != query else { return }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            guard !Task.isCancelled else { return }
            self?.commit(text)
        }
    }

    // MARK: - Host

    /// Reconcile with the field, for a host to call *before* presenting these results — so
    /// search is never presented showing an answer to a question the field isn't asking.
    ///
    /// This screen outlives a single search: it's the buffer list's results controller, built
    /// once and reused, still holding the last query's rows when search is opened again. Whether
    /// the field still holds that query on reopen is UIKit's call, not ours — so rather than
    /// assume either way, adopt whatever it says.
    ///
    /// Both outcomes are then right for free. If the text survived, it matches `query` and the
    /// results stay, which is what you want for "search → read one → come back for the next one"
    /// (the web client persists its query across opens for exactly that flow). If UIKit cleared
    /// it, this snaps back to the landing view *now* rather than after the debounce, which would
    /// have flashed the stale results on the way.
    ///
    /// The landing view is the exception to "unchanged text changes nothing", because its answer
    /// expires: highlights accumulate while you're elsewhere in the app, and since this screen is
    /// built once and reused, an unchanged empty field would otherwise show whatever was fetched
    /// the first time search was opened — for the rest of the session. Bookmarks tolerated that;
    /// mentions are the set that goes stale if you don't look. A search's rows are left alone,
    /// because a query's answer is a fact about history rather than a feed.
    func syncToField(_ text: String) {
        guard text != query else {
            if showing == .landing { reload() }
            return
        }
        debounce?.cancel()
        commit(text)
    }

    /// Adopt `text` as the query and run it. `reload()` supersedes anything in flight, so the
    /// last committed query is always the one whose answer lands.
    ///
    /// This is also where the screen changes mode, and it reads the *parsed* query rather than
    /// the raw string so that "empty" means the same thing here as it does to the server: a
    /// field holding only spaces is empty, and one holding only `in:#dev` is not. Deleting back
    /// to nothing returns to the landing view, which is what makes the field feel like a filter
    /// you can back out of rather than a mode you entered.
    private func commit(_ text: String) {
        let next = SearchQuery.parse(text)
        let nextShowing = Showing.of(next)
        query = text
        // Nothing the server would answer differently — the keystroke moved only whitespace, or
        // the field is still below the floor. Typing a space between two words is the common
        // case, and it used to cost a full round trip for a query identical to the last one.
        guard next != parsed || nextShowing != showing else { return }
        parsed = next
        showing = nextShowing
        reload()
    }

    private static let debounceMilliseconds = 350
}

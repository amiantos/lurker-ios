// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// The paging rules of a cross-buffer feed (Activity, Bookmarks, Search): which page to ask for
/// next, which answer may land, and which placeholder stands in for the rows.
///
/// The half of the app's `HistoryFeedViewController` that isn't table plumbing, kept synchronous
/// and pure so the rules can be tested. The screen runs the fetches this hands it and reports
/// each answer back through `land`; what comes back says whether the rows changed and whether
/// another page should be asked for straight away. lurker-android's `FeedPager` is the same
/// machine.
///
/// A REST read paginated by a cursor rather than streamed: it fetches on open and pages as you
/// scroll, with pull-to-refresh to pick up anything that changed while it sat open.
public struct FeedPaging {
    /// Which of a feed's three placeholders stands in for its rows. Each feed words them itself.
    public enum Placeholder: Equatable, Sendable { case loading, empty, error }

    /// One page to fetch, stamped with the reload it was asked for under.
    public struct Fetch: Equatable, Sendable {
        /// The reload generation this answers; an answer under a newer one is dropped.
        public let generation: Int
        /// Where the page starts — nil for the first (newest) page.
        public let cursor: FeedCursor?

        public var isFirstPage: Bool { cursor == nil }
    }

    /// What an answer did to the list.
    public struct Landing: Equatable, Sendable {
        /// `items` was replaced or grew, so the grouped view has to be rebuilt.
        public let rowsChanged: Bool
        /// The round added no rows but a cursor is still live: ask for this next, now. See
        /// `settle`.
        public let next: Fetch?
    }

    /// All rows, newest-first as the server returns them, after the ignore filter.
    public private(set) var items: [HighlightItem] = []
    /// Nil while there are rows to show.
    public private(set) var placeholder: Placeholder? = .loading
    public private(set) var isLoading = false

    /// Whether a `reload()` replaces a page already in flight rather than being dropped.
    ///
    /// False for the feeds whose reload is idempotent: pulling Activity twice re-fetches the same
    /// newest page, so the second pull buys nothing and dropping it keeps the refresh control
    /// honest. True for Search, where two reloads are two *different questions* and the one the
    /// user typed last is the only one whose answer they want.
    public let supersedes: Bool

    /// The next-page cursor from the last response; nil once the server has no more.
    private var nextCursor: FeedCursor?
    private var reachedEnd = false

    /// Bumped by every `reload()`. A page carries the generation it was requested under, and one
    /// that lands under a newer generation is dropped — the list it was fetched for no longer
    /// exists.
    ///
    /// Needed the moment a feed's reload can mean something *different* from the one in flight
    /// (Search, where each keystroke is a new query), but it isn't only for that: a pull-to-refresh
    /// landing while a page-in was in flight would otherwise append the old list's next page onto
    /// the new list.
    private var generation = 0

    /// The first fetch failed — distinct from an empty result, so the placeholder can offer a
    /// retry rather than claim the feed is empty.
    private var loadFailed = false

    /// Consecutive auto-page hops that yielded no visible rows.
    ///
    /// Each hop is a full history/FTS query on the server, and the chain is self-feeding: a page
    /// that filters to nothing asks for the next one. Against a channel an ignored sender dominates
    /// that can run the entire history, dozens of round trips deep, behind a spinner that never
    /// resolves. The cap stops the runaway; paging isn't lost, because scrolling asks again and
    /// every reload restores the budget.
    private var fruitlessHops = 0
    static let maxFruitlessHops = 10

    public init(supersedes: Bool) {
        self.supersedes = supersedes
    }

    /// Whether `fetch` still answers the list on screen. Re-checked when its request actually
    /// starts, not only when its answer arrives: the body of a fetch runs a turn after it was
    /// handed out, and a superseded page still costs a full query on the server.
    public func isCurrent(_ fetch: Fetch) -> Bool { fetch.generation == generation }

    /// (Re)fetch from the newest page: on open, on a pull, and — for Search — every time the
    /// question changes. Nil when dropped: a repeat reload of a feed that doesn't supersede while
    /// a page is still loading.
    ///
    /// `newQuestion` clears the old answer at once — rows, cursor and end — and shows the loading
    /// placeholder (lurker-ios#203). Keeping them, as a pull does, read as the answer to the new
    /// question: the "foo" rows stood under "bar" until it answered, and if it failed they stayed
    /// with no error at all, while the next scroll paged foo's cursor and `fetchPage` read bar's
    /// query, appending bar's matches from before foo's last id under foo's rows. A pull asks the
    /// same question again, so the rows it already has stay up under the refresh control's own
    /// spinner rather than blanking.
    ///
    /// The hop budget is restored here (lurker-ios#204), not only when rows are gained: otherwise
    /// a feed or a question that once spent it would come back from a pull, or the next search
    /// whose first page is all ignored lines, with an empty list while real rows sat a page away.
    public mutating func reload(newQuestion: Bool = false) -> Fetch? {
        guard !isLoading || supersedes else { return nil }
        generation += 1
        isLoading = true
        loadFailed = false
        fruitlessHops = 0
        if newQuestion {
            items = []
            nextCursor = nil
            reachedEnd = false
        }
        // Only the full-screen spinner on a cold load; a pull keeps the list up.
        if items.isEmpty { placeholder = .loading }
        return Fetch(generation: generation, cursor: nil)
    }

    /// The next older page, if there is one and nothing is already loading.
    public mutating func loadMore() -> Fetch? {
        guard !isLoading, !reachedEnd, let cursor = nextCursor else { return nil }
        isLoading = true
        return Fetch(generation: generation, cursor: cursor)
    }

    /// Give up on the page in flight without asking another — nobody is waiting for it. Its
    /// answer can no longer land. The placeholder is left alone: an error would claim a failure
    /// when the user simply left.
    public mutating func abandon() {
        generation += 1
        isLoading = false
    }

    /// A page arrived (nil: the fetch failed). Nil back when it was superseded and has touched
    /// nothing — not even `isLoading`, since clearing that would let a scroll page the *old*
    /// question's cursor into the new question's list. `visible` is the ignore filter, applied
    /// as pages land.
    public mutating func land(
        _ page: HighlightsPage?,
        for fetch: Fetch,
        visible: ([HighlightItem]) -> [HighlightItem]
    ) -> Landing? {
        guard isCurrent(fetch) else { return nil }
        isLoading = false
        return fetch.isFirstPage ? landFirst(page, visible: visible) : landMore(page, visible: visible)
    }

    private mutating func landFirst(
        _ page: HighlightsPage?, visible: ([HighlightItem]) -> [HighlightItem]
    ) -> Landing {
        guard let page else {
            // A failed pull under rows keeps them, and their cursor: it asked the same question,
            // so what's on screen still answers it. A failed new question has no rows by now
            // (`reload(newQuestion:)` cleared them), so it says it failed.
            loadFailed = true
            if items.isEmpty { placeholder = .error }
            return Landing(rowsChanged: false, next: nil)
        }
        items = visible(page.items)
        nextCursor = page.next
        reachedEnd = !page.hasMore
        return Landing(rowsChanged: true, next: settle(gainedRows: !items.isEmpty))
    }

    private mutating func landMore(
        _ page: HighlightsPage?, visible: ([HighlightItem]) -> [HighlightItem]
    ) -> Landing {
        guard let page else {
            // A failed page-in leaves what we have and just stops paging; the user can pull to
            // refresh. Don't latch `reachedEnd` — the next scroll re-arms `loadMore`.
            //
            // Unless there's nothing left on screen: `remove` can page from an emptied list, and
            // there no scroll will ever retry. Say the fetch failed rather than spin forever.
            if items.isEmpty {
                loadFailed = true
                settlePlaceholder()
            }
            return Landing(rowsChanged: false, next: nil)
        }
        // Filtered before the emptiness check, so a page that holds nothing but ignored lines
        // takes the same path as one the server returned empty: record the cursor, then let
        // `settle` decide whether to page past it.
        let fresh = visible(page.items)
        nextCursor = page.next
        reachedEnd = !page.hasMore
        guard !fresh.isEmpty else { return Landing(rowsChanged: false, next: settle(gainedRows: false)) }
        items.append(contentsOf: fresh)
        return Landing(rowsChanged: true, next: settle(gainedRows: true))
    }

    /// Drop one row, by message id. Nil back when it's already gone.
    ///
    /// By id, not position: the list can be replaced underneath an open swipe (a pull lands), and
    /// a position resolved again then removes whatever now occupies that slot. Emptying the list
    /// by removing things is not failing to load it, so the failure latch clears — a refresh that
    /// failed while rows were still up would otherwise leave "Couldn't load" as the epitaph for a
    /// list the user just cleared.
    public mutating func remove(messageId: Int) -> Landing? {
        guard let index = items.firstIndex(where: { $0.message.id == messageId }) else { return nil }
        items.remove(at: index)
        if items.isEmpty { loadFailed = false }
        return Landing(rowsChanged: true, next: settle(gainedRows: false))
    }

    /// Close out a list mutation: either ask for the next page, or say what the list now shows.
    ///
    /// The rule is about rows *gained*, not about the list being empty. The screen pages off rows
    /// coming on screen, so a round that adds none can never ask for another — a dead end whether
    /// the list holds zero rows or three: a search whose second page is entirely an ignored sender
    /// would otherwise stop at three results with a live cursor sitting there.
    private mutating func settle(gainedRows: Bool) -> Fetch? {
        if gainedRows { fruitlessHops = 0 }
        let stalled = !gainedRows && !reachedEnd && nextCursor != nil
        if stalled, fruitlessHops < Self.maxFruitlessHops {
            fruitlessHops += 1
            // Only claim to be loading when there's nothing to look at. Topping up beneath a
            // list the user is already reading should be silent.
            if items.isEmpty { placeholder = .loading }
            return loadMore()
        }
        settlePlaceholder()
        return nil
    }

    private mutating func settlePlaceholder() {
        placeholder = items.isEmpty ? (loadFailed ? .error : .empty) : nil
    }
}

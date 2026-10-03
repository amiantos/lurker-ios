// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The cross-buffer feeds' paging rules: which answer may land, what a new question does to the
/// old answer (lurker-ios#203), and the skip-ahead budget past pages an ignore rule empties
/// (lurker-ios#204).
final class FeedPagingTests: XCTestCase {

    // MARK: - Fixtures

    private func item(_ id: Int, nick: String = "alice") -> HighlightItem {
        HighlightItem(
            message: Message(id: id, type: .message, nick: nick, text: "hi"),
            networkId: 1, target: "#a", networkName: nil
        )
    }

    private func page(_ ids: [Int], nick: String = "alice", nextBefore: Int?) -> HighlightsPage {
        HighlightsPage(items: ids.map { item($0, nick: nick) }, nextBefore: nextBefore)
    }

    /// The ignore filter, as the screen applies it: "mallory" is ignored.
    private let visible: ([HighlightItem]) -> [HighlightItem] = { items in
        items.filter { $0.message.nick != "mallory" }
    }

    /// A feed showing ids 30...21 with a live cursor at 21.
    private func loaded(supersedes: Bool) -> FeedPaging {
        var paging = FeedPaging(supersedes: supersedes)
        let first = paging.reload()!
        _ = paging.land(page(Array((21...30).reversed()), nextBefore: 21), for: first, visible: visible)
        return paging
    }

    private func ids(_ paging: FeedPaging) -> [Int] { paging.items.map(\.message.id) }

    // MARK: - A new question (lurker-ios#203)

    func testANewQuestionClearsTheOldAnswerAndShowsLoading() {
        var paging = loaded(supersedes: true)
        XCTAssertNotNil(paging.reload(newQuestion: true))
        XCTAssertEqual(ids(paging), [], "foo's rows would read as the answer to bar")
        XCTAssertEqual(paging.placeholder, .loading)
    }

    /// The issue's own steps: "foo" up, type "bar", bar fails, scroll.
    func testAFailedNewQuestionShowsTheErrorAndCannotPageTheOldCursor() {
        var paging = loaded(supersedes: true)
        let bar = paging.reload(newQuestion: true)!
        let landing = paging.land(nil, for: bar, visible: visible)
        XCTAssertEqual(landing, FeedPaging.Landing(rowsChanged: false, next: nil))
        XCTAssertEqual(ids(paging), [])
        XCTAssertEqual(paging.placeholder, .error)
        XCTAssertNil(paging.loadMore(), "foo's cursor would page bar's query under foo's rows")
    }

    func testANewQuestionThatAnswersPagesFromItsOwnCursor() {
        var paging = loaded(supersedes: true)
        let bar = paging.reload(newQuestion: true)!
        _ = paging.land(page([9, 8], nextBefore: 8), for: bar, visible: visible)
        XCTAssertEqual(ids(paging), [9, 8])
        XCTAssertNil(paging.placeholder)
        XCTAssertEqual(paging.loadMore()?.cursor, FeedCursor(beforeMessage: 8))
    }

    func testAPageInFromTheOldQuestionLandingAfterTheNewOneIsDropped() {
        var paging = loaded(supersedes: true)
        let fooMore = paging.loadMore()!
        let bar = paging.reload(newQuestion: true)!
        XCTAssertFalse(paging.isCurrent(fooMore), "re-checked before the request goes out")
        XCTAssertNil(paging.land(page([20, 19], nextBefore: 19), for: fooMore, visible: visible))
        XCTAssertEqual(ids(paging), [])
        XCTAssertTrue(paging.isLoading, "bar is still out; clearing this would let a scroll page")
        _ = paging.land(page([9], nextBefore: nil), for: bar, visible: visible)
        XCTAssertEqual(ids(paging), [9])
    }

    func testAFirstPageFromTheOldQuestionLandingAfterTheNewOneIsDropped() {
        var paging = FeedPaging(supersedes: true)
        let foo = paging.reload()!
        let bar = paging.reload(newQuestion: true)!
        XCTAssertNil(paging.land(page([30], nextBefore: nil), for: foo, visible: visible))
        XCTAssertNil(paging.land(nil, for: foo, visible: visible), "nor may its failure")
        XCTAssertEqual(paging.placeholder, .loading)
        _ = paging.land(page([9], nextBefore: nil), for: bar, visible: visible)
        XCTAssertEqual(ids(paging), [9])
    }

    // MARK: - The same question again (a pull)

    func testAPullKeepsItsRowsWhileItLoads() {
        var paging = loaded(supersedes: false)
        XCTAssertNotNil(paging.reload())
        XCTAssertEqual(paging.items.count, 10)
        XCTAssertNil(paging.placeholder, "the refresh control spins; the rows stay up")
    }

    /// A failed pull asked the same question, so the rows and their cursor still answer it.
    func testAFailedPullKeepsItsRowsAndTheirCursor() {
        var paging = loaded(supersedes: true)
        let pull = paging.reload()!
        _ = paging.land(nil, for: pull, visible: visible)
        XCTAssertEqual(paging.items.count, 10)
        XCTAssertNil(paging.placeholder)
        XCTAssertEqual(paging.loadMore()?.cursor, FeedCursor(beforeMessage: 21))
    }

    func testAPullThatAnswersReplacesTheRows() {
        var paging = loaded(supersedes: false)
        let pull = paging.reload()!
        _ = paging.land(page([31, 30], nextBefore: nil), for: pull, visible: visible)
        XCTAssertEqual(ids(paging), [31, 30])
        XCTAssertNil(paging.loadMore(), "the end the new page reported")
    }

    func testARepeatReloadOfAFeedThatDoesNotSupersedeIsDropped() {
        var paging = FeedPaging(supersedes: false)
        let first = paging.reload()!
        XCTAssertNil(paging.reload(), "a second pull re-fetches the same newest page")
        _ = paging.land(page([1], nextBefore: nil), for: first, visible: visible)
        XCTAssertEqual(ids(paging), [1])
    }

    // MARK: - Skipping ahead past ignored pages (lurker-ios#204)

    func testAPageThatFiltersToNothingPagesPastItself() {
        var paging = FeedPaging(supersedes: false)
        let first = paging.reload()!
        let landing = paging.land(page([30, 29], nick: "mallory", nextBefore: 29), for: first, visible: visible)
        XCTAssertEqual(landing?.next?.cursor, FeedCursor(beforeMessage: 29))
        XCTAssertEqual(paging.placeholder, .loading)
    }

    /// Answers `fetch` with a page holding one ignored line and a live cursor; the hop it asks
    /// for in return, if any.
    private func landIgnored(_ paging: inout FeedPaging, _ id: Int, for fetch: FeedPaging.Fetch) -> FeedPaging.Fetch? {
        paging.land(page([id], nick: "mallory", nextBefore: id), for: fetch, visible: visible)?.next
    }

    /// Answers every hop with an ignored page until the paging state stops asking; how many it
    /// asked for.
    private func hopsUntilItStops(_ paging: inout FeedPaging, from fetch: FeedPaging.Fetch, at id: Int) -> Int {
        var hops = 0
        var next = landIgnored(&paging, id, for: fetch)
        while let hop = next {
            hops += 1
            next = landIgnored(&paging, id - hops, for: hop)
        }
        return hops
    }

    /// Spends the whole budget on all-ignored pages and returns the paging state there.
    private func exhausted(supersedes: Bool) -> FeedPaging {
        var paging = FeedPaging(supersedes: supersedes)
        let first = paging.reload()!
        XCTAssertEqual(hopsUntilItStops(&paging, from: first, at: 1000), FeedPaging.maxFruitlessHops,
                       "the cap stops the runaway")
        XCTAssertEqual(paging.placeholder, .empty)
        return paging
    }

    func testAPullRestoresTheSkipAheadBudget() {
        var paging = exhausted(supersedes: false)
        let pull = paging.reload()!
        XCTAssertNotNil(landIgnored(&paging, 500, for: pull),
                        "a spent budget left the feed empty with rows a page away")
        XCTAssertEqual(paging.placeholder, .loading)
    }

    func testANewQuestionRestoresTheSkipAheadBudget() {
        var paging = exhausted(supersedes: true)
        let bar = paging.reload(newQuestion: true)!
        XCTAssertNotNil(landIgnored(&paging, 500, for: bar), "\"No matches\" while matches sat a page away")
    }

    /// A new question typed while the old one is mid-hop: the hop's answer is dropped, and the new
    /// question starts with the whole budget rather than what the old one left.
    func testANewQuestionDuringAHopSupersedesItWithAFreshBudget() {
        var paging = FeedPaging(supersedes: true)
        var fetch = paging.reload()!
        for id in stride(from: 999, through: 991, by: -1) {
            fetch = landIgnored(&paging, id, for: fetch)!
        }
        let bar = paging.reload(newQuestion: true)!
        XCTAssertNil(paging.land(page([1], nextBefore: nil), for: fetch, visible: visible))
        XCTAssertEqual(hopsUntilItStops(&paging, from: bar, at: 500), FeedPaging.maxFruitlessHops)
    }

    func testGainingRowsRestoresTheBudget() {
        var paging = FeedPaging(supersedes: false)
        var fetch = paging.reload()!
        for id in stride(from: 999, through: 991, by: -1) {
            fetch = landIgnored(&paging, id, for: fetch)!
        }
        _ = paging.land(page([990], nextBefore: 990), for: fetch, visible: visible)
        XCTAssertEqual(hopsUntilItStops(&paging, from: paging.loadMore()!, at: 500), FeedPaging.maxFruitlessHops)
        XCTAssertEqual(ids(paging), [990])
    }

    // MARK: - Page-ins, removals, abandoning

    func testAFailedPageInUnderRowsKeepsThemAndCanBeRetried() {
        var paging = loaded(supersedes: false)
        let more = paging.loadMore()!
        _ = paging.land(nil, for: more, visible: visible)
        XCTAssertEqual(paging.items.count, 10)
        XCTAssertNil(paging.placeholder)
        XCTAssertEqual(paging.loadMore()?.cursor, FeedCursor(beforeMessage: 21), "not latched at the end")
    }

    func testRemovingTheLastRowAfterAFailedPullIsEmptyNotAnError() {
        var paging = FeedPaging(supersedes: false)
        let first = paging.reload()!
        _ = paging.land(page([1], nextBefore: nil), for: first, visible: visible)
        let pull = paging.reload()!
        _ = paging.land(nil, for: pull, visible: visible)
        XCTAssertEqual(paging.remove(messageId: 1)?.rowsChanged, true)
        XCTAssertEqual(paging.placeholder, .empty)
        XCTAssertNil(paging.remove(messageId: 1), "already gone")
    }

    func testAnAbandonedFetchCannotLand() {
        var paging = FeedPaging(supersedes: true)
        let first = paging.reload()!
        paging.abandon()
        XCTAssertFalse(paging.isLoading)
        XCTAssertNil(paging.land(page([1], nextBefore: nil), for: first, visible: visible))
        XCTAssertEqual(paging.placeholder, .loading, "left alone: the user simply left")
        let again = paging.reload()!
        _ = paging.land(page([2], nextBefore: nil), for: again, visible: visible)
        XCTAssertEqual(ids(paging), [2])
    }
}

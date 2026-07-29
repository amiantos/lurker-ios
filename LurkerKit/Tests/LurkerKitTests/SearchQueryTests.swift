// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Locks the `from:`/`in:`/`on:` filter grammar against the web client's, which is the point
/// of porting it rather than inventing one: the same string is typed by the same person on
/// both clients, and a scope seeded here has to mean what it means there.
///
/// The first three cases are `vue_client/src/utils/searchQuery.test.ts` verbatim — including
/// the forgiving one, where a bare `from:` and an unknown `word:` stay in the free text. The
/// rest cover ground the web's suite doesn't state but its parser also has.
final class SearchQueryTests: XCTestCase {

    func testPeelsStructuredFiltersOffTheFreeText() {
        let query = SearchQuery.parse("from:alice in:#dev on:libera hello world")
        XCTAssertEqual(query.text, "hello world")
        XCTAssertEqual(query.from, ["alice"])
        XCTAssertEqual(query.target, "#dev")
        XCTAssertEqual(query.network, "libera")
    }

    func testCollectsMultipleFromIntoAnArray() {
        let query = SearchQuery.parse("from:eren from:nostimo from:twomoon needle")
        XCTAssertEqual(query.from, ["eren", "nostimo", "twomoon"])
        XCTAssertEqual(query.text, "needle")
    }

    func testBareAndUnknownPrefixesStayFreeText() {
        let query = SearchQuery.parse("from: word: just text")
        XCTAssertEqual(query.from, [])
        XCTAssertEqual(query.text, "from: word: just text")
    }

    func testKeysAreCaseInsensitiveButValuesArePreserved() {
        let query = SearchQuery.parse("FROM:Alice IN:#Dev ON:Libera")
        XCTAssertEqual(query.from, ["Alice"])
        XCTAssertEqual(query.target, "#Dev")
        XCTAssertEqual(query.network, "Libera")
    }

    /// `in:` and `on:` are single-valued, so the last one typed wins — a user correcting a
    /// mistyped channel shouldn't end up filtered to neither.
    func testLastInAndOnWin() {
        let query = SearchQuery.parse("in:#one in:#two on:a on:b")
        XCTAssertEqual(query.target, "#two")
        XCTAssertEqual(query.network, "b")
    }

    /// Split on the FIRST colon only, so a value containing one survives — `#c++` is fine
    /// either way, but a `time:` in the search text after a filter is the real case.
    func testValueMayContainAColon() {
        let query = SearchQuery.parse("in:#chan:extra rest")
        XCTAssertEqual(query.target, "#chan:extra")
        XCTAssertEqual(query.text, "rest")
    }

    func testWhitespaceIsCollapsedAndEmptyInputIsEmpty() {
        XCTAssertEqual(SearchQuery.parse("   a    b  ").text, "a b")
        XCTAssertTrue(SearchQuery.parse("   ").isEmpty)
        XCTAssertTrue(SearchQuery.parse("").isEmpty)
    }

    /// A filter with no free text is a legal search — "everything in this channel" is exactly
    /// what the scoped entry point opens with, before a word has been typed.
    func testFilterOnlyQueryIsNotEmpty() {
        XCTAssertFalse(SearchQuery.parse("in:#dev").isEmpty)
        XCTAssertFalse(SearchQuery.parse("from:alice").isEmpty)
        XCTAssertFalse(SearchQuery.parse("on:libera").isEmpty)
    }

    // MARK: - Dispatch floor

    /// A lone ASCII letter is both the most expensive thing to answer (`a` and `i` are among
    /// the commonest tokens in the index) and the least likely to be what anyone meant.
    func testSingleAsciiCharacterNeedsMoreText() {
        XCTAssertTrue(SearchQuery.parse("a").needsMoreText)
        XCTAssertTrue(SearchQuery.parse("I").needsMoreText)
        XCTAssertTrue(SearchQuery.parse("7").needsMoreText)
    }

    func testTwoCharactersIsEnough() {
        XCTAssertFalse(SearchQuery.parse("hi").needsMoreText)
        XCTAssertFalse(SearchQuery.parse("ok").needsMoreText)
        XCTAssertFalse(SearchQuery.parse("hello").needsMoreText)
    }

    /// The floor is on the FREE TEXT. A finished filter is a complete question that runs no
    /// full-text pass at all, so gating it would be charging for something that's nearly free.
    func testFilterOnlyQueryNeverNeedsMoreText() {
        XCTAssertFalse(SearchQuery.parse("in:#dev").needsMoreText)
        XCTAssertFalse(SearchQuery.parse("from:alice").needsMoreText)
        XCTAssertFalse(SearchQuery.parse("from:alice in:#dev on:libera").needsMoreText)
    }

    /// …but free text alongside a filter is still free text, and still has to clear the floor.
    func testShortTextWithAFilterStillNeedsMoreText() {
        XCTAssertTrue(SearchQuery.parse("in:#dev a").needsMoreText)
    }

    /// One CJK character is routinely a whole word, so the floor must not apply to it — a rule
    /// that counted characters blindly would lock those users out of searching for it.
    func testSingleNonAsciiCharacterIsEnough() {
        XCTAssertFalse(SearchQuery.parse("日").needsMoreText)
        XCTAssertFalse(SearchQuery.parse("б").needsMoreText)
    }

    /// An empty query isn't "too short" — it's `isEmpty`, which the caller answers with its
    /// landing view rather than a "keep typing" hint. Distinct states, distinct screens.
    func testEmptyQueryDoesNotNeedMoreText() {
        XCTAssertFalse(SearchQuery.parse("").needsMoreText)
        XCTAssertFalse(SearchQuery.parse("   ").needsMoreText)
    }

    // MARK: - Scope

    func testScopeSeedsInAndOnWithATrailingSpace() {
        let channel = Buffer(networkId: 1, target: "#dev", kind: .channel)
        XCTAssertEqual(SearchQuery.scope(for: channel, networkName: "libera"), "in:#dev on:libera ")
    }

    /// A round trip, since that's the actual contract: what `scope` writes, `parse` must read.
    func testScopeRoundTripsThroughParse() {
        let dm = Buffer(networkId: 1, target: "alice", kind: .dm)
        let seed = SearchQuery.scope(for: dm, networkName: "libera")
        let query = SearchQuery.parse(seed ?? "")
        XCTAssertEqual(query.target, "alice")
        XCTAssertEqual(query.network, "libera")
        XCTAssertEqual(query.text, "")
    }

    /// Tokens split on spaces, so a network name with one could not round-trip. Dropping `on:`
    /// leaves a scope that's slightly wider than asked for, which beats one that silently means
    /// something else.
    func testScopeDropsOnForANetworkNameWithWhitespace() {
        let channel = Buffer(networkId: 1, target: "#dev", kind: .channel)
        XCTAssertEqual(SearchQuery.scope(for: channel, networkName: "My Server"), "in:#dev ")
        XCTAssertEqual(SearchQuery.scope(for: channel, networkName: nil), "in:#dev ")
    }

    /// Neither is a conversation, so neither has a scope to search within.
    func testNoScopeForServerLogOrSystemBuffer() {
        let log = Buffer(networkId: 1, target: ":server:1", kind: .server)
        XCTAssertNil(SearchQuery.scope(for: log, networkName: "libera"))
        XCTAssertNil(SearchQuery.scope(for: Buffer.system, networkName: nil))
    }
}

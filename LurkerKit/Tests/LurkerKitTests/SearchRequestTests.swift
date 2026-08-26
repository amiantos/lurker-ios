// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// Building the `GET /api/search` URL (#123).
///
/// ⚠⚠ Every rule here fails silently when it is wrong: the server answers a mis-encoded query with
/// the wrong ROWS rather than with an error, and "these results look a bit off" is not something a
/// person can debug from the outside. That is the whole reason the URL is built somewhere testable
/// instead of inline in the fetch.
@Suite("Search request")
struct SearchRequestTests {

    private func url(_ raw: String, networkId: Int? = nil, before: Int? = nil, limit: Int = 50)
        -> String
    {
        SearchRequest.url(
            base: "https://lurker.test", query: SearchQuery.parse(raw), networkId: networkId,
            before: before, limit: limit
        )?.absoluteString ?? "<nil>"
    }

    @Test("a plain query carries just the text and the limit")
    func plainQuery() {
        #expect(url("hello") == "https://lurker.test/api/search?q=hello&limit=50")
    }

    @Test("a literal + survives, because the server reads a bare one as a space")
    func plusIsEncoded() {
        // ⚠⚠ The regression this whole file exists for. `URLComponents` leaves `+` alone (it is
        // legal in a query), the server parses with form-urlencoded semantics where `+` MEANS
        // SPACE, and so a search for `C++` silently became a search for `C  `. The WS verb could
        // not get this wrong — JSON carries a `+` literally — so it is new with the migration.
        #expect(url("C++") == "https://lurker.test/api/search?q=C%2B%2B&limit=50")
        // ...and a real space is still a space, which is what makes the blanket replace safe:
        // URLComponents encodes it as %20 and never as +.
        #expect(url("a b") == "https://lurker.test/api/search?q=a%20b&limit=50")
    }

    @Test("a channel target is encoded, so the # cannot start a fragment")
    func channelTargetIsEncoded() {
        #expect(url("in:#dev hi") == "https://lurker.test/api/search?q=hi&target=%23dev&limit=50")
    }

    @Test("every channel sigil survives, not just #")
    func allSigilsSurvive() {
        // ⚠⚠ `&chan` is the one that bites: unencoded it would end the parameter and invent a new
        // one. The other three are ordinary characters here, but a channel is `#&+!` and testing
        // only `#` is how that gets forgotten.
        #expect(url("in:&chan").contains("target=%26chan"))
        #expect(url("in:+chan").contains("target=%2Bchan"))
        #expect(url("in:!chan").contains("target=!chan"))
    }

    @Test("from: repeats the parameter, because that is how the route OR-matches")
    func nicksRepeat() {
        let out = url("from:bob from:alice hi")
        #expect(out.contains("nick=bob"))
        #expect(out.contains("nick=alice"))
        // ⚠ Not comma-joined — the route would read that as one nick containing a comma.
        #expect(!out.contains("nick=bob,alice"))
    }

    @Test("an unused filter is absent, never empty")
    func unusedFiltersAreOmitted() {
        // ⚠⚠ The server reads an absent key as unfiltered and an EMPTY one as a filter matching
        // nothing, so `q=` would return no rows for every search. Inherited from the WS verb,
        // where the same rule applied to the JSON keys.
        let out = url("in:#dev")
        #expect(!out.contains("q="))
        #expect(!out.contains("nick="))
        #expect(out.contains("target=%23dev"))
    }

    @Test("the cursor and the network scope ride along when present")
    func cursorAndScope() {
        let out = url("hi", networkId: 3, before: 412)
        #expect(out.contains("networkId=3"))
        #expect(out.contains("before=412"))
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// Building the `GET /api/uploads` URL, and the paging rules that go with it (#138).
///
/// ⚠⚠ Same reason `SearchRequestTests` exists: every rule here fails SILENTLY. The route answers a
/// mis-encoded filename with the wrong rows rather than an error, and a grid of thumbnails gives a
/// person nothing to notice that from.
@Suite("Uploads request")
struct UploadsRequestTests {

    private func url(
        _ filter: UploadsFilter = UploadsFilter(),
        before: Int? = nil,
        limit: Int? = nil
    ) -> String {
        UploadsRequest.url(
            base: "https://lurker.test",
            filter: filter,
            before: before,
            limit: limit ?? UploadsRequest.limit(for: filter)
        )?.absoluteString ?? "<nil>"
    }

    @Test("an unfiltered browse asks for nothing but a limit")
    func unfiltered() {
        // ⚠ No `q=`, no `kind=`, no `favorites=`. An empty `q` is not "unfiltered" to the route —
        // it is a filename search for the empty string.
        #expect(url() == "https://lurker.test/api/uploads?limit=50")
    }

    @Test("a literal + survives, because the server reads a bare one as a space")
    func plusIsEncoded() {
        // ⚠⚠ The trap `SearchRequest` documents, and filenames are where it actually bites:
        // `C++.png` and `notes+drafts.txt` are names people really have. `URLComponents` leaves
        // `+` alone (legal in a query); the route parses with form-urlencoded semantics where
        // `+` MEANS SPACE, so the search quietly answers a different question and finds nothing.
        #expect(url(UploadsFilter(query: "C++.png")).contains("q=C%2B%2B.png"))
        // ...and a real space is still a space, which is what makes the blanket replace safe:
        // URLComponents encodes it as %20 and never as +.
        #expect(url(UploadsFilter(query: "screen shot")).contains("q=screen%20shot"))
    }

    @Test("a filename's other punctuation is encoded too")
    func punctuationIsEncoded() {
        // `&` would end the parameter and invent a new one; `#` would start a fragment and take
        // the rest of the query with it.
        #expect(url(UploadsFilter(query: "a&b#c")).contains("q=a%26b%23c"))
    }

    @Test("starred composes with a kind rather than replacing it")
    func starredComposesWithKind() {
        // ⚠⚠ The rule the whole filter UI is shaped around: "my starred gifs" is one request, not
        // a choice between two views.
        let both = url(UploadsFilter(kind: .image, favoritesOnly: true))
        #expect(both.contains("kind=image"))
        #expect(both.contains("favorites=1"))
    }

    @Test("the starred view asks for the whole set, not a page")
    func starredAsksForTheCeiling() {
        #expect(UploadsRequest.limit(for: UploadsFilter(favoritesOnly: true)) == 200)
        #expect(UploadsRequest.limit(for: UploadsFilter()) == 50)
    }

    @Test("a cursor is dropped for the starred view, and carried for every other")
    func cursorIsDroppedForStarred() {
        // ⚠⚠ The server orders the starred view by when each row was STARRED, so an id cursor
        // against that ordering pages the wrong rows — the route ignores `before` for exactly
        // that reason, and sending one would encode a paging model this view does not have.
        #expect(!url(UploadsFilter(favoritesOnly: true), before: 90).contains("before"))
        #expect(url(before: 90).contains("before=90"))
    }

    @Test("a full page means there is more; the starred view never has more")
    func hasMore() {
        let plain = UploadsFilter()
        #expect(UploadsRequest.hasMore(filter: plain, received: 50, limit: 50))
        #expect(!UploadsRequest.hasMore(filter: plain, received: 49, limit: 50))
        // ⚠ Even at a full 200 rows: there is no cursor that can page this view, so "more" would
        // be a promise nothing can keep. It is disclosed as truncation instead.
        let starred = UploadsFilter(favoritesOnly: true)
        #expect(!UploadsRequest.hasMore(filter: starred, received: 200, limit: 200))
        #expect(UploadsRequest.isTruncated(filter: starred, received: 200))
        #expect(!UploadsRequest.isTruncated(filter: starred, received: 199))
        // ...and an ordinary full page is not "truncated" — it just has a next page.
        #expect(!UploadsRequest.isTruncated(filter: plain, received: 50))
    }

    @Test("a 404 is a failure here, never an empty page")
    func unpredictedStatusIsAFailure() {
        // ⚠ Unlike search, which reads a SCOPED 404 as "that network holds nothing of yours".
        // This route takes no such parameter, so nothing can be legitimately unknown and the only
        // honest reading of a 404 is that we failed to ask. Saying "no uploads" instead would be
        // unfalsifiable from the outside, where an error at least offers a retry.
        #expect(UploadsRequest.outcome(status: 404) == .failed)
        #expect(UploadsRequest.outcome(status: 401) == .unauthorized)
        #expect(UploadsRequest.outcome(status: 200) == .page)
        #expect(UploadsRequest.outcome(status: 500) == .failed)
    }

    @Test("the scope is a noun phrase, so it survives being dropped into a sentence")
    func scopeIsANounPhrase() {
        // ⚠⚠ The regression this exists for: built as a bare list of what was set, a starred-only
        // filter described itself as "starred", and the empty state read "Nothing in your uploads
        // matches starred." — which is not a sentence. Every one of these has to end in the head
        // noun with the narrowings in front of it.
        #expect(UploadsFilter(favoritesOnly: true).scope == "starred uploads")
        #expect(UploadsFilter(kind: .image).scope == "image uploads")
        #expect(UploadsFilter(kind: .image, favoritesOnly: true).scope == "starred image uploads")
        #expect(UploadsFilter().scope == "uploads")
        // ⚠ The RAW name, not the chip label: the labels are plural where the grammar wants a
        // modifier, and "No videos uploads" is the other way to get this wrong.
        #expect(UploadsFilter(kind: .video).scope == "video uploads")
    }

    @Test("the no-matches line names what was searched as well as what for")
    func noMatchesLineReadsAsASentence() {
        #expect(
            UploadsFilter(query: "march", kind: .video, favoritesOnly: true).noMatchesLine
                == "No starred video uploads match “march”.")
        #expect(UploadsFilter(query: "march").noMatchesLine == "No uploads match “march”.")
    }

    @Test("a filter with nothing set is not narrowed")
    func narrowing() {
        #expect(!UploadsFilter().isNarrowed)
        #expect(UploadsFilter(favoritesOnly: true).isNarrowed)
        #expect(UploadsFilter(kind: .text).isNarrowed)
        #expect(UploadsFilter(query: "a").isNarrowed)
    }
}

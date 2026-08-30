// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// What the uploads browser is currently narrowed to (#138).
///
/// ⚠⚠ `favoritesOnly` **composes with** `kind` rather than replacing it — "my starred gifs" is a
/// view somebody actually wants, so it is its own flag and not a fifth kind. That is why the UI
/// puts it beside the kind choices rather than among them: a row of mutually-exclusive options
/// with one member that isn't would be lying about what tapping it does.
public struct UploadsFilter: Sendable, Equatable {
    /// Filename search. Server-side by necessity, not by preference: this client only holds the
    /// pages it has scrolled through, and the entire point of the search is finding one it
    /// hasn't. The house rule is that a filter is a render-time thing over what the client
    /// already holds; this is the documented exception, and the reason is delivery, not taste.
    public var query: String
    public var kind: UploadKind?
    public var favoritesOnly: Bool

    public init(query: String = "", kind: UploadKind? = nil, favoritesOnly: Bool = false) {
        self.query = query
        self.kind = kind
        self.favoritesOnly = favoritesOnly
    }

    /// Is this narrowed at all? Decides whether an empty list says "nothing matches" or "you
    /// haven't uploaded anything".
    public var isNarrowed: Bool { !query.isEmpty || kind != nil || favoritesOnly }

    /// What this filter is narrowed to, as a NOUN PHRASE — `uploads`, `starred uploads`,
    /// `image uploads`, `starred video uploads`.
    ///
    /// ⚠⚠ Always ends in the head noun, and the narrowings are adjectives in front of it. Built as
    /// a bare list of what was set, it produced "Nothing in your uploads matches starred." — which
    /// is not a sentence. Anything that gets dropped into running prose has to be a phrase that
    /// can survive being dropped into running prose, and the empty state is the one place a
    /// reader meets these words at all.
    ///
    /// ⚠ The kind contributes its raw name (`video`) rather than its chip label (`Video`), because
    /// the labels are plural where the grammar wants a modifier: "No videos uploads" is the other
    /// way to get this wrong.
    ///
    /// ⚠ `starred` must be named as well as the kind. "No image uploads match" sent the reader
    /// hunting for the wrong thing when the empty view was really the starred one.
    public var scope: String {
        let narrowings = [favoritesOnly ? "starred" : nil, kind?.rawValue].compactMap { $0 }
        return (narrowings + ["uploads"]).joined(separator: " ")
    }

    /// The line under an empty grid when a search found nothing — `No starred image uploads match
    /// “march”.` Only for the case where something was actually typed; a filter with no query has
    /// nothing to report *not matching*, and reads as "you have none of these" instead.
    public var noMatchesLine: String {
        "No \(scope) match “\(query)”."
    }
}

/// The URL for one page of `GET /api/uploads`, and the two paging rules that go with it.
///
/// Split out from the fetch for the same reason `SearchRequest` is: every rule here fails
/// SILENTLY when it is wrong. A mis-encoded filename returns the wrong rows rather than an error,
/// and a browse that quietly answers a different question than the one asked is close to
/// impossible to notice from a grid of thumbnails.
public enum UploadsRequest {

    /// How many rows a scrolled page asks for.
    public static let pageSize = 50

    /// How many the starred view asks for in its single request.
    ///
    /// ⚠ Mirrors the server's own ceiling. Hitting it is DISCLOSED rather than silently
    /// truncated — a list that stops at 200 with nothing said reads as "these are all of them",
    /// which would be a lie. See `isTruncated`.
    public static let favoritesLimit = 200

    /// The limit this filter's first request should carry.
    public static func limit(for filter: UploadsFilter) -> Int {
        filter.favoritesOnly ? favoritesLimit : pageSize
    }

    /// `nil` when the base URL will not parse, which is the caller's cue to give up.
    ///
    /// ⚠⚠ Only what the user actually filtered on goes on the wire. `q=` with an empty value is
    /// not "unfiltered" — it is a filename search for the empty string, and the route reads the
    /// two differently.
    ///
    /// ⚠⚠ `before` is DROPPED for the starred view. The server orders that view by when each row
    /// was starred, and an id cursor against that ordering pages the wrong rows — so the route
    /// ignores the parameter, and sending one anyway would encode a paging model this view does
    /// not have. It comes back whole instead; see `favoritesLimit`.
    public static func url(
        base: String,
        filter: UploadsFilter,
        before: Int?,
        limit: Int
    ) -> URL? {
        guard var components = URLComponents(string: base + "/api/uploads") else { return nil }
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let before, !filter.favoritesOnly {
            items.append(URLQueryItem(name: "before", value: String(before)))
        }
        if !filter.query.isEmpty { items.append(URLQueryItem(name: "q", value: filter.query)) }
        if let kind = filter.kind { items.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
        if filter.favoritesOnly { items.append(URLQueryItem(name: "favorites", value: "1")) }
        components.queryItems = items

        // ⚠⚠ `+` has to be percent-encoded BY HAND, exactly as in `SearchRequest`, and a filename
        // search is where it bites hardest: `C++.png` and `notes+drafts.txt` are ordinary names.
        // `URLComponents` leaves a literal `+` alone (it is legal in a query), but the server
        // parses query strings with form-urlencoded semantics, where `+` MEANS SPACE — so the
        // search quietly answers a different question and returns nothing.
        //
        // ⚠ Safe as a blanket replacement because `URLComponents` encodes a space as `%20` and
        // never as `+`, so every `+` left in the output is one the user typed.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// Is there another page behind this one?
    ///
    /// A full page means "ask again" and a short one means "that's everything" — the route has no
    /// `nextBefore` to say so itself. The starred view is the exception in both directions: it
    /// arrives whole, so there is never a next page to fetch even when it came back full.
    public static func hasMore(filter: UploadsFilter, received: Int, limit: Int) -> Bool {
        !filter.favoritesOnly && received >= limit
    }

    /// The starred view came back at the ceiling, so there may be more the server didn't send.
    public static func isTruncated(filter: UploadsFilter, received: Int) -> Bool {
        filter.favoritesOnly && received >= favoritesLimit
    }

    /// What a response status means for a list request.
    ///
    /// ⚠ Deliberately has no "that's an empty page" case, unlike `SearchRequest.outcome`. That
    /// one exists because the search route answers 404 for exactly one thing (an unowned
    /// network); this route takes no such parameter, so a 404 here is a response nobody
    /// predicted and the only honest reading of one is that we failed to ask.
    public enum Outcome: Equatable {
        case page
        case unauthorized
        case failed
    }

    public static func outcome(status: Int) -> Outcome {
        switch status {
        case 200..<300: .page
        case 401: .unauthorized
        default: .failed
        }
    }
}

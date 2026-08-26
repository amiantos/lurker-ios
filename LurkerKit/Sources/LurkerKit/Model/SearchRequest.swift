// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The URL for one page of `GET /api/search` (#123).
///
/// Split out from the fetch so it can be tested: the mapping is small but every one of its rules
/// fails SILENTLY when it is wrong — a mis-encoded parameter returns the wrong rows rather than an
/// error, and a search that quietly answers a different question than the one typed is close to
/// impossible to notice from the results.
public enum SearchRequest {

    /// `nil` when the base URL will not parse, which is the caller's cue to give up.
    ///
    /// ⚠⚠ Only what the user actually filtered on goes on the wire. The server reads an absent key
    /// as unfiltered and an empty string as a filter matching nothing, so sending `q=` for an
    /// unused filter returns no rows for every search. This is inherited from the WS verb, where
    /// the same rule applied to the JSON keys.
    public static func url(
        base: String,
        query: SearchQuery,
        networkId: Int?,
        before: Int?,
        limit: Int
    ) -> URL? {
        guard var components = URLComponents(string: base + "/api/search") else { return nil }
        var items: [URLQueryItem] = []
        if !query.text.isEmpty { items.append(URLQueryItem(name: "q", value: query.text)) }
        // ⚠ Repeated, not comma-joined: `nick=a&nick=b` is how the route OR-matches a friend's
        // alts, and it is the one field of the WS verb (`nicks: [a, b]`) that did not map to a
        // single param. A comma-joined value would be read as one nick containing a comma.
        for nick in query.from { items.append(URLQueryItem(name: "nick", value: nick)) }
        if !query.target.isEmpty { items.append(URLQueryItem(name: "target", value: query.target)) }
        if let networkId { items.append(URLQueryItem(name: "networkId", value: String(networkId))) }
        if let before { items.append(URLQueryItem(name: "before", value: String(before))) }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        components.queryItems = items

        // ⚠⚠ `+` has to be percent-encoded BY HAND, and this is the one thing about moving search
        // onto a URL that the WS verb could not get wrong. `URLComponents` leaves a literal `+`
        // alone — it is legal in a query — but the server parses query strings with
        // form-urlencoded semantics, where `+` MEANS SPACE. So `C++` arrives as `C  ` and the
        // search quietly answers a different question. JSON over the socket had no such reading.
        //
        // ⚠ Safe as a blanket replacement because `URLComponents` encodes a space as `%20` and
        // never as `+`, so every `+` left in the output is one the user typed. Everything else it
        // already handles: `#dev` → `%23dev`, `&` → `%26`.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// What a response status means for a search.
    public enum Outcome: Equatable {
        /// Read the body as a page of matches.
        case page
        /// A question that was answered, with nothing in it. Distinct from `failed`: the caller
        /// says "no matches" rather than putting an error and a retry in front of the user.
        case emptyPage
        /// The session is gone.
        case unauthorized
        /// We could not ask, or could not read the answer. NEVER rendered as "no matches".
        case failed
    }

    /// ⚠⚠ `scoped` — whether the request carried a `networkId` — is what makes a 404 readable, and
    /// getting this wrong turns search into a silent lie rather than an error.
    ///
    /// The route answers 404 for an unowned or unknown network, and for THAT a 404 is the empty
    /// page: the user narrowed to a network holding nothing of theirs, and "no matches" is the
    /// honest answer. But this client only ever sends an id it resolved from its own roster, so
    /// that case is nearly unreachable — while the reachable 404 is a server with no
    /// `/api/search` at all, which is every self-hosted instance older than lurker#676. Reading
    /// that as an empty page means every query on such a server answers "No matches" forever,
    /// with no error and nothing to retry. Nothing in this client gates on a server version, so
    /// the status code is the only signal there is.
    public static func outcome(status: Int, scoped: Bool) -> Outcome {
        switch status {
        case 200..<300: .page
        case 401: .unauthorized
        case 404: scoped ? .emptyPage : .failed
        default: .failed
        }
    }
}

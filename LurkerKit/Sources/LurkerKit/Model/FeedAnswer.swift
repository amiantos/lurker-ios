// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// What came back for one page of a cross-buffer feed: search, highlights, activity.
///
/// Three answers rather than a page-or-nil because one failure is not like the others. Since
/// lurker 2.7.0 these reads run in the server's search process, one statement at a time and
/// against a time limit, and each can answer `503 {error}`: the search took too long, too many
/// are waiting, or a newer one of ours displaced it (lurker#1308). That is "try again", said
/// in the server's words — not a dropped connection, a lost session, or a body we couldn't read.
public enum FeedAnswer: Equatable, Sendable {
    case page(HighlightsPage)
    /// `503`: the server could not answer this one just now. `reason` is its own `error` text,
    /// nil when the body carried none.
    case unavailable(reason: String?)
    /// We could not ask, or could not read the answer. A 401 has already bounced the session.
    case failed

    public init(_ page: HighlightsPage?) {
        self = page.map(FeedAnswer.page) ?? .failed
    }

    public var page: HighlightsPage? {
        if case .page(let page) = self { return page }
        return nil
    }

    /// Why there is no page, when the server said: a 503's reason. Nil for a page, for a plain
    /// failure, and for a 503 that gave no reason.
    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// The answer a `503` body gives. The body is `{error}`; anything else — an empty body, a
    /// proxy's HTML page — is still "try again", with nothing of the server's to quote.
    public static func unavailable(body: Data) -> FeedAnswer {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let text = (object?["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bounded: it is shown under the list, and a body is whatever the far end sent.
        guard let text, !text.isEmpty, text.count <= maxReasonLength else { return .unavailable(reason: nil) }
        return .unavailable(reason: text)
    }

    static let maxReasonLength = 200
}

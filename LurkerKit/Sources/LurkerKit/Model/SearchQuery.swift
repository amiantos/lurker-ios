// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// The inline message-search grammar, shared with the web client:
///
///     from:nick in:#channel on:network free text…
///
/// `from:` / `in:` / `on:` are peeled off as structured filters and everything else is joined
/// back up as the free-text query. Deliberately a *parser over one text field* rather than a
/// row of filter chips: the same string round-trips between the two clients, a scoped entry
/// point can seed it by prefixing `in:#chan on:net `, and the whole grammar stays legible in
/// the field the user is already typing in.
///
/// Port of `vue_client/src/utils/searchQuery.ts`, including its two forgiving cases: a bare
/// prefix (`from:`) and an unknown one (`word:`) are left in the free text, where the server's
/// FTS layer handles them harmlessly. Getting that wrong would swallow a real search term.
public struct SearchQuery: Equatable, Sendable {
    /// Everything that wasn't a filter, re-joined with single spaces. Empty when the user
    /// typed only filters — which is a legal search (`in:#dev` alone means "that buffer").
    public let text: String

    /// The `from:` nicks. Repeatable, and OR-matched by the server — a friend's alts, or the
    /// Friends screen's "view activity". Every other filter is last-wins, matching the web.
    public let from: [String]

    /// `in:` — a buffer target (channel name or peer nick). Empty when unfiltered.
    public let target: String

    /// `on:` — a *network name*, which the client resolves against its own roster to the
    /// network id the server wants. Empty when unfiltered.
    public let network: String

    /// Nothing to search on: no free text and no filter. The server would have nothing to
    /// match, so the caller shows its "type to search" prompt rather than dispatching.
    public var isEmpty: Bool {
        text.isEmpty && from.isEmpty && target.isEmpty && network.isEmpty
    }

    /// Typed, but not yet enough to be worth asking the server — the state a search-as-you-type
    /// field passes through on the way to a real query.
    ///
    /// **A search is the most expensive thing a client can ask this server for.** The FTS query
    /// runs synchronously on the event loop that also services every IRC connection on the
    /// instance, so the cheapest thing to type must not be the most expensive thing to answer —
    /// and a lone `a` or `i` is exactly that, being among the most common tokens in the index.
    ///
    /// **The floor is on the free text, not on what's typed.** `in:#dev` is a complete question
    /// the moment it's finished: it runs no full-text pass at all, only an indexed filter, so
    /// demanding extra characters would gate a query that costs almost nothing.
    ///
    /// **And only for text that's entirely ASCII.** One CJK character is routinely a whole
    /// word; a floor that couldn't tell it from a lone Latin letter would lock those users out
    /// of searching for it.
    public var needsMoreText: Bool {
        !text.isEmpty && text.count < Self.minimumFreeText && text.allSatisfy(\.isASCII)
    }

    /// Two, not three: it rules out the single-character case that is both the most expensive
    /// to answer and the least likely to be meant, without blocking the two-letter words people
    /// genuinely search for ("hi", "ok", "wg").
    private static let minimumFreeText = 2

    public init(text: String, from: [String], target: String, network: String) {
        self.text = text
        self.from = from
        self.target = target
        self.network = network
    }

    public static func parse(_ raw: String) -> SearchQuery {
        var from: [String] = []
        var target = ""
        var network = ""
        var free: [String] = []
        for token in raw.split(whereSeparator: \.isWhitespace) {
            // Split once, so a value may itself contain a colon (`in:#c++`, a nick with one).
            guard let colon = token.firstIndex(of: ":") else {
                free.append(String(token))
                continue
            }
            let key = token[token.startIndex..<colon].lowercased()
            let value = String(token[token.index(after: colon)...])
            // A bare prefix carries no filter, so it stays free text rather than setting an
            // empty one — an empty `in:` would otherwise read as "filter to the buffer named
            // ''" and match nothing.
            guard !value.isEmpty else {
                free.append(String(token))
                continue
            }
            switch key {
            case "from": from.append(value)
            case "in": target = value
            case "on": network = value
            default: free.append(String(token))
            }
        }
        return SearchQuery(text: free.joined(separator: " "), from: from, target: target, network: network)
    }

    /// The `in:`/`on:` prefix that scopes a search to `buffer`, with a trailing space so the
    /// user's first keystroke adds a term instead of editing the scope. Nil for a buffer with
    /// no meaningful scope — the system buffer and a `:server:` log aren't conversations, and
    /// the web's scoped entry points leave both unscoped for the same reason.
    ///
    /// `on:` is dropped when the network's name contains whitespace: tokens split on spaces,
    /// so it could not round-trip through `parse`. `in:` alone still scopes by target, which
    /// is the part that matters — a channel name colliding across two networks is rare, and a
    /// few extra rows beats a filter that silently means something else.
    public static func scope(for buffer: Buffer, networkName: String?) -> String? {
        guard buffer.kind == .channel || buffer.kind == .dm, !buffer.target.isEmpty else { return nil }
        let on = networkName.flatMap { name in
            !name.isEmpty && !name.contains(where: \.isWhitespace) ? " on:\(name)" : nil
        } ?? ""
        return "in:\(buffer.target)\(on) "
    }
}

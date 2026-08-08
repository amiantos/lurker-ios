// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Argument parsing for `/relay` (#277) — mark, unmark, and list relay/bridge bots on the active
/// network. A marked bot's messages get re-attributed to the speaker embedded in its envelope
/// (`[Discord] <alice> hi` → alice); see `RelayEnvelope`.
///
/// Ported from the web's `vue_client/src/lib/commands/relay.ts`, and split out of `CommandParser`
/// for the same reason `IgnoreArgs` is: the interesting part is the tokenizing, and it's testable
/// on its own.
///
/// ⚠ The custom-pattern argument is the **raw remainder of the line** — a template like
/// `<{nick}> {message}`, whose spaces are significant. So tokens are peeled by hand rather than
/// run through `IgnoreArgs.tokenize`, which would split and de-quote the template into something
/// that no longer matches anything.
public enum RelayArgs {

    /// What a `/relay` line turned out to be.
    public enum Parsed: Equatable, Sendable {
        case list
        case add(nick: String, pattern: String)
        case remove(nick: String)
        /// Unusable input, with the line to print. Never reaches the wire.
        case failure(message: String)
    }

    private static let addVerbs: Set<String> = ["add", "mark", "set"]
    private static let removeVerbs: Set<String> = ["remove", "rm", "del", "delete", "unmark"]

    static let usage = "usage: /relay [list] · /relay add <nick> [pattern] · /relay remove <nick>"

    public static func parse(_ argLine: String) -> Parsed {
        // `whitespacesAndNewlines`, not `whitespaces`: the composer is multi-line and Return
        // inserts a newline, so `/relay\n` arrives here with one still attached — and an argLine
        // that is only a newline would otherwise miss the listing and be read as a subcommand.
        let trimmed = argLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .list }

        let (sub, rest) = peel(trimmed)
        let verb = sub.lowercased()

        if verb == "list" || verb == "ls" { return .list }

        if addVerbs.contains(verb) {
            let (nick, pattern) = peel(rest)
            guard !nick.isEmpty else { return .failure(message: "usage: /relay add <nick> [pattern]") }
            return .add(
                nick: nick,
                pattern: unquote(pattern.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }

        if removeVerbs.contains(verb) {
            let (nick, _) = peel(rest)
            guard !nick.isEmpty else { return .failure(message: "usage: /relay remove <nick>") }
            return .remove(nick: nick)
        }

        return .failure(message: "unknown subcommand \"\(sub)\". \(usage)")
    }

    /// Split off the first whitespace-delimited token, returning it and the remainder. The
    /// remainder keeps its interior spacing — only the gap after the token is consumed — so a
    /// custom template survives intact.
    private static func peel(_ s: String) -> (String, String) {
        let start = s.drop { $0.isWhitespace }
        let token = start.prefix { !$0.isWhitespace }
        let rest = start.dropFirst(token.count).drop { $0.isWhitespace }
        return (String(token), String(rest))
    }

    /// Drop one matching pair of surrounding quotes, if present — a convenience so
    /// `/relay add bot "[{s}] <{n}> {m}"` works even though quoting isn't required here.
    ///
    /// ⚠ "Starts and ends with the same quote" is not the same test as "is one quoted run", and
    /// taking the first for the second peels a pair that was never a pair: `"{nick}" said
    /// "{message}"` would become `{nick}" said "{message}`, which still compiles — both required
    /// placeholders survive — so it would be stored and marked with a cheerful receipt while
    /// matching something the user never wrote. Requiring the interior to be quote-free is what
    /// makes the convenience refuse to guess: the template is then left exactly as typed, quotes
    /// and all, which is at least visible in `/relay list`.
    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let quote = s.first, quote == "\"" || quote == "'",
              s.last == quote, !s.dropFirst().dropLast().contains(quote)
        else { return s }
        return String(s.dropFirst().dropLast())
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The `/ignore` command line, parsed — a port of `shared/parseIgnore.ts` (lurker #301, #350),
/// which is irssi's grammar:
///
///     /ignore [-regexp|-full] [-pattern <text>] [-except] [-time <dur>] [-network]
///             [<mask>|<#channel>] [LEVELS...]
///
/// Pure, and with no clock beyond the injected `now`, so the whole grammar is testable without
/// a socket or a wall clock — the same shape the matcher ported in (`IgnoreMatch`). The server
/// re-validates everything this produces (`parseIgnoreInput` → `ignoreRulesService.add`), so a
/// rule that gets past here can still be refused; what this buys is that the common mistakes —
/// a typo'd flag, a duration that isn't one — are answered in the buffer the user typed in
/// rather than by silence.
public enum IgnoreArgs {

    /// A command line that named a rule, plus the one thing about it that isn't the rule.
    public struct Parsed: Equatable, Sendable {
        /// The rule to send. Its `id` is 0 — identity is the server's to assign.
        public let rule: IgnoreRule
        /// Whether `-network` scoped it to the issuing connection. False — global, every
        /// network — is the default, and the opposite of what irssi does (#350). The rule
        /// payload itself is scope-agnostic; the caller maps this to a `networkId`.
        public let scopeNetwork: Bool
    }

    /// Why a command line named no rule. Carries the same wording as the web's parser, since
    /// it's printed straight back to the user.
    public struct Failure: Error, Equatable, Sendable {
        public let message: String
    }

    // MARK: - Durations

    private static let multipliers: [String: Double] = [
        "ms": 1,
        "s": 1000, "sec": 1000, "secs": 1000,
        "m": 60_000, "min": 60_000, "mins": 60_000,
        "h": 3_600_000, "hr": 3_600_000, "hrs": 3_600_000, "hour": 3_600_000, "hours": 3_600_000,
        "d": 86_400_000, "day": 86_400_000, "days": 86_400_000,
        "w": 604_800_000, "week": 604_800_000, "weeks": 604_800_000,
    ]

    /// ~100 years. Past this, `now + duration` leaves the range a `Date` can carry to the
    /// server as an ISO string, and a value that large is a typo rather than an intent — so it
    /// fails rather than being silently capped. A permanent ignore is `-time` omitted.
    private static let maxDurationMillis: Double = 100 * 365 * 24 * 60 * 60 * 1000

    /// `"7 days"`, `"30m"`, `"300"` → milliseconds; nil if it isn't a duration.
    ///
    /// Hand-rolled rather than regex'd, because the reference's `\d` is ASCII-only and ICU's
    /// is not: `٧days` would parse here and not there. Held in a `Double` for the same reason
    /// the reference holds a JS number — a 20-digit count of days has to be *rejected*, and an
    /// `Int` would have overflowed to nil before the range check could say so.
    static func duration(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let count = Double(digits) else { return nil }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        guard let multiplier = multipliers[unit.isEmpty ? "s" : unit] else { return nil }
        let millis = count * multiplier
        guard millis.isFinite, millis <= maxDurationMillis else { return nil }
        return millis
    }

    // MARK: - Tokenizer

    /// Split on whitespace, but keep a balanced `(…)` group or a `"quoted"` string whole, so
    /// `-pattern (a|b c)` and `-pattern "two words"` survive as one token each.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }
            let first = characters[index]
            if first == "\"" || first == "'" {
                index += 1
                var buffer = ""
                while index < characters.count, characters[index] != first {
                    buffer.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 } // closing quote
                tokens.append(buffer)
            } else if first == "(" {
                // Depth-counted, so a nested group closes at the right paren. An unbalanced
                // one runs to the end of the line — the same shape it has on the web, and the
                // regex it becomes will fail to compile there too.
                var depth = 0
                var buffer = ""
                while index < characters.count {
                    let character = characters[index]
                    if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
                    buffer.append(character)
                    index += 1
                    if depth == 0 { break }
                }
                tokens.append(buffer)
            } else {
                var buffer = ""
                while index < characters.count, !characters[index].isWhitespace {
                    buffer.append(characters[index])
                    index += 1
                }
                tokens.append(buffer)
            }
        }
        return tokens
    }

    private static func isChannelToken(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        return first == "#" || first == "&" || first == "!" || first == "+"
    }

    // MARK: - Parse

    /// Parse the arguments of an `/ignore` line (everything after the verb).
    ///
    /// `now` is injected rather than read here so `-time` is testable, and so the expiry a
    /// command computes is the same instant the rest of the line was parsed at.
    public static func parse(_ argLine: String, now: Date = Date()) -> Result<Parsed, Failure> {
        func fail(_ message: String) -> Result<Parsed, Failure> {
            .failure(Failure(message: message))
        }

        var mask: String?
        var channels: [String] = []
        var pattern: String?
        var expiresAt: Date?
        var isExcept = false
        var scopeNetwork = false
        var sawRegexp = false
        var sawFull = false
        var addLevels: [String] = []
        var subLevels: [String] = []

        let tokens = tokenize(argLine.trimmingCharacters(in: .whitespaces))
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            let lower = token.lowercased()

            switch lower {
            case "-regexp", "-regex":
                sawRegexp = true
                continue
            case "-full", "-word":
                sawFull = true
                continue
            case "-except":
                isExcept = true
                continue
            // Scope flags (#350): global is the default, `-network` opts into the current
            // connection, and `-global` is the explicit opposite — a no-op that exists so the
            // default is discoverable from the command line rather than only from docs.
            case "-network", "-net":
                scopeNetwork = true
                continue
            case "-global":
                scopeNetwork = false
                continue
            case "-replies":
                return fail("-replies is not supported")
            case "-pattern":
                guard index < tokens.count else { return fail("-pattern needs a value") }
                pattern = tokens[index]
                index += 1
                continue
            case "-time":
                let value = index < tokens.count ? tokens[index] : nil
                index += 1
                guard let millis = duration(value) else {
                    return fail("invalid -time value: \(value ?? "(missing)")")
                }
                expiresAt = Date(timeInterval: millis / 1000, since: now)
                continue
            default:
                break
            }

            // A subtractive level — `ALL -PUBLIC`. Only a known level token qualifies;
            // anything else beginning with `-` is a flag nobody implements, and saying so
            // beats silently reading `-regex` (a typo of `-regexp`) as a mask.
            if token.hasPrefix("-"), token.count > 1 {
                guard let level = IgnoreLevels.canonical(String(token.dropFirst())) else {
                    return fail("unknown flag: \(token)")
                }
                subLevels.append(level)
                continue
            }

            if isChannelToken(token) {
                channels.append(token.lowercased())
                continue
            }

            if let level = IgnoreLevels.canonical(token) {
                addLevels.append(level)
                continue
            }

            if mask == nil {
                // `*` is "anyone", which the matcher spells as no mask at all.
                mask = token == "*" ? nil : token
                continue
            }
            return fail("unexpected argument: \(token)")
        }

        // Resolve the level set: the additive tokens are the base, or `ALL` when none was
        // named. A subtractive token expands `ALL` to its concrete members first and then
        // removes — irssi's `ALL -PUBLIC -ACTIONS`.
        var levelSet = Set(addLevels.isEmpty ? ["ALL"] : addLevels)
        if !subLevels.isEmpty {
            if levelSet.remove("ALL") != nil { levelSet.formUnion(IgnoreLevels.concrete) }
            for level in subLevels { levelSet.remove(level) }
        }
        guard !levelSet.isEmpty else { return fail("no levels remain") }

        return .success(
            Parsed(
                rule: IgnoreRule(
                    mask: mask,
                    channels: channels.isEmpty ? nil : channels,
                    pattern: pattern,
                    patternKind: sawRegexp ? .regex : sawFull ? .full : .substr,
                    levels: IgnoreLevels.canonicalize(Array(levelSet)),
                    isExcept: isExcept,
                    expiresAt: expiresAt
                ),
                scopeNetwork: scopeNetwork
            )
        )
    }
}

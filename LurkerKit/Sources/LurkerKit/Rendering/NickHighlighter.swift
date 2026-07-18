// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Finds nicks mentioned inside a message body, the way the web client's `colorNicksInText`
/// does: any known nick that appears as a whole word — not inside a longer word, and not
/// straddling another nick — is a match, so the caller can color it. Compiled once per
/// channel-membership change and reused across that buffer's messages, because building the
/// alternation regex is the expensive part and the member set rarely changes.
public struct NickHighlighter {
    private let regex: NSRegularExpression?

    /// The characters that can appear in an IRC nick. A match must not be flanked by one, so
    /// "bob" inside "bobby" or "bob_" isn't a match. Kept identical to the web client's
    /// `NICK_CHAR_CLASS` so the two clients agree on what counts as a mention.
    private static let nickCharClass = "[A-Za-z0-9_\\-\\[\\]\\\\^{|}]"

    /// `nicks` should already exclude the reader's own nick: a self-mention keeps the body's
    /// own color rather than a palette color, matching the web.
    public init(nicks: [String]) {
        let unique = Array(Set(nicks.filter { !$0.isEmpty }))
        guard !unique.isEmpty else {
            regex = nil
            return
        }
        // Longest first so "alibaba" wins over "ali" when both could match at a position —
        // regex alternation is order-sensitive and takes the first alternative that fits.
        let alternation = unique
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = "(?<!\(Self.nickCharClass))(?:\(alternation))(?!\(Self.nickCharClass))"
        regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Whether this highlighter can ever match — false when there are no known nicks, so the
    /// caller can skip the work entirely.
    public var isEmpty: Bool { regex == nil }

    /// The ranges in `string` that name a known nick, in order. Empty when nothing matches.
    public func matches(in string: String) -> [NSRange] {
        guard let regex else { return [] }
        let full = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: full).map(\.range)
    }
}

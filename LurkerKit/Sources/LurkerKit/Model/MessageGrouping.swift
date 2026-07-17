// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which messages collapse into one visual run.
///
/// This is the load-bearing half of bubble rendering, not a polish detail. A 1:1 messenger
/// can give every message its own nick header and full spacing because there are only two
/// participants and they alternate. An IRC channel has dozens, so without runs you get a
/// nick header per line and the list roughly doubles in height for no added information.
public enum MessageGrouping {
    /// A gap longer than this breaks a run even for the same author. Without it, two
    /// messages from the same nick three hours apart would render as one conversation.
    public static let runGap: TimeInterval = 5 * 60

    /// Whether `message` continues the run that `previous` is part of.
    ///
    /// Only bubbles group: an action or notice is a full-width line, so it breaks any run
    /// it lands in (which is correct — "* nick waves" between two of nick's messages is a
    /// real interruption).
    public static func continuesRun(_ message: Message, after previous: Message?) -> Bool {
        guard let previous,
              message.type.isBubble, previous.type.isBubble,
              message.isSelf == previous.isSelf,
              sameAuthor(message, previous)
        else { return false }
        // No clock on one side → fall back to author alone rather than splitting a run
        // that probably belongs together.
        guard let earlier = previous.date, let later = message.date else { return true }
        return abs(later.timeIntervalSince(earlier)) <= runGap
    }

    /// IRC nicks are case-insensitive and servers send them inconsistently cased, so a
    /// run must not break just because `Brad` said something after `brad`. House style is
    /// an ASCII lowercase fold, matching `BufferKey`.
    private static func sameAuthor(_ lhs: Message, _ rhs: Message) -> Bool {
        (lhs.nick ?? "").lowercased() == (rhs.nick ?? "").lowercased()
    }
}

/// Where a message sits in its run — what the cell needs to know to round the right
/// corners and decide whether to show the nick header and the timestamp.
public struct RunPosition: Equatable, Sendable {
    public let isFirst: Bool
    public let isLast: Bool

    public init(isFirst: Bool, isLast: Bool) {
        self.isFirst = isFirst
        self.isLast = isLast
    }

    /// A message that is its own whole run.
    public static let solo = RunPosition(isFirst: true, isLast: true)
}

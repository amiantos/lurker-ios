// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The server's ISO-8601 `time` field → a `Date`. Two formatters because the server emits
/// fractional seconds on some paths and not others, and `ISO8601DateFormatter` will not
/// parse a string that doesn't match its options exactly.
///
/// The formatters are expensive to build and are not `Sendable`, so they're created once
/// behind a lock rather than per call — parsing runs once per event at the wire boundary,
/// but a backlog frame is a few hundred events at a time.
public enum ISOTime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parse, or nil if absent/unparseable. Never throws — an unreadable timestamp costs
    /// a rendered clock, not a dropped message.
    public static func parse(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: iso) ?? plain.date(from: iso)
    }
}

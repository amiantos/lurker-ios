// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// When to ask the server about a URL again — the whole rule, as arithmetic.
///
/// Pure and separate from `LinkPreviewStore` so it can be exercised directly: the store owns a
/// timer and a task, and a rule buried behind those is a rule tested through a sleep. Ported
/// from the web client's `armReask`, including the three defects that shaped it — each of the
/// ⚠⚠ notes below was a live bug there before it was a comment here.
public enum PreviewReask {

    /// The longest stated TTL that still means "come back" rather than "this is the answer".
    ///
    /// ⚠⚠ Without this test every dead link becomes a perpetual poller. The server answers a
    /// real failure with a one-hour TTL and a transient refusal with ~15 seconds; re-asking both
    /// turned 300 dead links scrolled past into 300 outbound fetches an hour, for as long as the
    /// app stayed open. Worse, the client's deadline and the server's row TTL start at the same
    /// instant, so the re-ask landed *just after* the row lapsed — a guaranteed cache miss and a
    /// fresh fetch to a known-dead origin, every single time. **Only a SHORT TTL means "come
    /// back."** A verdict is re-asked only by a new priming pass, once it has genuinely expired.
    public static let verdictTTL: TimeInterval = 60

    /// Floor on the gap between re-asks, doubling per consecutive failure up to `ceiling`.
    ///
    /// ⚠ A FLOOR, not the delay itself — the delay is whatever the server's own `expiresAt` asks
    /// for, and this only raises it. That distinction is what keeps the steady state cheap
    /// without needing an attempt cap: a genuinely dead URL is answered with the one-hour failure
    /// TTL, so it is a verdict and never reaches here at all. The floor binds only on the ~15s
    /// transient answer — which means the instance is saturated, i.e. precisely when backing off
    /// is the right thing to do rather than re-asking every 15 seconds forever.
    public static let floor: TimeInterval = 15
    public static let ceiling: TimeInterval = 300

    /// How long to wait before asking again, or **nil for "this is the answer, don't"**.
    ///
    /// - `untilExpiry`: seconds until the server's stated `expiresAt`. Pass a non-positive value
    ///   for "already lapsed", and `nil`-expiry callers should pass 0 — an answer with no stated
    ///   expiry, which is what a transport failure produces, backs off on the floor alone.
    /// - `tries`: how many times this URL has already come back unanswered, 1 for the first.
    /// - `jitter`: a value in 0..<1, supplied by the caller so the rule stays pure.
    ///
    /// ⚠⚠ The jitter is not cosmetic, and `max(untilExpiry, floor)` without it was a real bug.
    /// The server jitters its transient TTL specifically so that the losers of one saturation
    /// event don't all come back as a single wave; taking the max against a fixed floor throws
    /// that away and re-synchronises every client onto the same millisecond — a thundering herd
    /// aimed at a server that has just finished saying it is overloaded. ±25%, matching the
    /// server's own spread.
    public static func delay(untilExpiry: TimeInterval, tries: Int, jitter: Double)
        -> TimeInterval?
    {
        guard untilExpiry <= verdictTTL else { return nil }
        let doubled = floor * pow(2, Double(max(0, tries - 1)))
        let base = Swift.max(untilExpiry, Swift.min(ceiling, doubled))
        return base * (0.75 + jitter.clamped(to: 0..<1) * 0.5)
    }
}

extension Double {
    fileprivate func clamped(to range: Range<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound.nextDown)
    }
}

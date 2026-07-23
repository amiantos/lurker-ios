// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which day a highlight falls on, for the results list's per-group header stamp. Structured
/// rather than a formatted string so the pure grouping stays UIKit- and locale-free and the
/// client formats it (Today / Yesterday / a date). `on` carries the start-of-day.
public enum HighlightDay: Equatable, Sendable {
    case today
    case yesterday
    case on(Date)
    case undated

    /// Classify a date against `now` in `calendar`'s time zone. A nil date (an event with no
    /// readable time) is `.undated`.
    ///
    /// "Today"/"yesterday" are measured against the passed-in `now`, NOT the device's current
    /// date — `Calendar.isDateInToday`/`isDateInYesterday` consult the real clock, which would
    /// make the result depend on when it runs (breaking tests, previews, and any as-of caller).
    public init(date: Date?, now: Date, calendar: Calendar) {
        guard let date else { self = .undated; return }
        let dayStart = calendar.startOfDay(for: date)
        let todayStart = calendar.startOfDay(for: now)
        if dayStart == todayStart {
            self = .today
        } else if dayStart == calendar.date(byAdding: .day, value: -1, to: todayStart) {
            self = .yesterday
        } else {
            self = .on(dayStart)
        }
    }
}

/// One channel+day run of highlights: consecutive matches (input order preserved) that share a
/// buffer and a local calendar day. `offset` is the run's first item's index in the flat input,
/// so the list can page off global position regardless of run sizes.
public struct HighlightGroup: Equatable, Sendable {
    public let networkId: Int?
    public let target: String
    public let day: HighlightDay
    public let offset: Int
    public var items: [HighlightItem]

    public init(networkId: Int?, target: String, day: HighlightDay, offset: Int, items: [HighlightItem]) {
        self.networkId = networkId
        self.target = target
        self.day = day
        self.offset = offset
        self.items = items
    }
}

/// Groups a flat, order-preserving list of highlights into channel+day runs — the shape the
/// recent-highlights list (and later search/bookmarks) renders. A new run begins whenever the
/// buffer or the local day changes from the previous row, so consecutive matches in one channel
/// on one day share a header; when channels interleave in time a channel repeats, in order,
/// exactly like iMessage search.
public enum HighlightGrouping {
    /// `now` fixes the reference for Today/Yesterday (passed in, not read, so the result is
    /// deterministic and testable). Buffer identity folds case via `BufferKey.id`, so `#Chan`
    /// and `#chan` stay one run.
    public static func group(
        _ items: [HighlightItem], now: Date, calendar: Calendar = .current
    ) -> [HighlightGroup] {
        var groups: [HighlightGroup] = []
        for (index, item) in items.enumerated() {
            let day = HighlightDay(date: item.message.date, now: now, calendar: calendar)
            if var last = groups.last,
               last.items.last?.bufferKey.id == item.bufferKey.id,
               last.day == day {
                last.items.append(item)
                groups[groups.count - 1] = last
            } else {
                groups.append(HighlightGroup(
                    networkId: item.networkId, target: item.target, day: day, offset: index, items: [item]
                ))
            }
        }
        return groups
    }
}

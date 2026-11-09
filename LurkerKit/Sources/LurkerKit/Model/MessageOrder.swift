// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The order a buffer's rows are shown in: by the time the server stamped them, with id as the
/// tiebreak (lurker#1290; the web's `lib/messageOrder`).
///
/// Ids are the order rows were STORED in, and the two agree for everything heard live. They part
/// on a line fetched after the fact (`replay`, lurker#1283): a gap filled from the network's
/// history after a reconnect holds lines from before the rejoin, stored after its JOIN row with
/// fresh ids, and shown by id they would sit under the join they precede. Ids stay what they are
/// everywhere else: the paging cursor, the dedupe key, the unread boundary (CLIENT_PROTOCOL §9).
/// The store's list is never reordered; this is applied where the rows are built.
public enum MessageOrder {
    private struct Key {
        var date: Date
        var id: Int

        static func <= (a: Key, b: Key) -> Bool {
            a.date != b.date ? a.date < b.date : a.id <= b.id
        }
    }

    /// Where a row sorts. A row with a clock and no id (an ephemeral) goes by its time, last
    /// among rows of that time. A row with no clock (a line the app wrote itself, `appendLocal`)
    /// has nothing to be placed by, so it takes `latest`, the latest key among the rows held
    /// before it: it stays under everything that was on screen when it was written. Not the key
    /// of the row before it, which can be a line fetched after the fact, shown far above.
    private static func key(_ message: Message, latest: Key?) -> Key {
        guard let date = message.date else {
            return latest ?? Key(date: .distantPast, id: 0)
        }
        return Key(date: date, id: message.id != 0 ? message.id : Int.max)
    }

    /// `rows` in display order. The array itself when it already is, which is every buffer that
    /// holds nothing replayed, so a build costs one pass.
    public static func byTime(_ rows: [Message]) -> [Message] {
        // While the rows are in order, the latest key so far is the previous row's.
        var latest: Key?
        var ordered = true
        for message in rows {
            let next = key(message, latest: latest)
            if let latest, !(latest <= next) {
                ordered = false
                break
            }
            latest = next
        }
        if ordered { return rows }

        var keyed: [(key: Key, offset: Int)] = []
        keyed.reserveCapacity(rows.count)
        latest = nil
        for (offset, message) in rows.enumerated() {
            let next = key(message, latest: latest)
            keyed.append((next, offset))
            if let held = latest, next <= held { continue }
            latest = next
        }
        // The offset is the last word, so rows that tie keep the order they were held in.
        keyed.sort { a, b in
            if a.key.date != b.key.date { return a.key.date < b.key.date }
            if a.key.id != b.key.id { return a.key.id < b.key.id }
            return a.offset < b.offset
        }
        return keyed.map { rows[$0.offset] }
    }
}

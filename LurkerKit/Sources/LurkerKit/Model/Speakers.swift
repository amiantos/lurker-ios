// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One entry of the server's recent-speakers list: who spoke in a buffer, and when they last
/// did. Ships on the `backlog` and `history` frames (`wsHub.ts`'s `listSpeakers`), which is the
/// only place it comes from — this is the server's answer, not something derived from the
/// messages a client happens to have loaded.
public struct Speaker: Equatable, Sendable {
    public let nick: String
    public let lastSpoke: Date

    public init(nick: String, lastSpoke: Date) {
        self.nick = nick
        self.lastSpoke = lastSpoke
    }
}

/// One buffer's "who has spoken here lately", keyed by lowercased nick.
///
/// Feeds two readers, and it matters that they share one map. The smart filter (#63) asks *when*
/// a nick last spoke, to decide whether their join/part/quit/nick line is churn worth hiding;
/// `Consolidation` asks *whether* they're in the set at all, to float people you were just
/// talking to to the front of a truncated summary. Two derivations of "recent speaker" would
/// eventually disagree, and the disagreement would show up as a line the filter hid and the
/// summary still counted.
///
/// **Seeded from the server, then kept current locally.** The seed is what makes the phone agree
/// with the browser: the server's list is capped at 20 and computed over a fixed scan window, and
/// deriving the map from loaded messages instead would read anyone who spoke before the loaded
/// window as silent — hiding *more* than the web does, in a buffer the reader has scrolled less
/// of. Live messages are recorded as they arrive because that's the half no fetch can supply:
/// the join-unmask rule ("they joined and immediately started talking") is entirely about speech
/// that happens after the seed.
public struct SpeakerMap: Equatable, Sendable {

    /// How many nicks one buffer remembers. The web keeps the same number, and for the same
    /// reason: the map only ever grows from live traffic, so a channel left open for a day
    /// would otherwise accumulate every nick that ever said anything. Well past the server's
    /// seed of 20, so a seed never immediately evicts itself.
    public static let cap = 128

    private var lastSpoke: [String: Date] = [:]

    public init() {}

    public init(_ speakers: [Speaker]) {
        seed(speakers)
    }

    /// When `nick` last spoke here, or nil if they haven't (within what we know).
    public subscript(nick: String) -> Date? { lastSpoke[nick.lowercased()] }

    /// Everyone in the map, lowercased — what `Consolidation` ranks its truncated name lists by.
    public var nicks: Set<String> { Set(lastSpoke.keys) }

    public var isEmpty: Bool { lastSpoke.isEmpty }

    /// Apply the server's list, keeping any local entry it doesn't know about or that is newer.
    ///
    /// A merge rather than a replace, because the two sources answer at different moments: the
    /// server's list was computed when it built the frame, and anything said since arrived here
    /// as a live event. Replacing wholesale would roll those back — and on a `history` reply
    /// (which the client fetches while the buffer is open) that rollback lands mid-conversation,
    /// re-hiding the join of somebody who is demonstrably talking.
    public mutating func seed(_ speakers: [Speaker]) {
        for speaker in speakers {
            record(nick: speaker.nick, at: speaker.lastSpoke)
        }
    }

    /// Note that `nick` spoke at `date`. Older-than-known times are ignored: a replayed backlog
    /// row must not walk a live entry backwards.
    public mutating func record(nick: String, at date: Date) {
        let key = nick.lowercased()
        guard !key.isEmpty else { return }
        if let known = lastSpoke[key], known >= date { return }
        lastSpoke[key] = date
        trim()
    }

    /// Carry an entry across a nick change, so someone who spoke and then renamed doesn't read
    /// as a stranger when they part. The newer of the two times wins where both exist.
    public mutating func rename(from old: String, to new: String) {
        let oldKey = old.lowercased()
        let newKey = new.lowercased()
        guard !oldKey.isEmpty, !newKey.isEmpty, oldKey != newKey,
              let carried = lastSpoke.removeValue(forKey: oldKey)
        else { return }
        record(nick: newKey, at: carried)
    }

    /// Evict the least-recent speaker once past the cap. One at a time, because entries only
    /// ever arrive one at a time — `seed` records each of its own.
    private mutating func trim() {
        guard lastSpoke.count > Self.cap,
              let oldest = lastSpoke.min(by: { $0.value < $1.value })?.key
        else { return }
        lastSpoke.removeValue(forKey: oldest)
    }
}

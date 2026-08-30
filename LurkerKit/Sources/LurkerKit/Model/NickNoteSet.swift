// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One free-form note about a nick on a network — "lives in Berlin", "spouse: Pat".
public struct NickNote: Equatable, Sendable {
    /// The nick in its stored casing. Lookups fold case (the server's column collates NOCASE
    /// so a case-flip doesn't fragment the row), so this is only what to *show*.
    public let nick: String
    public let note: String
    /// When the note was last written. Nil when the server didn't say — and always nil on a
    /// clear, where there's no row left to have been updated.
    public let updatedAt: Date?

    public init(nick: String, note: String, updatedAt: Date? = nil) {
        self.nick = nick
        self.note = note
        self.updatedAt = updatedAt
    }
}

/// The account's nick notes, per network.
///
/// Network-scoped because the same nick on two networks may be two people — the same keying
/// the server uses (`user_nick_notes` is `(user_id, network_id, nick)`) and the same one
/// `RelayBotSet` and `IgnoreSet` use.
///
/// Server-authoritative, exactly like `RelayBotSet`: writing a note here *asks*, and the note
/// exists once the server fans a `nick-note-updated` back to every device. **Nothing writes to
/// this type but a frame** — replaced whole by `snapshot`, patched a nick at a time by
/// `nick-note-updated`, never mutated in place by the editor that caused the change. A note the
/// server refuses simply never appears.
///
/// **Because it is only ever replaced, `===` is a valid test for "the notes changed"** — what
/// lets a `removeDuplicates` predicate compare it with a pointer test rather than walking every
/// note on every frame the socket delivers.
public final class NickNoteSet: Sendable {
    /// networkId → folded nick → note.
    private let byNetwork: [Int: [String: NickNote]]

    public init(byNetwork: [Int: [NickNote]] = [:]) {
        self.byNetwork = byNetwork.reduce(into: [:]) { out, entry in
            // ⚠ An empty note is the server's spelling of "no note" — `set_nick_note` deletes
            // the row for an empty string rather than storing one. Dropping them here means a
            // cleared note can't survive as a present-but-blank entry that `hasNote` would
            // answer yes to.
            let notes = entry.value.filter { !$0.nick.isEmpty && !$0.note.isEmpty }
            guard !notes.isEmpty else { return }
            out[entry.key] = notes.reduce(into: [:]) { map, note in
                map[note.nick.lowercased()] = note
            }
        }
    }

    /// No notes at all — a fresh session, a signed-out one, and every account that has never
    /// written one, which is most of them.
    public static let empty = NickNoteSet()

    /// The note about `nick` on `networkId`, or nil when there isn't one. A nil network is the
    /// app-scoped system buffer, where there is nobody to have a note about.
    public func note(networkId: Int?, nick: String?) -> NickNote? {
        guard let networkId, let nick, !nick.isEmpty else { return nil }
        return byNetwork[networkId]?[nick.lowercased()]
    }

    /// Whether there is anything written about this nick — for a marker beside them in a list,
    /// where the text itself doesn't fit.
    public func hasNote(networkId: Int?, nick: String?) -> Bool {
        note(networkId: networkId, nick: nick) != nil
    }

    /// This set with one note written or cleared — how a `nick-note-updated` frame folds in.
    ///
    /// The frame carries one nick rather than a network's whole list, so this patches a bucket
    /// rather than replacing it (where it differs from `IgnoreSet.replacing`, whose frame ships
    /// a scope at a time).
    ///
    /// An empty `note` is a **delete**, which is the server's own rule rather than a convention
    /// invented here: `setNickNote.ts` deletes the row for an empty string and echoes back
    /// `note: ''`, so the clear and the write arrive as the same frame shape.
    public func applying(networkId: Int, nick: String, note: String, updatedAt: Date?) -> NickNoteSet {
        guard !nick.isEmpty else { return self }
        var notes = byNetwork[networkId].map { Array($0.values) } ?? []
        notes.removeAll { $0.nick.lowercased() == nick.lowercased() }
        if !note.isEmpty { notes.append(NickNote(nick: nick, note: note, updatedAt: updatedAt)) }
        var next = byNetwork.mapValues { Array($0.values) }
        next[networkId] = notes
        return NickNoteSet(byNetwork: next)
    }

    /// This set with everything about one network forgotten — the local half of a network
    /// delete, matching what `LurkerStore.dropNetwork` does to every other network-keyed slot.
    public func removing(networkId: Int) -> NickNoteSet {
        guard byNetwork[networkId] != nil else { return self }
        var next = byNetwork.mapValues { Array($0.values) }
        next[networkId] = nil
        return NickNoteSet(byNetwork: next)
    }
}

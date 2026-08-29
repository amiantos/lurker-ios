// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The order the buffer list puts things in, where that order is the *user's* rather than
/// this client's: which network comes first, and which of its buffers they pinned.
///
/// Both settings are made on the web — this app deliberately offers no way to change either
/// (#11's follow-up) — so the whole job here is to render a decision that was already taken
/// somewhere else, rather than to impose an alphabet on it. A phone that lists your networks
/// in a different order from the browser you arranged them in is a phone you have to re-read
/// every time you pick it up.
public enum BufferOrder {

    /// Networks in the user's configured order.
    ///
    /// `(position, id)` matches the server's own `ORDER BY position ASC, id ASC`, so the two
    /// agree on ties — and ties are normal, since `position` is only densified when something
    /// is reordered. Id is the tiebreak rather than name: it's what the server falls back to,
    /// and a name-based tiebreak would have two networks swap places on a rename.
    public static func networks(_ networks: [Int: Network]) -> [Network] {
        networks.values.sorted {
            $0.position != $1.position ? $0.position < $1.position : $0.id < $1.id
        }
    }

    /// One network's buffers: pinned first in the user's pin order, then everything else in
    /// the ordinary channels-then-DMs-then-server, sigil-stripped-alphabetical order.
    ///
    /// ⚠ A pin whose buffer isn't open contributes nothing — the pin row survives on the
    /// server when a channel is parted or closed, so a pin list is a superset of what can be
    /// shown, and mapping it blindly would produce rows for buffers that aren't there. The
    /// web filters the same way for the same reason.
    ///
    /// Targets are matched case-insensitively. The pin is stored under the spelling the
    /// server last saw and the buffer under the one the client holds, and IRC lets those
    /// differ — an exact match would silently drop a pin after a CASEMAPPING refold.
    ///
    /// ⚠⚠ Keyed on `target.lowercased()`, which is what `BufferKey.id` uses — NOT
    /// `ChannelName.fold`, which is the *autocomplete* fold and also drops a leading sigil so
    /// `li` matches `#linux`. As a target key that collides two real buffers: `#ops` and
    /// `&ops` both fold to "ops", so a pin on one could render the other in its slot, and the
    /// `rest` filter below — matching the same collided key — would drop the loser out of the
    /// buffer list entirely.
    public static func buffers(_ buffers: [Buffer], pinned: [String]) -> [Buffer] {
        guard !pinned.isEmpty else { return buffers.sorted(by: order) }
        var byTarget: [String: Buffer] = [:]
        for buffer in buffers { byTarget[buffer.target.lowercased()] = buffer }
        var pinnedBuffers: [Buffer] = []
        var claimed: Set<String> = []
        for target in pinned {
            let key = target.lowercased()
            // `claimed` before `byTarget`: a pin list with a duplicate in it must not print
            // the same buffer twice.
            guard !claimed.contains(key), let buffer = byTarget[key] else { continue }
            claimed.insert(key)
            pinnedBuffers.append(buffer)
        }
        let rest = buffers.filter { !claimed.contains($0.target.lowercased()) }
        return pinnedBuffers + rest.sorted(by: order)
    }

    /// Channels, then DMs, then the server log; alphabetical within each.
    ///
    /// Matches the web client's ordering: the alphabetical key strips leading channel sigils
    /// (`##anime` sorts as "anime", not before `#aardvark`), so the two clients list the same
    /// network the same way. All four sigils, via `ChannelName.stripSigils` — a hand-written
    /// `#&` here floated `+`/`!` channels above every named one until lurker-ios#98, which
    /// the web (`stripChannelPrefix`) never did.
    public static func order(_ lhs: Buffer, _ rhs: Buffer) -> Bool {
        func rank(_ kind: BufferKind) -> Int {
            switch kind {
            case .channel: 0
            case .dm: 1
            case .server: 2
            case .system: 3
            }
        }
        if rank(lhs.kind) != rank(rhs.kind) { return rank(lhs.kind) < rank(rhs.kind) }
        return ChannelName.stripSigils(lhs.target)
            .localizedCaseInsensitiveCompare(ChannelName.stripSigils(rhs.target)) == .orderedAscending
    }
}

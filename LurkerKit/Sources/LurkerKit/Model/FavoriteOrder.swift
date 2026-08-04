// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Applying a drag in the Favorites grid back onto the stored key list (#53).
///
/// Its own type because the two lists aren't the same list. What's stored is every key the
/// user has ever pinned, on this device, across networks; what's *shown* is the subset that
/// currently resolves to a buffer — a favorite whose network is still connecting, or one whose
/// DM has since become a friend (and moved to the Friends grid), has a stored slot and no
/// chip. So a move from grid position 1 to position 0 is not a move from stored index 1 to
/// stored index 0, and treating it as one silently rewrites the order of rows the user can't
/// see — worse, it can drop them, which is a favorite lost to a gesture.
///
/// The rule instead: the visible keys keep the *slots* they already occupy in the stored list
/// and are dealt back into them in their new order. Nothing invisible moves, nothing is lost,
/// and the grid ends up in exactly the order the drag drew.
///
/// ## What that costs, deliberately
///
/// A hidden key holds its slot even when the slot is *first*. Pin a favorite on a network that
/// is still connecting, drag another chip "to the top", and the hidden one still appears above
/// it when its network arrives — because position 0 of the grid is not position 0 of the list.
///
/// The alternative is worse: to put the dragged key genuinely first, the drag would have to
/// displace a key the user can't see and didn't touch, on every drag, forever. This way the
/// only thing a drag ever reorders is what was on screen when it was made — and the hidden
/// key is sitting where the user themselves last put it. Pinned by the boundary tests.
public enum FavoriteOrder {

    /// The stored order after moving the visible item at `from` to `to`.
    ///
    /// Returns `stored` untouched when the move can't be applied — indices out of range, or a
    /// visible key the stored list doesn't have. A gesture that can't be interpreted must be a
    /// no-op rather than a guess: this list is the only record of what's pinned, and there is
    /// no server copy to restore it from.
    public static func moved(_ stored: [String], visible: [String], from: Int, to: Int) -> [String] {
        guard visible.indices.contains(from), visible.indices.contains(to), from != to else { return stored }
        // Containment, not a count. Every visible key must occupy exactly one slot to be dealt
        // back into — a deal that runs short leaves stale keys in the slots it never reached,
        // and one that runs long writes a key that was never pinned.
        //
        // The cardinality check this replaces looked equivalent and wasn't: a duplicate in
        // `stored` contributes two slots, which could make the counts agree while a visible key
        // had no slot at all. `["a","a","b"]` against a visible `["a","b","c"]` reached three
        // slots, passed, and dealt `"c"` into the list while destroying an `"a"`. Nothing can
        // currently produce a duplicated `stored` — the server's favorites list is keyed by
        // buffer id — but this guard exists precisely for the input nothing is supposed to
        // produce.
        let unique = Set(visible)
        guard unique.count == visible.count, unique.isSubset(of: stored) else { return stored }
        let slots = stored.indices.filter { unique.contains(stored[$0]) }
        guard slots.count == visible.count else { return stored }

        var reordered = visible
        reordered.insert(reordered.remove(at: from), at: to)

        var next = stored
        for (slot, key) in zip(slots, reordered) { next[slot] = key }
        return next
    }
}

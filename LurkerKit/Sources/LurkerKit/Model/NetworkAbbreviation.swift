// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Short network labels for the buffer-list grid chips, where a buffer has been lifted out of
/// its network's section and two chips can otherwise be pixel-identical (`#lurker` on two
/// networks, `alice` on two networks).
///
/// The label is the **shortest prefix of the network name that no other network shares** —
/// `l` for libera on an instance where it's the only `l…`, `li`/`lu` once libera and lurkernet
/// coexist. The web client (`BufferList.vue`'s `networkAbbrevs`) computes the same thing for
/// the same rows, so the two clients name a network the same way.
///
/// A prefix rather than the full name because the full name next to a nick read as clutter at
/// every length tried, and because this rides *inside* the chip's one line — the thing it
/// disambiguates is the name it follows, so it has to stay small enough not to become the
/// thing you read first. The full name is still what the accessibility label says, for
/// everyone, hint or no hint.
///
/// ⚠ Uniqueness is computed against **every** network, not just the ones currently colliding
/// on screen. Otherwise the same network would abbreviate differently from section to section
/// as buffers came and went, and a label that changes under you is worse than a long one.
public enum NetworkAbbreviation {
    /// Shortest-unique-prefix label per network id, lowercased.
    ///
    /// Two networks with the *same* name both get the full name: no prefix can separate them,
    /// so the loop runs out of string and returns what it has. That's the honest answer — the
    /// names really are ambiguous — and it beats inventing a tiebreaker the web doesn't have.
    public static func shortestUniquePrefixes(_ namesById: [Int: String]) -> [Int: String] {
        let lowered = namesById.mapValues { $0.lowercased() }
        var out: [Int: String] = [:]
        for (id, name) in lowered {
            var length = 1
            while length < name.count {
                let candidate = String(name.prefix(length))
                let shared = lowered.contains { $0.key != id && $0.value.hasPrefix(candidate) }
                if !shared { break }
                length += 1
            }
            out[id] = String(name.prefix(length))
        }
        return out
    }
}

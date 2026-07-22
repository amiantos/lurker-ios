// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Channel-name handling shared by the command parser (which prefixes a bare `/join` target)
/// and the composer's autocomplete (which folds a query to match channels regardless of the
/// sigil the user has typed yet). Kept in one place so the set of channel sigils isn't
/// written twice and drift into disagreement.
///
/// Distinct from `BufferKind.of`, which classifies an *existing* target as a channel using
/// only `#`/`&` — the sigils a server actually opens buffers for. This covers the full
/// RFC-1459 set for the *input* side, matching the web client's `ensureChannelPrefix`.
public enum ChannelName {
    /// The RFC-1459 channel-name sigils.
    public static let sigils: Set<Character> = ["#", "&", "+", "!"]

    /// Whether `name` already carries a channel sigil.
    public static func isPrefixed(_ name: String) -> Bool {
        name.first.map(sigils.contains) ?? false
    }

    /// A bare name gets a leading `#`; an already-sigiled one is left alone. The web's
    /// `ensureChannelPrefix`.
    public static func ensurePrefix(_ name: String) -> String {
        isPrefixed(name) ? name : "#\(name)"
    }

    /// Fold for prefix-matching in autocomplete: lowercased, with one leading sigil dropped,
    /// so `li` and `#li` both match `#linux`.
    public static func fold(_ name: String) -> String {
        var lowered = name.lowercased()
        if let first = lowered.first, sigils.contains(first) { lowered.removeFirst() }
        return lowered
    }
}

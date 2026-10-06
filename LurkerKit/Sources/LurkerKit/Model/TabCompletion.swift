// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// In-place Tab completion from a hardware keyboard (lurker-android#63): the web composer's Tab
/// handler (`MessageInput.vue`), so the three clients complete the same word the same way.
///
///  - The token is the whitespace-delimited word around the caret, so `al|ice` completes the
///    whole word rather than leaving its tail behind.
///  - A token that starts with `#` completes a channel, `#` included; anything else completes a
///    nick, with a leading `@` dropped from what's matched (and from what's inserted).
///  - A nick that opens its line is being addressed, and takes the addressing suffix
///    (`input.completion.nick_suffix` plus a space); mid-sentence it takes nothing, so a comma or a
///    question mark can follow it. A channel never takes one.
///  - Tab again cycles through the matches, Shift-Tab backwards — but only while the caret is
///    where the last insertion left it. A tap or an arrow that moved it starts a new completion
///    from whatever word is under it now (`continues`).
///
/// Offsets are UTF-16, the currency of `NSRange` on iOS and of a text field's selection on
/// Android. Pure, so the whole rule is tested here; the composers own the session and the keys.
public struct TabCompletion: Equatable, Sendable {
    /// What one step of the completion leaves in the composer.
    public struct Edit: Equatable, Sendable {
        public let text: String
        /// UTF-16 offset just past the inserted name and its suffix.
        public let caret: Int
    }

    private let prefix: String
    private let tail: String
    private let suffix: String
    private let matches: [String]
    private var index: Int

    /// Start a completion for the word around `caret` in `text`, or nil when there's no word under
    /// it or nothing matches.
    ///
    /// `nicks` answers the nick candidates for what's been typed, best first — pass
    /// `NickCompletion.candidates` with no limit to speak of, so Tab can cycle through every match,
    /// as the web's can. `channels` answers the network's channels, best first (the one you're in
    /// leads), asked only when the word starts with `#`; this filters them by the typed prefix.
    /// `punctuation` is `NickCompletion.addressPunctuation(settings)`.
    public static func begin(
        text: String,
        caret: Int,
        nicks: (String) -> [String],
        channels: () -> [String],
        punctuation: String
    ) -> TabCompletion? {
        let units = Array(text.utf16)
        let at = min(max(0, caret), units.count)
        var start = at
        while start > 0, !isWhitespace(units[start - 1]) { start -= 1 }
        var end = at
        while end < units.count, !isWhitespace(units[end]) { end += 1 }
        guard start < end, let token = String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
            .nilIfEmpty
        else { return nil }

        let prefix = String(utf16CodeUnits: Array(units[..<start]), count: start)
        let tail = String(utf16CodeUnits: Array(units[end...]), count: units.count - end)
        // ⚠ `#`-only on purpose, as on the web (#724): this asks which SIGIL was typed, not whether
        // a target is a channel. Widening it would make a leading `+` or `!` in ordinary prose
        // start completing channel names.
        let isChannel = token.hasPrefix("#")
        let matches: [String]
        if isChannel {
            let typed = token.lowercased()
            matches = channels().filter { $0.lowercased().hasPrefix(typed) }
        } else {
            let query = token.hasPrefix("@") ? String(token.dropFirst()) : token
            guard !query.isEmpty else { return nil }
            matches = nicks(query)
        }
        guard !matches.isEmpty else { return nil }
        let suffix = !isChannel && isAtLineStart(prefix) ? punctuation + " " : ""
        return TabCompletion(prefix: prefix, tail: tail, suffix: suffix, matches: matches, index: 0)
    }

    /// The composer as this step leaves it.
    public var edit: Edit {
        let head = prefix + matches[index] + suffix
        return Edit(text: head + tail, caret: head.utf16.count)
    }

    /// The next match (the previous one, `backward`), wrapping at either end.
    public mutating func cycle(backward: Bool) -> Edit {
        let count = matches.count
        index = (index + (backward ? -1 : 1) + count) % count
        return edit
    }

    /// Whether the composer still shows what this completion last left — so another Tab cycles it
    /// rather than starting over. False once the text or the caret has moved.
    public func continues(text: String, caret: Int) -> Bool {
        let current = edit
        return current.text == text && current.caret == caret
    }

    /// The web's `isAtLineStart`, `/(^|\n)\s*$/`: nothing but whitespace since the last newline,
    /// or since the start of the draft.
    static func isAtLineStart(_ before: String) -> Bool {
        for unit in before.utf16.reversed() {
            if unit == 0x0A { return true }
            if !isWhitespace(unit) { return false }
        }
        return true
    }

    /// JavaScript's `\s` over a UTF-16 unit — the web's token boundary.
    static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

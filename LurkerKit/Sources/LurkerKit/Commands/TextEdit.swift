// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The smallest edit that turns one text into another — so a composer that rewrites its field
/// (a completion, a Reply's address) can touch only what changed, and the colour on the rest of
/// the line survives it.
public enum TextEdit {

    /// The range of `old` to replace, in UTF-16 (`NSRange`'s and `UITextView`'s currency), and
    /// what to put there.
    ///
    /// ⚠ The ends are snapped out to whole characters. A common prefix counted in UTF-16 units
    /// stops INSIDE a surrogate pair when two emoji share their high half (`😀` and `😃` both
    /// open with D83D), and a splice there writes a lone surrogate — a broken character on the
    /// wire. Snapping can only widen the edit, which costs nothing.
    public static func difference(from old: String, to new: String) -> (range: NSRange, replacement: String) {
        let a = old as NSString, b = new as NSString
        let shorter = min(a.length, b.length)
        var prefix = 0
        while prefix < shorter, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        while true {
            let snapped = min(start(of: a, at: prefix), start(of: b, at: prefix))
            if snapped == prefix { break }
            prefix = snapped
        }
        var suffix = 0
        while suffix < shorter - prefix,
              a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        while true {
            let snapped = min(a.length - end(of: a, at: a.length - suffix), b.length - end(of: b, at: b.length - suffix))
            if snapped == suffix { break }
            suffix = snapped
        }
        return (
            NSRange(location: prefix, length: a.length - prefix - suffix),
            b.substring(with: NSRange(location: prefix, length: b.length - prefix - suffix))
        )
    }

    /// `index`, moved back to the start of the character it falls inside.
    private static func start(of text: NSString, at index: Int) -> Int {
        guard index < text.length else { return index }
        return text.rangeOfComposedCharacterSequence(at: index).location
    }

    /// `index` as the end of an edit, moved forward to the end of the character it falls inside.
    private static func end(of text: NSString, at index: Int) -> Int {
        guard index > 0, index < text.length else { return index }
        let character = text.rangeOfComposedCharacterSequence(at: index)
        return character.location < index ? NSMaxRange(character) : index
    }
}

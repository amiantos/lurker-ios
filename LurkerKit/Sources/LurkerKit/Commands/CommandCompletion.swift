// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The pure logic behind command autocomplete — the sibling of `NickCompletion`, feeding the
/// same floating pill strip. It answers one question the composer asks on every keystroke and
/// caret move: *is a command completion live under the caret, and if so, what kind?*
///
///  - Typing the verb (`/jo|`) → command chips, filtered by what's typed.
///  - Typing an argument of a known command (`/join #li|`, `/msg ali|`) → channel or nick
///    chips, decided by that command's argument grammar (`CommandSpec.argKind`).
///  - A free-text argument slot (`/me hello…`) or an unknown command → nothing here; the
///    composer falls through to `@`-mention detection, so `/me @al|` still completes a nick.
///
/// Offsets are UTF-16 (`NSRange`'s currency), so the composer can hand `selectedRange`
/// straight in and splice the completion back with `NSString`.
public enum CommandCompletion {

    /// A live command completion under the caret. `range` is the whole token the pick
    /// replaces (verb or argument), so completing `/jo|in` swallows the tail rather than
    /// welding onto it — the same rule `NickCompletion` uses for `@al|ice`.
    public enum Context: Equatable {
        /// The verb is being typed. `query` is the text after the slash, up to the caret.
        case command(query: String, range: NSRange)
        /// An argument of a known command is being typed. `kind` is `.channel` or `.nick` —
        /// the only kinds that produce chips.
        case argument(verb: String, index: Int, kind: ArgKind, query: String, range: NSRange)
    }

    /// Classify the caret. Returns nil when the line isn't a command, it's a `//` escape, the
    /// verb is unknown, or the slot under the caret is free text / opaque (channel key, mode
    /// string, your new nick) — every case where the composer should try `@`-mention instead.
    public static func context(in text: String, caret: Int) -> Context? {
        let chars = Array(text.utf16)
        guard caret >= 0, caret <= chars.count else { return nil }
        let slash = UInt16(UnicodeScalar("/").value)

        // The command must open the line. Leading whitespace is skipped (the send path trims
        // it too), so " /join" still completes.
        var start = 0
        while start < chars.count, isWhitespace(chars[start]) { start += 1 }
        guard start < chars.count, chars[start] == slash else { return nil }
        // `//…` is an escaped literal, not a command.
        if start + 1 < chars.count, chars[start + 1] == slash { return nil }
        // Caret sitting in the leading whitespace or on the slash has nothing to complete.
        guard caret > start else { return nil }

        // The verb token: from the slash to the first whitespace.
        var index = start + 1
        while index < chars.count, !isWhitespace(chars[index]) { index += 1 }
        let verbEnd = index

        // Caret still inside the verb token → command-name completion.
        if caret <= verbEnd {
            let query = string(chars[(start + 1)..<caret])
            return .command(query: query, range: NSRange(location: start, length: verbEnd - start))
        }

        // Past the verb: resolve it. An unknown verb goes raw on send, so there's nothing to
        // suggest for its arguments.
        let verb = string(chars[(start + 1)..<verbEnd]).lowercased()
        guard let spec = CommandRegistry.spec(for: verb) else { return nil }

        // Walk the argument tokens to find which one the caret sits in (or the empty slot it's
        // poised to start).
        var argIndex = 0
        var scan = verbEnd
        while scan < chars.count {
            while scan < chars.count, isWhitespace(chars[scan]) { scan += 1 }
            let tokenStart = scan
            // Caret is in the whitespace gap before this token → an empty new argument here.
            if caret < tokenStart {
                return argument(spec: spec, index: argIndex, query: "", range: NSRange(location: caret, length: 0))
            }
            while scan < chars.count, !isWhitespace(chars[scan]) { scan += 1 }
            let tokenEnd = scan
            if caret >= tokenStart, caret <= tokenEnd {
                let query = string(chars[tokenStart..<caret])
                return argument(spec: spec, index: argIndex, query: query, range: NSRange(location: tokenStart, length: tokenEnd - tokenStart))
            }
            argIndex += 1
        }
        // Caret is past the last token, in trailing whitespace → a fresh empty argument.
        return argument(spec: spec, index: argIndex, query: "", range: NSRange(location: caret, length: 0))
    }

    /// Wrap an argument slot in a `Context`, but only when its kind is one we can suggest for.
    private static func argument(spec: CommandSpec, index: Int, query: String, range: NSRange) -> Context? {
        let kind = spec.argKind(at: index)
        guard kind == .channel || kind == .nick else { return nil }
        return .argument(verb: spec.name, index: index, kind: kind, query: query, range: range)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func string(_ slice: ArraySlice<UInt16>) -> String {
        String(decoding: slice, as: UTF16.self)
    }
}

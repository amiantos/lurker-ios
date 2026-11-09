// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Slack-style `:shortcode:` emoji (lurker#1294) — the web's `emojiShortcodes.ts` and
/// `emojiData.ts` in one: the gemoji table and the grammar that finds a shortcode in text.
///
/// The web turns `:skull:` into 💀 twice, and so do the apps: in the composer on the closing
/// colon (`completed`), and at render time for anything that arrives as a literal shortcode
/// from a client that doesn't (`matches`, applied by `replace`). `/react` and the reaction
/// sheet's field take a name too (`reaction`). All three read the same table, so the three
/// clients resolve the same set.
///
/// A shortcode is `:name:` where `name` is one or more of `[a-z0-9_+-]` — the gemoji
/// character set (`:+1:`, `:e-mail:`, `:thumbsup:`). Matching is case-insensitive over ASCII:
/// a typed `:Bone:` resolves straight against the (lowercase) table. The opening `:` must not sit
/// right behind another shortcode character, so a clock like `12:00` or `word:bone:` never
/// reads as a shortcode start, and ASCII smileys fall out for free: `:-)` never closes
/// because `)` isn't a shortcode character. An unknown name stays literal.
///
/// ⚠ `Resources/emoji.json` is a **copy** of the web's table: `{name: glyph}`, derived from
/// `vue_client/src/utils/emojiData.ts` in the lurker repo, which `tools/gen-emoji-data.mjs`
/// there generates from github/gemoji `db/emoji.json` (pinned at revision
/// 0eca75db9301421efc8710baf7a7576793ae452a — 1870 emoji, 1913 aliases). Regenerate it from
/// that file when the web's moves, so the three clients keep resolving the same names. The
/// emoji data is gemoji's, distributed under the MIT License (Copyright (c) 2019 GitHub, Inc.).
public enum EmojiShortcodes {

    /// One resolvable shortcode in a string: where it sits, in UTF-16 units, and the glyph it
    /// stands for.
    public struct Match: Equatable, Sendable {
        public let range: NSRange
        public let glyph: String

        public init(range: NSRange, glyph: String) {
            self.range = range
            self.glyph = glyph
        }
    }

    /// The gemoji shortcode character set, both cases spelled out. Defined once so the body
    /// pattern and the opening-boundary lookbehind can't drift apart — the web's `NAME_CHARS`.
    /// ⚠ Not `[a-z]` with `.caseInsensitive`: ICU folds beyond ASCII, so the Kelvin sign in
    /// `:sKull:` would match `k` and the long s in `ſ:skull:` would glue the colon, where the
    /// web's non-Unicode regex does neither.
    private static let nameChars = "[A-Za-z0-9_+-]"

    /// Every completed `:name:` whose opening colon isn't glued to a preceding shortcode
    /// character — the web's `shortcodeScanRegex`.
    private static let scan = try? NSRegularExpression(pattern: "(?<!\(nameChars)):(\(nameChars)+):")

    /// A completed `:name:` ending exactly at the end of the string — the web's `CLOSE_RE`,
    /// run on the text up to the caret. ⚠ `\z`, not the web's `$`: in ICU (and java.util.regex)
    /// `$` also matches before a final line terminator, so `:tada:\n` with the caret after the
    /// newline would read as "just closed" and the swap would land on the line above.
    private static let closing = try? NSRegularExpression(pattern: "(?<!\(nameChars)):(\(nameChars)+):\\z")

    /// A whole typed reaction that is one shortcode, closing colon optional — the web's
    /// `reactionFromInput`. Nothing may follow it, so `:tada` is unambiguous.
    private static let whole = try? NSRegularExpression(pattern: "^:(\(nameChars)+):?$")

    /// Shortcode body (no colons, lowercase) → glyph. Read once from the bundle; a resource
    /// that doesn't reach it leaves an empty table, and every shortcode stays literal — which
    /// `testTheTableLoadsFromTheBundle` is there to catch.
    static let table: [String: String] = {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return parsed
    }()

    /// The glyph for a shortcode body (case-insensitive), or nil when it isn't a known emoji —
    /// the web's `emojiForShortcode`.
    public static func glyph(for name: String) -> String? {
        table[name.lowercased()]
    }

    /// Every resolvable `:name:` in `text`, in order, as the render pass replaces them. An
    /// unknown name is left out (it stays literal). `protecting` — the caller's spoilers and
    /// links — is cut out before the scan, and each stretch between is scanned on its own: the
    /// web splits URLs out first and runs its emoji pass over what remains, so a shortcode never
    /// forms inside a link (a URL's path is text) or a spoiler (a glyph there would be a visible
    /// shape in a box of invisible ones), and the opening-colon rule never looks INTO a link —
    /// `<https://x.test>:skull:` is a link and then 💀, not a colon glued to the `t`.
    public static func matches(in text: String, protecting: [NSRange] = []) -> [Match] {
        guard let scan, !text.isEmpty else { return [] }
        let source = text as NSString
        var out: [Match] = []
        for gap in gaps(in: source.length, protecting: protecting) {
            let stretch = source.substring(with: gap)
            for found in scan.matches(in: stretch, range: NSRange(location: 0, length: gap.length)) {
                guard let glyph = glyph(for: (stretch as NSString).substring(with: found.range(at: 1))) else { continue }
                out.append(Match(range: NSRange(location: gap.location + found.range.location, length: found.range.length), glyph: glyph))
            }
        }
        return out
    }

    /// The stretches of `0..<length` that none of `protecting` covers, in order.
    private static func gaps(in length: Int, protecting: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        var from = 0
        for range in protecting.sorted(by: { $0.location < $1.location }) {
            if range.location > from { out.append(NSRange(location: from, length: min(range.location, length) - from)) }
            from = max(from, NSMaxRange(range))
        }
        if from < length { out.append(NSRange(location: from, length: length - from)) }
        return out
    }

    /// Replace every match in `attributed` with its glyph, back to front so each earlier range
    /// still means what `matches` measured. The glyph takes the attributes of the shortcode's
    /// first character — the run it was typed in, so a bold `:tada:` is a bold 🎉 — and
    /// anything set on only part of the name (a nick coloured inside it) goes with the name.
    public static func replace(in attributed: NSMutableAttributedString, protecting: [NSRange] = []) {
        for match in matches(in: attributed.string, protecting: protecting).reversed() {
            attributed.replaceCharacters(in: match.range, with: match.glyph)
        }
    }

    /// The composer's moment: the user just typed the closing `:` of a known `:name:`, so the
    /// character before `caret` ends a shortcode. The match to swap for its glyph, or nil —
    /// including for an unknown name, which stays as typed. The web's `findCompletedShortcode`
    /// and the lookup that follows it.
    public static func completed(in text: String, caret: Int) -> Match? {
        guard let closing, caret > 0, caret <= (text as NSString).length else { return nil }
        let head = (text as NSString).substring(to: caret) as NSString
        guard let found = closing.firstMatch(in: head as String, range: NSRange(location: 0, length: caret)),
              let glyph = glyph(for: head.substring(with: found.range(at: 1)))
        else { return nil }
        return Match(range: found.range, glyph: glyph)
    }

    /// A reaction typed as text — `/react`'s argument, the sheet's field: a whole `:name:` or
    /// `:name` that the table knows becomes its glyph; anything else, an unknown name included,
    /// goes out as typed (trimmed). The web's `reactionFromInput`. `:D` and `:-)` are reactions
    /// people type on purpose: `d` is no emoji's name, and `)` is no name character.
    public static func reaction(from raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let whole,
              let found = whole.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let glyph = glyph(for: (text as NSString).substring(with: found.range(at: 1)))
        else { return text }
        return glyph
    }
}

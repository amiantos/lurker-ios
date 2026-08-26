// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// URL auto-linking, ported from the lurker repo's `shared/urlPattern.ts` (a directly
/// portable regex) plus its trailing-punctuation trim and scheme inference.
public enum URLMatcher {

    /// The exact `shared/urlPattern.ts` source, applied case-insensitively.
    public static let pattern =
        #"(?:(?:https?|ftps?)://|mailto:|www\.)[^\s<>`]+|\b[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}\b"#

    private static let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])

    /// Every URL-ish span in `text`, UNTRIMMED and in order.
    ///
    /// The one place the pattern is run, so that everything asking "where are the URLs in this
    /// message" gets the same answer. ⚠⚠ `PreviewSelection` used to carry its own copy of the
    /// pattern AND its own trimmer, and the trimmer differed: it dropped a closing bracket
    /// unconditionally where `trimTrailingPunctuation` counts them. So
    /// `…/wiki/Rust_(programming_language)` was resolved one character short of the URL the
    /// reader actually taps — the card silently never appeared, and the 404 was cached for an
    /// hour under a string appearing nowhere in the message. Two parsers disagreeing about where
    /// a URL ends is the bug; one parser is the fix.
    ///
    /// Untrimmed because the trim is not always wanted: inside angle brackets the author has
    /// stated where the address ends, and `isBracketedUrl` has to measure against what was
    /// actually matched.
    static func rawRanges(in text: String) -> [NSRange] {
        guard let regex else { return [] }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: whole).map(\.range)
    }

    /// Whether a match is wrapped in angle brackets — `<https://example.com>`.
    ///
    /// RFC 3986 Appendix C's convention: brackets delimit a URL so a reader (and a parser)
    /// doesn't have to guess where it ends inside prose. Discord borrowed it as "link, but no
    /// unfurl", and that is the meaning here — `PreviewSelection` refuses to resolve what they
    /// wrap. It is the only per-link control a poster has over an unfurl, which is why there is
    /// no other one.
    ///
    /// ⚠⚠ Measured against the UNTRIMMED match, and this is the whole subtlety.
    /// `trimTrailingPunctuation` eats the `.` off `<https://example.com/a.>`, so measuring from
    /// the trimmed length looks one character short of the `>` — and the brackets stop being
    /// recognised on exactly the URLs whose ends are ambiguous, which is the case the convention
    /// exists for.
    ///
    /// ⚠ No scheme test, deliberately: `<www.example.com>` is the same convention, and callers
    /// apply their own scheme rules afterwards.
    static func isBracketedUrl(_ text: String, at range: NSRange) -> Bool {
        let ns = text as NSString
        guard range.location > 0, range.location + range.length < ns.length else { return false }
        return ns.character(at: range.location - 1) == UInt16(UnicodeScalar("<").value)
            && ns.character(at: range.location + range.length) == UInt16(UnicodeScalar(">").value)
    }

    /// URL ranges (into `text`) paired with their resolved hrefs.
    ///
    /// `delimiters` is the range of the `<…>` wrapping the URL, when it has them — the caller
    /// deletes it so the brackets don't render, exactly as the web client does. Nil otherwise.
    ///
    /// ⚠⚠ Inside brackets the whole match is the URL, with NO trailing-punctuation trim. That is
    /// the entire point of the convention: the author has stated where the address ends, so
    /// `<https://en.wikipedia.org/wiki/Foo.>` keeps its full stop instead of having it guessed
    /// away. Trimming there would also break `isBracketedUrl`, which measures the untrimmed
    /// match — see its note.
    ///
    /// ⚠⚠ `range` is the ONLY span of the address on offer, and the untrimmed match is
    /// deliberately not handed back beside it. It used to be, for the preview-hiding deletion,
    /// and having both within reach is what let that deletion take a closing delimiter whose
    /// partner sat in the prose — `look at this (…a.png)` rendering as `look at this (` (#126).
    /// Anything that needs to reach past the address for punctuation asks
    /// `PreviewText.absorbing`, which knows which characters are safe to take.
    public static func matches(in text: String)
        -> [(range: NSRange, href: String, delimiters: NSRange?)]
    {
        let ns = text as NSString
        return rawRanges(in: text).compactMap { range in
            let matched = ns.substring(with: range)
            if isBracketedUrl(text, at: range), carriesAScheme(matched) {
                return (
                    range, href(for: matched),
                    NSRange(location: range.location - 1, length: range.length + 2)
                )
            }
            let trimmed = trimTrailingPunctuation(matched)
            guard !trimmed.isEmpty else { return nil }
            return (
                NSRange(location: range.location, length: (trimmed as NSString).length),
                href(for: trimmed),
                nil
            )
        }
    }

    /// Whether a match is a URI as WRITTEN, rather than a bare address the matcher inferred a
    /// scheme for.
    ///
    /// ⚠⚠ This is what keeps the `<…>` convention off email. `isBracketedUrl` deliberately applies
    /// no scheme test — `<www.example.com>` is the same convention — and the renderer took that
    /// permissive answer as licence to DELETE the brackets, so
    /// `Co-Authored-By: Claude <noreply@anthropic.com>` rendered as
    /// `Co-Authored-By: Claude noreply@anthropic.com`. RFC 5322 angle-addr is ordinary traffic on
    /// IRC — git trailers, quoted mail, "mail me at <foo@bar.com>" — and this fires in the
    /// app-wide linkifier, so it hit every message for every user with both preview settings off.
    ///
    /// RFC 3986 Appendix C is about delimiting a URI. A bare `foo@bar.com` is not one; we merely
    /// guess `mailto:` for it, and a guess is not grounds for rewriting what somebody typed.
    private static func carriesAScheme(_ matched: String) -> Bool {
        let lower = matched.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("ftp://") || lower.hasPrefix("ftps://")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("www.")
    }

    /// `text` with every URL replaced by a single space — what a content pattern is matched
    /// against, so a word that appears only inside a link doesn't trigger it (a nick in
    /// `https://example.com/nick`, say). The web's `stripUrls`.
    ///
    /// A space rather than nothing: removing the URL outright would fuse the words on either
    /// side of it into one that was never written.
    ///
    /// Deliberately the raw pattern, *not* `matches(in:)` — that one trims trailing
    /// punctuation so a link can be tapped without swallowing the sentence's full stop, which
    /// is a rendering concern. Here the whole match goes, exactly as the shared matcher does
    /// it, so the two clients agree on what "the text" is.
    public static func blanked(_ text: String) -> String {
        guard let regex else { return text }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: whole, withTemplate: " ")
    }

    /// Strip trailing sentence punctuation and one unbalanced closing bracket, so
    /// `(see https://x.com)` and `end of https://x.com.` don't swallow the delimiter.
    static func trimTrailingPunctuation(_ url: String) -> String {
        var result = Substring(url)
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\""]
        while let last = result.last, trailing.contains(last) { result = result.dropLast() }
        for (open, close) in [(Character("("), Character(")")), ("[", "]"), ("{", "}")] {
            guard result.last == close else { continue }
            if result.filter({ $0 == close }).count > result.filter({ $0 == open }).count {
                result = result.dropLast()
            }
        }
        return String(result)
    }

    /// `www.` → `http://`, a bare `name@host.tld` → `mailto:`, otherwise as-is.
    static func href(for url: String) -> String {
        let lower = url.lowercased()
        if lower.hasPrefix("www.") { return "http://" + url }
        if !lower.contains("://"), !lower.hasPrefix("mailto:"), url.contains("@") { return "mailto:" + url }
        return url
    }
}

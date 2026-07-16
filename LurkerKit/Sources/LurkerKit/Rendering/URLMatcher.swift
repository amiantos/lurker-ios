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

    /// URL ranges (into `text`) paired with their resolved hrefs.
    public static func matches(in text: String) -> [(range: NSRange, href: String)] {
        guard let regex else { return [] }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: whole).compactMap { match in
            let raw = ns.substring(with: match.range)
            let trimmed = trimTrailingPunctuation(raw)
            guard !trimmed.isEmpty else { return nil }
            let range = NSRange(location: match.range.location, length: (trimmed as NSString).length)
            return (range, href(for: trimmed))
        }
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

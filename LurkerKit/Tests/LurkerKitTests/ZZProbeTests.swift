import Foundation
@testable import LurkerKit
import Testing

@Suite("ZZProbe") struct ZZProbe {
    @Test("probe") func probe() {
        for text in [
            "(https://e.test/a.png.)",
            "look at this https://e.test/a.png\u{2026}",
            "check https://e.test/a.png...",
        ] {
            let m = URLMatcher.matches(in: text).first
            let spans = PreviewText.urlSpans(in: text).spans
            print("PROBE text=\(text)\n  href=\(m?.href ?? "nil") range=\(String(describing: m?.range))\n  spans=\(spans)")
        }
        // #5: duplicate URL, one copy inside a spoiler run
        let a = "https://e.test/a.png"
        let spoiled = "\(a) then \(SpoilerMarkup.apply(to: "||\(a)||"))"
        let (vis, sp) = PreviewText.urlSpans(in: spoiled)
        print("PROBE spoiler visible=\(vis)\n  spans=\(sp)")
        print("PROBE hideable=\(PreviewHiding.hideableUrls(in: spoiled, candidates: [a]))")
        print("PROBE matchesInVisible=\(URLMatcher.matches(in: vis).map { ($0.range, $0.href) })")
    }
}

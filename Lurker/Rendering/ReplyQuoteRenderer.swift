// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

extension MessageRenderer {

    /// An IRCv3 reply's quote (iOS #184) — the web's `ReplyQuote.vue`: the answered line written
    /// the way IRC writes it, `<alice> text`, `* bob waves`, `-ChanServ- text`, after a rounded
    /// box-drawing arm, so it reads as what was said rather than a sentence starting with a name.
    /// Italic, one line; the cell fades the whole label so the quoted nick keeps its own colour.
    /// With nothing to quote it says so.
    ///
    /// The arm is upright and lifted a little: in an italic line a slanted corner stops lining up,
    /// and on the baseline it sits below the text's middle.
    static func renderReplyQuote(
        _ quote: ReplyQuote?, indent: CGFloat, traits: UITraitCollection
    ) -> NSAttributedString {
        let base = compactFont(compatibleWith: traits)
        let italic = base.italic
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineBreakMode = .byTruncatingTail
        // The arm is lifted so it sits level with the text's middle, as the web nudges it up 3px.
        // ⚠ A raised run alone made UILabel clip the line's DESCENDERS ("anyone" lost its tail):
        // it sized the line for the font and drew it lower. Reserving the lift as line height
        // first is what keeps the whole line inside the label.
        let lift = round(base.pointSize * 0.18)
        paragraph.minimumLineHeight = ceil(base.lineHeight + lift)
        let line = NSMutableAttributedString(
            string: "╭─ ",
            attributes: [
                .font: base, .foregroundColor: Palette.fg, .paragraphStyle: paragraph,
                .baselineOffset: lift,
            ]
        )
        let plain: [NSAttributedString.Key: Any] = [.font: italic, .foregroundColor: Palette.fg, .paragraphStyle: paragraph]
        guard let quote else {
            line.append(NSAttributedString(string: "original message unavailable", attributes: plain))
            return line
        }
        let marks: (String, String) = switch quote.type {
        case .action: ("* ", "")
        case .notice: ("-", "-")
        default: ("<", ">")
        }
        line.append(NSAttributedString(string: marks.0, attributes: plain))
        var nick = plain
        nick[.foregroundColor] = nickColor(quote.nick, isSelf: quote.isSelf)
        line.append(NSAttributedString(string: quote.nick, attributes: nick))
        line.append(NSAttributedString(string: marks.1 + " ", attributes: plain))
        if let source = quote.relaySource, !source.isEmpty {
            line.append(NSAttributedString(string: "[\(source)] ", attributes: plain))
        }
        line.append(NSAttributedString(string: Replies.excerpt(quote.text), attributes: plain))
        return line
    }

    /// What VoiceOver says for the quote.
    static func spokenReplyQuote(_ quote: ReplyQuote?) -> String {
        guard let quote else { return "In reply to a message that's unavailable" }
        return "In reply to \(quote.nick): \(Replies.excerpt(quote.text))"
    }
}

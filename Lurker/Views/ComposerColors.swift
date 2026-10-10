// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

extension NSAttributedString.Key {
    /// The mIRC slot (`Int`, 0–15) a stretch of composer text is coloured with. The slot is the
    /// truth and `.foregroundColor` only shows it: a colour can't be read back into a slot, and
    /// the slot is what `ColorMarkup` writes on the wire.
    static let ircForeground = NSAttributedString.Key("net.amiantos.lurker.ircForeground")
    /// The slot behind it — the run's own fill, shown as `.backgroundColor`.
    static let ircBackground = NSAttributedString.Key("net.amiantos.lurker.ircBackground")
}

/// Colour on composer text — the composer and the colour editor both keep it as attributes on
/// their text, and convert to and from `ColorSpan` at the edges (`ColorMarkup`).
enum ComposerColors {

    /// Which half of a colour pair a pick sets.
    enum Layer {
        case text
        case highlight
    }

    /// What uncoloured composer text is drawn with.
    static func plainAttributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor.label]
    }

    static func spans(of text: NSAttributedString) -> [ColorSpan] {
        var spans: [ColorSpan] = []
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            spans.append(ColorSpan(
                string.substring(with: range),
                fg: attributes[.ircForeground] as? Int,
                bg: attributes[.ircBackground] as? Int))
        }
        return spans
    }

    static func attributed(_ spans: [ColorSpan], font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            var attributes = plainAttributes(font: font)
            attributes = applying(span.fg, layer: .text, to: attributes)
            attributes = applying(span.bg, layer: .highlight, to: attributes)
            out.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        return out
    }

    /// The slot `attributes` give `layer`, nil for none.
    static func slot(_ layer: Layer, in attributes: [NSAttributedString.Key: Any]) -> Int? {
        attributes[layer == .text ? .ircForeground : .ircBackground] as? Int
    }

    /// `attributes` with `layer` set to `slot` (nil takes it off), the other half kept.
    static func applying(
        _ slot: Int?, layer: Layer, to attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var out = attributes
        let color = slot.flatMap(MessageRenderer.mircSlot)
        switch layer {
        case .text:
            out[.ircForeground] = color == nil ? nil : slot
            out[.foregroundColor] = color ?? UIColor.label
        case .highlight:
            out[.ircBackground] = color == nil ? nil : slot
            out[.backgroundColor] = color
        }
        return out
    }

    /// Set `layer` across `range` of `text`.
    static func apply(_ slot: Int?, layer: Layer, to range: NSRange, in text: NSMutableAttributedString) {
        guard range.length > 0 else { return }
        let color = slot.flatMap(MessageRenderer.mircSlot)
        let (key, visual): (NSAttributedString.Key, NSAttributedString.Key) =
            layer == .text ? (.ircForeground, .foregroundColor) : (.ircBackground, .backgroundColor)
        text.beginEditing()
        if let slot, let color {
            text.addAttribute(key, value: slot, range: range)
            text.addAttribute(visual, value: color, range: range)
        } else {
            text.removeAttribute(key, range: range)
            if layer == .text {
                text.addAttribute(visual, value: UIColor.label, range: range)
            } else {
                text.removeAttribute(visual, range: range)
            }
        }
        text.endEditing()
    }

    /// `text` in `font` throughout — the editor writes larger than the composer, and colour is
    /// the only styling either keeps.
    static func restyled(_ text: NSAttributedString, font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.addAttribute(.font, value: font, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The field's text for a line that came from outside it — a restored refusal, a synced
    /// draft. Colour the editor can hold becomes colour; anything else stays the raw line it
    /// always was, codes and all, so nothing written elsewhere is lost on the way through.
    static func attributed(line: String, font: UIFont) -> NSAttributedString {
        if let spans = ColorMarkup.decode(line), ColorMarkup.isColored(spans) {
            return attributed(spans, font: font)
        }
        return NSAttributedString(string: line, attributes: plainAttributes(font: font))
    }

    /// The draft `text` holds — colour written out, nothing else rewritten (`encodeDraft`).
    static func draft(_ text: NSAttributedString) -> String {
        let spans = spans(of: text)
        return ColorMarkup.isColored(spans) ? ColorMarkup.encodeDraft(spans) : text.string
    }

    /// The line `text` sends as (`encode`) — spoilers made, colour only on a chat body.
    static func wireLine(_ text: NSAttributedString) -> String {
        let spans = spans(of: text)
        return ColorMarkup.isColored(spans) ? ColorMarkup.encode(spans) : text.string
    }
}

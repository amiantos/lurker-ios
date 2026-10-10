// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Colour on composer text — the composer and the colour editor both keep it as attributes on
/// their text, and convert to and from `ColorSpan` at the edges (`ColorMarkup`).
///
/// ⚠⚠ The slot is read back from the VISIBLE colour — `.foregroundColor` / `.backgroundColor`
/// being one of the sixteen palette instances (`MessageRenderer.mircSlot`), compared by identity.
/// It used to ride a custom attribute key beside them, and UIKit drops custom keys: a text view
/// rebuilds its typing attributes from the previous character keeping only the keys it knows, so
/// after the first keystroke the text stayed red on screen while the slot was gone, and the
/// colour never reached the wire. Autocorrect's replace drops them too. The colour objects
/// themselves survive typing, replacement, reassignment and an appearance change (measured on
/// the simulator), so the one attribute is the whole truth and there's nothing to fall out of
/// step with it.
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
                fg: slot(.text, in: attributes),
                bg: slot(.highlight, in: attributes)))
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
        guard let color = attributes[layer == .text ? .foregroundColor : .backgroundColor] as? UIColor
        else { return nil }
        return (0..<16).first { MessageRenderer.mircSlot($0) === color }
    }

    /// Both halves at once — the colour a caret is typing in, as the composer and the editor
    /// hand it to each other.
    static func colors(in attributes: [NSAttributedString.Key: Any]) -> (fg: Int?, bg: Int?) {
        (slot(.text, in: attributes), slot(.highlight, in: attributes))
    }

    static func applying(
        _ colors: (fg: Int?, bg: Int?), to attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        applying(colors.bg, layer: .highlight, to: applying(colors.fg, layer: .text, to: attributes))
    }

    /// `attributes` with `layer` set to `slot` (nil takes it off), the other half kept.
    static func applying(
        _ slot: Int?, layer: Layer, to attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var out = attributes
        let color = slot.flatMap(MessageRenderer.mircSlot)
        switch layer {
        case .text: out[.foregroundColor] = color ?? UIColor.label
        case .highlight: out[.backgroundColor] = color
        }
        return out
    }

    /// Set `layer` across `range` of `text`.
    static func apply(_ slot: Int?, layer: Layer, to range: NSRange, in text: NSMutableAttributedString) {
        guard range.length > 0 else { return }
        let color = slot.flatMap(MessageRenderer.mircSlot)
        switch layer {
        case .text: text.addAttribute(.foregroundColor, value: color ?? UIColor.label, range: range)
        case .highlight:
            if let color {
                text.addAttribute(.backgroundColor, value: color, range: range)
            } else {
                text.removeAttribute(.backgroundColor, range: range)
            }
        }
    }

    /// `text` in `font` throughout — the editor writes larger than the composer, and colour is
    /// the only styling either keeps.
    static func restyled(_ text: NSAttributedString, font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.addAttribute(.font, value: font, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The field's text for a line that came from outside it — a restored refusal, a synced
    /// draft. What `ColorMarkup` can hold becomes colour (a lone reset reads as the plain text it
    /// shows); anything else stays the raw line it always was, codes and all, so nothing written
    /// elsewhere is lost or changed on the way through.
    static func attributed(line: String, font: UIFont) -> NSAttributedString {
        if let spans = ColorMarkup.decode(line) {
            return attributed(spans, font: font)
        }
        return NSAttributedString(string: line, attributes: plainAttributes(font: font))
    }

    /// The line `text` holds, syncs and sends — one format for all three (`ColorMarkup.encode`).
    static func line(_ text: NSAttributedString) -> String {
        let spans = spans(of: text)
        return ColorMarkup.isColored(spans) ? ColorMarkup.encode(spans) : text.string
    }
}

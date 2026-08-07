// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Lurker's own colors: the two built-in themes as the web client ships them — **Monokai Plus**
/// (dark) and **Monokai Plus Light** — from `shared/themePresets.ts`.
///
/// The app is otherwise a UIKit semantic-color app on purpose. This exists in two places only:
/// where a system color would be a lie about which signal is being shown (the status lights, the
/// connection banner), and on the message list, which is Lurker's canvas rather than the system's.
/// Chrome — the buffer list, settings, login — stays native, in both schemes.
///
/// ⚠ This is the two built-ins' *values*, not a theme engine. The web client points each scheme
/// at a theme the user can edit; iOS reads none of that, so a token here is always the built-in.
/// Keep them byte-identical to the presets: the same signal in both clients has to be the same
/// color, and the drift shows the moment you have both open.
///
/// The light column is the official Monokai Pro Light filter wherever it defines a value (every
/// accent clears WCAG 3:1 on its own background). `fgMuted` deliberately takes Pro Light's
/// *semi-muted* tier rather than its comment tier — the comment gray is 2.4:1 here, and this role
/// carries timestamps and system events, which need the dark theme's ~5:1.
enum Palette {

    // MARK: - Core palette

    /// `look.color.bg` — what the message list sits on, rather than the system's near-black or
    /// pure white. A dense monospaced log on pure black is all edge, and this charcoal is what
    /// the PWA has always shown on a phone, so the two clients look like the same product.
    nonisolated static let bg = dynamicHex(dark: "#212022", light: "#faf4f2")

    /// `look.color.fg` — text on `bg`. Not `.label`: that resolves to pure white / pure black,
    /// and the theme's foreground is a shade off each, which is what keeps the log from glaring.
    nonisolated static let fg = dynamicHex(dark: "#fcfcfa", light: "#29242a")

    /// `look.color.fg_muted` — timestamps, system events, secondary labels on `bg`.
    nonisolated static let fgMuted = dynamicHex(dark: "#939293", light: "#706b6e")

    // The rest of the web palette — `bg_soft` (#2c2a2e / #ede7e5) and `border`
    // (#38353b / #e0dad9) — is deliberately absent. Their roles are raised surfaces and region
    // separators, both of which are native chrome here, and a token nothing draws is a token
    // nobody keeps in sync.

    // MARK: - Signal colors

    /// `look.color.good` / `warn` / `bad`. `.systemGreen` / `.systemRed` are close but not these,
    /// and a status light that disagrees between clients is worse than one that's slightly off
    /// the platform palette.
    ///
    /// ⚠ The light column is *not* the dark hex — the dark pastels are tuned for a dark canvas
    /// and collapse on a light one (`#b3db82` is 1.6:1 on white, `#f9d978` is 1.4:1). Using one
    /// value for both is what made the connection spinner and the title-bar light vanish in light
    /// mode.
    nonisolated static let good = dynamicHex(dark: "#b3db82", light: "#269d69")
    nonisolated static let warn = dynamicHex(dark: "#f9d978", light: "#cc7a0a")
    nonisolated static let bad = dynamicHex(dark: "#ed6c89", light: "#e14775")

    static func color(for light: StatusLight) -> UIColor {
        switch light {
        case .good: good
        case .warn: warn
        case .bad: bad
        }
    }

    // MARK: - Member mode prefixes

    /// `look.color.member.*` — the ~ & @ % + glyphs in the member list. Same role pairing in both
    /// schemes (owner = red, admin = orange, op = the accent purple, half-op = cyan, voice =
    /// green), so a glance reads the same rank whichever way the phone is set.
    ///
    /// Only the *glyph* wears these, never the nick — the nick keeps its own hashed color, which
    /// is how the web draws it too.
    nonisolated static let memberOwner = dynamicHex(dark: "#ed6c89", light: "#e14775")
    nonisolated static let memberAdmin = dynamicHex(dark: "#fc9867", light: "#e16032")
    nonisolated static let memberOp = dynamicHex(dark: "#a99dec", light: "#7058be")
    nonisolated static let memberHalfop = dynamicHex(dark: "#78dce8", light: "#1c8ca8")
    nonisolated static let memberVoice = dynamicHex(dark: "#b3db82", light: "#269d69")

    /// The color for a `MemberPrefix.of(_:)` glyph, or `nil` for a member holding no mode — the
    /// caller leaves those in the ordinary text color rather than inventing a sixth rank.
    nonisolated static func memberPrefix(_ glyph: String) -> UIColor? {
        switch glyph {
        case "~": memberOwner
        case "&": memberAdmin
        case "@": memberOp
        case "%": memberHalfop
        case "+": memberVoice
        default: nil
        }
    }

    // MARK: - Derived

    /// The fill behind a line a highlight rule matched (#13). A warm wash of `warn` — the same
    /// gold the web tints `.line.highlight` with — rather than a solid fill, so the sender's mIRC
    /// colors and in-body nick colors still read over it. The web uses 12% (18% on its
    /// alt-striped rows); this list has no striping, so it sits between at one value.
    ///
    /// Built with `translucent(_:alpha:)` rather than `warn.withAlphaComponent(_:)`: the two
    /// schemes' `warn` are different hues, not one hue at two brightnesses, so this has to stay
    /// trait-keyed and the alpha has to land on whichever gold the scheme resolved.
    nonisolated static let highlightBubble = translucent(warn, alpha: 0.16)

    // MARK: - Building blocks

    /// A `UIColor` that resolves `dark` in dark mode and `light` in light mode.
    ///
    /// The palettes are fixed hex and each slot needs a different variant per scheme; a
    /// trait-keyed color then adapts everywhere it's drawn — captions, tokens, in-body mentions,
    /// a table's backdrop — with no work at the call site. (A *tinted image* does not get this
    /// for free: see `MessageRenderer.typingGlyph`.)
    nonisolated static func dynamicHex(dark: String, light: String) -> UIColor {
        guard let darkColor = UIColor(hex: dark), let lightColor = UIColor(hex: light) else {
            return .secondaryLabel
        }
        return UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor }
    }

    /// `base` at `alpha`, still trait-keyed.
    ///
    /// The alpha is applied to the color `base` resolves to for the traits being drawn with,
    /// which is the whole point: every token here has two *different* values, so a wash of one
    /// of them is only meaningful once you know which scheme is asking.
    nonisolated static func translucent(_ base: UIColor, alpha: CGFloat) -> UIColor {
        UIColor { traits in base.resolvedColor(with: traits).withAlphaComponent(alpha) }
    }
}

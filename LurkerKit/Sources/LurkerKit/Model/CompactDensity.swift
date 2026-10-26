// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// How tightly the compact layout sits: the three `look.message.compact.*` settings (lurker#1186,
/// Mobile lurker#1224), in the units the registry stores them in. Turning them into points is the
/// renderer's job, since that needs the font.
///
/// ⚠ Read as override → registry default. The web also consults the active theme in between, so a
/// density saved into a custom theme only reaches the phone once the apps resolve themes
/// (lurker#1094) — the same gap every other themed key has today.
public struct CompactDensity: Equatable, Sendable {
    /// Space before each block (a head line, an action, an event), in points. Rows within a run
    /// stay flush.
    public let groupGap: Int
    /// The line height, as a percentage of the font size.
    public let lineHeightPercent: Int
    /// How far a message body sits in from the nick above it, in characters.
    ///
    /// ⚠ The web ignores it while `look.message.avatars` is on, because the avatar gutter is the
    /// indent then. The apps draw no avatars yet, so they always apply it; lurker#1203 owes that
    /// rule.
    public let indent: Int

    public static let groupGapKey = "look.message.compact.group_gap"
    public static let lineHeightKey = "look.message.compact.line_height"
    public static let indentKey = "look.message.compact.indent"

    /// The registry's defaults.
    public static let standard = CompactDensity(groupGap: 10, lineHeightPercent: 155, indent: 1)

    public init(groupGap: Int, lineHeightPercent: Int, indent: Int) {
        // Clamped to the registry's ranges: the server enforces them on a write, but a stored
        // value from before a range tightened would otherwise lay out as whatever it says.
        self.groupGap = min(max(groupGap, 0), 48)
        self.lineHeightPercent = min(max(lineHeightPercent, 100), 250)
        self.indent = min(max(indent, 0), 8)
    }

    public init(settings: Settings) {
        self.init(
            groupGap: settings.int(Self.groupGapKey, default: Self.standard.groupGap),
            lineHeightPercent: settings.int(Self.lineHeightKey, default: Self.standard.lineHeightPercent),
            indent: settings.int(Self.indentKey, default: Self.standard.indent)
        )
    }
}

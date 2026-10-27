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
    /// Space between blocks, in points. The web puts it before each head line, action, notice,
    /// event and divider; iOS puts it after the block above, which is the same gap between two
    /// blocks, and gives a run of status events one gap rather than one each. Rows within a run
    /// stay flush.
    public let groupGap: Int
    /// The line height, as a percentage of the font size.
    public let lineHeightPercent: Int
    /// How far a message body sits in from the nick above it, in characters.
    ///
    /// ⚠ The web ignores it while `look.message.avatars` is on: beside the gutter's hairline any
    /// body indent reads as a stray margin, so the gutter is the indent and the setting does not
    /// apply (the registry greys it out, `dependsOn`). That rule is the LIST's, which draws the
    /// gutter — `flushBodies`, taken where the column is drawn — not this struct's: the history
    /// feed reads the same settings and draws no gutter (lurker#1203).
    public let indent: Int

    public static let groupGapKey = "look.message.compact.group_gap"
    public static let lineHeightKey = "look.message.compact.line_height"
    public static let indentKey = "look.message.compact.indent"
    /// The avatar column in the compact layout (lurker#607). Default off.
    public static let avatarsKey = "look.message.avatars"

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

    /// Whether the compact layout draws the avatar column (lurker#607).
    public static func avatarsOn(_ settings: Settings) -> Bool {
        settings.bool(avatarsKey, default: false)
    }

    /// This density with the body indent off — for a list drawing the avatar gutter, where the
    /// gutter is the indent. One place, so the body, the reply quote, the attachments and the
    /// reactions can't disagree about it.
    public var flushBodies: CompactDensity {
        CompactDensity(groupGap: groupGap, lineHeightPercent: lineHeightPercent, indent: 0)
    }
}

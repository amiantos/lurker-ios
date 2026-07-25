// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// How a buffer draws its messages.
///
/// The row *stream* is the same either way — `MessageRows` builds the dividers, the consolidation
/// and the run positions once, and a style only decides how a row becomes a cell. That's the whole
/// reason the actions sheet (#60) and the row builder live where they do: neither belongs to a
/// style, so adding one can't fork them.
///
/// **A style reaches the message list and nothing else.** The composer, the nav pill, the
/// connection banner, the floating jump pills and every sheet are one layer of glass above a list
/// that can be swapped out from under them — so a style owns cells and the gestures that only make
/// sense for its cells, and owns none of the chrome. A style that wanted to restyle the composer
/// would be the wrong shape for this seam.
public enum MessageListStyle: String, CaseIterable, Codable, Sendable {
    /// Chat bubbles, captioned once per run, with the timestamp parked off the right edge until
    /// the list is dragged. The default, and what the app shipped with.
    case bubbles
    /// A flat terminal feed — one full-width monospaced line per event, timestamp inline at the
    /// head of every one. No bubbles, no captions, no grouping: an irssi/weechat log, which is
    /// both denser and closer to what an IRC client has always looked like.
    case compact

    public var title: String {
        switch self {
        case .bubbles: "Bubbles"
        case .compact: "Compact"
        }
    }

    /// Whether the drag-to-reveal timestamp gesture makes sense here. It doesn't when every line
    /// already carries its time — and this is a property of the style rather than a setting on top
    /// of it, so "compact with a redundant reveal gesture" isn't a state anyone can get into.
    public var revealsTimestamps: Bool {
        switch self {
        case .bubbles: true
        case .compact: false
        }
    }
}

/// Which style each buffer uses: a default, plus per-buffer exceptions.
///
/// Modelled on setting a Finder folder's view: a buffer you've explicitly changed keeps its choice,
/// and "apply to all" both moves the default *and* clears the exceptions, so it means what it says
/// rather than "change everything except the ones you'd changed before".
///
/// Local to the device, like favorites — deliberately not a server setting and deliberately not
/// tied to the web client's `look.*` keys. How a phone draws a list is the phone's business.
public struct MessageListStylePreferences: Equatable, Codable, Sendable {
    /// The style for any buffer with no choice of its own.
    public private(set) var defaultStyle: MessageListStyle
    /// Buffer key (`BufferKey.id`) → the style that buffer was explicitly given.
    public private(set) var overrides: [String: MessageListStyle]

    public init(defaultStyle: MessageListStyle = .bubbles, overrides: [String: MessageListStyle] = [:]) {
        self.defaultStyle = defaultStyle
        self.overrides = overrides
    }

    public func style(for key: String) -> MessageListStyle {
        overrides[key] ?? defaultStyle
    }

    /// Give one buffer a style, leaving every other buffer alone.
    ///
    /// Choosing the current default still records an override. It's a real choice — "this one stays
    /// bubbles" — and dropping it would mean a later "apply Compact to all" silently took this
    /// buffer with it, which is exactly what the user just said they didn't want.
    public mutating func set(_ style: MessageListStyle, for key: String) {
        overrides[key] = style
    }

    /// Make `style` the default *and* forget every exception, so every buffer really is that style.
    public mutating func applyToAll(_ style: MessageListStyle) {
        defaultStyle = style
        overrides.removeAll()
    }
}

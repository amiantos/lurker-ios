// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which per-message action a descriptor stands for. The key is the identity; the descriptor
/// beside it is only how the action presents itself.
public enum MessageActionKey: String, Sendable {
    case reply
    case copy
}

/// One entry in a message's action menu.
///
/// A plain value with no closure in it, deliberately: the menu is rebuilt for whichever row the
/// finger landed on, and a descriptor that captured its own side effect would have to capture the
/// screen too. Side effects are dispatched through `MessageActions.run` with a context the caller
/// supplies instead — see `MessageActionContext`.
public struct MessageAction: Equatable, Sendable {
    public let key: MessageActionKey
    /// The menu row's title, already interpolated ("Reply to alice").
    public let title: String
    /// An SF Symbol name for the row's glyph.
    public let symbol: String
}

/// Where a message action's effects go. The two the caller owns are the two that touch the
/// platform: the composer, and the pasteboard.
///
/// This is what keeps the builder testable without a view controller, and it's why `run` lives
/// here rather than in the screen: a second message-list style gets the same menu, with the same
/// behaviour, by supplying its own context — neither style owns the actions.
public struct MessageActionContext {
    /// Address this nick in the composer — the reply gesture. Only called with a non-empty nick.
    public let reply: (String) -> Void
    /// Put this text on the pasteboard. The message's *raw* text, not the rendered form.
    public let copy: (String) -> Void

    public init(reply: @escaping (String) -> Void, copy: @escaping (String) -> Void) {
        self.reply = reply
        self.copy = copy
    }
}

/// The per-message actions a message list offers, and their effects (#60).
///
/// Mirrors the web client's `useMessageActions`, which splits the same problem the same way: a
/// pure builder returning descriptors, and a `run` that dispatches through a caller-supplied
/// context. Both clients therefore agree on *which* actions a given line offers.
///
/// Bookmark and Ignore are the web's other two and are deliberately absent: bookmarks need the
/// `set-bookmark`/`bookmark-ids-snapshot` protocol surface nothing here consumes yet, and Ignore
/// needs rule authoring, which belongs with the screen that applies rules.
///
/// One row still ends up with no menu and no selection: a consolidated summary, which stands for
/// a run of events rather than one message (`MessageRow.message` is nil for it). Its text is
/// synthesized at render time, so there is no raw string to copy — the same reason activity lines
/// get no Copy below.
public enum MessageActions {

    /// The actions for `message`, in menu order — empty when the line offers none.
    ///
    /// Gated per action rather than by one eligibility test, which is a deliberate divergence
    /// from the web's `eligibleForActions` (speech + a non-null id, for all four of its actions).
    /// Two reasons the web's gate doesn't transfer:
    ///
    ///  - **The id gate is Bookmark's**, and we don't ship Bookmark. Neither Reply nor Copy needs
    ///    the server to have heard of the line: one addresses a nick, the other reads a string.
    ///  - **On iOS the menu is the only way to copy at all.** The row menu takes the long press
    ///    away from the text-selection loupe (see `MessageTextView`), so a line with no menu is a
    ///    line whose text can't be copied — the web always has drag-select as a floor. Gating
    ///    Copy on speech would silently strand every MOTD, system and error line in the server
    ///    buffer, which is exactly the text people reach for.
    public static func build(for message: Message) -> [MessageAction] {
        var actions: [MessageAction] = []

        // Reply addresses someone, so it stays speech-only: narration names its actor inside the
        // sentence rather than speaking. Replying to yourself is meaningless, and a line with no
        // nick has nobody to address.
        if message.type.isSpeech, let nick = message.nick, !nick.isEmpty, !message.isSelf {
            actions.append(
                MessageAction(key: .reply, title: "Reply to \(nick)", symbol: "arrowshape.turn.up.left")
            )
        }

        // Copy wants lines whose `text` IS their content. That's everything that isn't activity
        // narration — speech and all the server's own output. An activity line synthesizes what
        // you see from structured fields and keeps only a fragment in `text` (a part reason, a
        // topic), so "Copy Text" on `alice left (brb)` would put `brb` on the pasteboard. Better
        // to offer nothing than to copy something other than the line you pressed.
        if !message.type.isActivity, let text = message.text, !text.isEmpty {
            actions.append(MessageAction(key: .copy, title: "Copy Text", symbol: "doc.on.doc"))
        }

        return actions
    }

    /// Perform `key` against `message`. A no-op when the message lacks what the action needs, so
    /// a menu built from a stale row can't fire an action on nothing.
    public static func run(_ key: MessageActionKey, on message: Message, context: MessageActionContext) {
        switch key {
        case .reply:
            guard let nick = message.nick, !nick.isEmpty else { return }
            context.reply(nick)
        case .copy:
            // The raw text, not the rendered attributed string: what gets pasted should be what
            // was typed — mIRC color codes and all — not this client's rendering of it.
            guard let text = message.text, !text.isEmpty else { return }
            context.copy(text)
        }
    }
}

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
public enum MessageActions {

    /// The actions for `message`, in menu order — empty when the line offers none.
    ///
    /// Eligibility matches the web's `eligibleForActions`: speech (a message, an action, or a
    /// notice) carrying a stable server id. Everything else is narration or furniture — a join,
    /// a topic change, a date divider — which there is nothing useful to do *to*. An id of 0 is
    /// this client's "no id": an ephemeral, locally synthesized line that the server has never
    /// heard of.
    public static func build(for message: Message) -> [MessageAction] {
        guard message.type.isSpeech, message.id > 0 else { return [] }
        var actions: [MessageAction] = []

        // Reply addresses someone. Replying to yourself is meaningless, and a line with no nick
        // has nobody to address.
        if let nick = message.nick, !nick.isEmpty, !message.isSelf {
            actions.append(
                MessageAction(key: .reply, title: "Reply to \(nick)", symbol: "arrowshape.turn.up.left")
            )
        }

        if let text = message.text, !text.isEmpty {
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

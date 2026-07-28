// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which per-message action a descriptor stands for. The key is the identity; the descriptor
/// beside it is only how the action presents itself.
public enum MessageActionKey: String, Sendable {
    case reply
    case copy
    case bookmark
    // A long press that lands on a link is about the link, not the line it's in — see
    // `MessageActions.build(for url:)`.
    case openLink
    case copyLink
    case shareLink
}

/// The two facts a message's menu needs that aren't on the message itself.
///
/// `Message` is what a buffer's log holds, so it carries no idea which buffer that is, and
/// bookmark state is account-wide rather than per-line. Both are the caller's to supply, and
/// bundling them keeps `build` and `run` from growing a parameter each.
public struct MessageActionScope: Equatable, Sendable {
    /// The network of the buffer the line is in. **Nil means the app-scoped system buffer**,
    /// which is what makes a line unbookmarkable — see the gate in `build`.
    public let networkId: Int?
    /// Whether this line is currently saved, from `ChatState.isBookmarked(_:)`.
    public let isBookmarked: Bool

    public init(networkId: Int?, isBookmarked: Bool) {
        self.networkId = networkId
        self.isBookmarked = isBookmarked
    }
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
    /// Toggle this message id's saved state. Called with the id only — the caller decides the
    /// direction from its own view of the store, so the sheet can't act on a stale reading.
    public let toggleBookmark: (Int) -> Void

    public init(
        reply: @escaping (String) -> Void,
        copy: @escaping (String) -> Void,
        toggleBookmark: @escaping (Int) -> Void
    ) {
        self.reply = reply
        self.copy = copy
        self.toggleBookmark = toggleBookmark
    }
}

/// Where a link action's effects go — all three are the platform's, none of them this package's.
public struct LinkActionContext {
    public let open: (URL) -> Void
    public let copy: (URL) -> Void
    public let share: (URL) -> Void

    public init(
        open: @escaping (URL) -> Void,
        copy: @escaping (URL) -> Void,
        share: @escaping (URL) -> Void
    ) {
        self.open = open
        self.copy = copy
        self.share = share
    }
}

/// The per-message actions a message list offers, and their effects (#60).
///
/// Mirrors the web client's `useMessageActions`, which splits the same problem the same way: a
/// pure builder returning descriptors, and a `run` that dispatches through a caller-supplied
/// context. Both clients therefore agree on *which* actions a given line offers.
///
/// Ignore is the web's fourth and is deliberately absent: it needs rule authoring, which belongs
/// with the screen that applies rules.
///
/// One row still ends up with no menu and no selection: a consolidated summary, which stands for
/// a run of events rather than one message (`MessageRow.message` is nil for it). Its text is
/// synthesized at render time, so there is no raw string to copy — the same reason activity lines
/// get no Copy below.
public enum MessageActions {

    /// The actions for `message`, in menu order — empty when the line offers none.
    ///
    /// Gated per action rather than by one eligibility test, which is a deliberate divergence
    /// from the web's `eligibleForActions` (speech + a non-null id, for all of its actions).
    /// Two reasons the web's gate doesn't transfer:
    ///
    ///  - **The id gate is Bookmark's alone.** Neither Reply nor Copy needs the server to have
    ///    heard of the line: one addresses a nick, the other reads a string.
    ///  - **On iOS the menu is the only way to copy at all.** The row menu takes the long press
    ///    away from the text-selection loupe (see `MessageTextView`), so a line with no menu is a
    ///    line whose text can't be copied — the web always has drag-select as a floor. Gating
    ///    Copy on speech would silently strand every MOTD, system and error line in the server
    ///    buffer, which is exactly the text people reach for.
    public static func build(for message: Message, scope: MessageActionScope) -> [MessageAction] {
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

        // Bookmarking needs content, a persisted line, and an owning network.
        //
        // The id gate is the ordinary one: `id == 0` is an ephemeral event the server has no
        // row for, so there's nothing to point a bookmark at.
        //
        // The network gate is less obvious and not cosmetic. Saving is ownership-checked
        // server-side by joining the message to its network, so a system-buffer line — which
        // is app-scoped and has none — can never be saved: the insert writes nothing and no
        // `bookmark-updated` comes back. Offering it there would be a row that does nothing,
        // every time, with no way to tell. It also keeps us from ever asking about a system
        // line's id, which matters because those come from a separate sequence that overlaps
        // the message ids the bookmark set is keyed by.
        //
        // Activity narration is excluded for the same reason it gets no Copy, and this is a
        // deliberate divergence from the web (which offers Save on anything with an id). A
        // join or a nick change isn't content — it's the churn the event-filter tier exists to
        // hide — and in the Bookmarks feed it would surface as a lone "alice joined" with
        // no conversation around it to explain why it was kept.
        if !message.type.isActivity, message.id != 0, scope.networkId != nil {
            actions.append(
                MessageAction(
                    key: .bookmark,
                    title: scope.isBookmarked ? "Remove Bookmark" : "Save Message",
                    symbol: scope.isBookmarked ? "bookmark.fill" : "bookmark"
                )
            )
        }

        return actions
    }

    /// The actions for a link, when the press landed on one rather than on the line around it.
    ///
    /// A fixed list — a URL is a URL, there's nothing to gate on. It's here beside the message
    /// actions rather than in the sheet that draws it for the same reason as the rest: the second
    /// message-list style should offer the same three things without either style deciding.
    public static func build(for url: URL) -> [MessageAction] {
        [
            MessageAction(key: .openLink, title: "Open Link", symbol: "safari"),
            MessageAction(key: .copyLink, title: "Copy Link", symbol: "doc.on.doc"),
            MessageAction(key: .shareLink, title: "Share Link", symbol: "square.and.arrow.up"),
        ]
    }

    /// Perform `key` against `url`. Keys that aren't a link's are ignored rather than trapped —
    /// the two menus are rendered by one screen, and a mismatch there is a bug in the caller, not
    /// something worth crashing a chat client over.
    public static func run(_ key: MessageActionKey, on url: URL, context: LinkActionContext) {
        switch key {
        case .openLink: context.open(url)
        case .copyLink: context.copy(url)
        case .shareLink: context.share(url)
        case .reply, .copy, .bookmark: break
        }
    }

    /// Perform `key` against `message`. A no-op unless `message` actually offers that action, so a
    /// menu built from a stale row can't fire an action the line doesn't have.
    ///
    /// The gate is `build`'s own answer rather than a restatement of its conditions. Restating them
    /// is how the two drift: Reply here used to require only a nick, so it would have addressed a
    /// *self* message or a server line — cases `build` rules out — and Copy would have pasted the
    /// fragment in an activity line's `text` ("brb" from `alice left (brb)`). Neither was reachable
    /// through the sheet, which offers only what `build` returned, but "unavailable actions are
    /// no-ops" is the guarantee this function documents, and it wasn't true.
    public static func run(
        _ key: MessageActionKey,
        on message: Message,
        scope: MessageActionScope,
        context: MessageActionContext
    ) {
        guard build(for: message, scope: scope).contains(where: { $0.key == key }) else { return }
        switch key {
        case .reply:
            guard let nick = message.nick, !nick.isEmpty else { return }
            context.reply(nick)
        case .copy:
            // The raw text, not the rendered attributed string: what gets pasted should be what
            // was typed — mIRC color codes and all — not this client's rendering of it.
            guard let text = message.text, !text.isEmpty else { return }
            context.copy(text)
        case .bookmark:
            // The id only. Which way to toggle is the caller's to decide against the store, so
            // a sheet built before an echo landed can't push the state backwards.
            context.toggleBookmark(message.id)
        case .openLink, .copyLink, .shareLink:
            // A link's keys, dispatched by the `URL` overload. Ignored rather than trapped: one
            // screen renders both menus, and a mismatch is a caller bug, not a reason to crash.
            break
        }
    }
}

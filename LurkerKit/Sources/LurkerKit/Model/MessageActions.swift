// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which per-message action a descriptor stands for. The key is the identity; the descriptor
/// beside it is only how the action presents itself.
public enum MessageActionKey: String, Sendable {
    case reply
    case copy
    case bookmark
    /// Open the profile of the person the line is *from* (#12) — which on a re-attributed
    /// relay line is the bridge, not the speaker. See `profileSubject`.
    case profile
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
    /// Set this message id's saved state. The DIRECTION is passed, not a toggle: it comes
    /// from the same `MessageActionScope` that produced the menu's label, so what fires is
    /// always what the row the user tapped said it would do.
    public let setBookmark: (Int, Bool) -> Void
    /// Open a profile for this nick. Only called with a nick that has an IRC presence — see
    /// `profileSubject`.
    public let showProfile: (String) -> Void

    public init(
        reply: @escaping (String) -> Void,
        copy: @escaping (String) -> Void,
        setBookmark: @escaping (Int, Bool) -> Void,
        showProfile: @escaping (String) -> Void
    ) {
        self.reply = reply
        self.copy = copy
        self.setBookmark = setBookmark
        self.showProfile = showProfile
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

        // Bookmarking needs speech, a persisted line, and an owning network.
        //
        // **Speech is where this client stops diverging from the web.** The web gates its
        // entire action surface on `eligibleForActions` — message/action/notice — so MOTD,
        // system and error lines offer nothing there at all. Copy above deliberately breaks
        // that gate, and has a reason to: on iOS this menu is the only way to copy anything,
        // and the server buffer's text is exactly what people reach for. Bookmark has no such
        // excuse. The feed is for things people said; a saved MOTD or connection error is a
        // slice of log with no conversation in it. So it follows the web's rule instead.
        //
        // (Speech also excludes activity narration, which would otherwise surface in the feed
        // as a lone "alice joined" with nothing around it to say why it was kept.)
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
        if message.type.isSpeech, message.id != 0, scope.networkId != nil {
            actions.append(
                MessageAction(
                    key: .bookmark,
                    title: scope.isBookmarked ? "Remove Bookmark" : "Save Message",
                    symbol: scope.isBookmarked ? "bookmark.fill" : "bookmark"
                )
            )
        }

        // Profile — whois, their note, and the way to DM them.
        //
        // ⚠⚠ The subject is `profileSubject`, NOT `message.nick`. On a relay-re-attributed
        // line those differ, and the nick on screen is a person on Discord or Matrix with no
        // IRC presence at all: a whois for them answers "not_found" every time. The action
        // sheet's header already draws this distinction ("alice via relaybot") on the grounds
        // that the bot is the only thing there with an IRC presence, and this follows it.
        //
        // The title names whoever that turns out to be, so a relayed line offers "Profile of
        // relaybot" under a header reading "alice via relaybot" — which is the honest offer,
        // and legible next to it.
        //
        // ⚠ Speech OR activity, which is a narrower gate than "has a nick" and has to be.
        // Server text carries a nick-shaped field that is not a person — a MOTD's is the
        // server itself — so a bare nick check offers "Profile of irc.example.org", a whois
        // for a hostname. The two categories here are exactly the lines whose nick is a USER.
        //
        // Activity is deliberately included, unlike Reply/Copy/Bookmark above. Each of those
        // has its own reason to skip narration — you can't address a sentence, its `text` is a
        // fragment, churn isn't content — and none of them is a reason to refuse "who is that",
        // which is a perfectly ordinary thing to ask about a nick you just watched join.
        //
        // Not gated on self: your own whois is how you check your host and modes. The network
        // gate is real though — a system-buffer line has no connection to ask on.
        if scope.networkId != nil,
           message.type.isSpeech || message.type.isActivity,
           let subject = profileSubject(of: message) {
            actions.append(
                MessageAction(
                    key: .profile,
                    title: "Profile of \(subject)",
                    symbol: "person.crop.circle"
                )
            )
        }

        return actions
    }

    /// The nick on a line that actually has an IRC presence, or nil when there is none.
    ///
    /// A relay bot's re-attributed line shows the embedded speaker as its author, but that
    /// person exists on the far side of a bridge — the bot is the IRC entity. Anything that
    /// addresses the *network* about a line therefore has to ask about the bot.
    public static func profileSubject(of message: Message) -> String? {
        if let bot = message.relayBot, !bot.isEmpty { return bot }
        guard let nick = message.nick, !nick.isEmpty else { return nil }
        return nick
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
        case .reply, .copy, .bookmark, .profile: break
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
            // The direction comes from `scope`, which is also what titled the row — so a
            // sheet built before a `bookmark-updated` echo landed still does the thing it
            // offered. Re-reading the store here instead would invert the button under the
            // user: the row says "Save Message" and an unsave goes out.
            context.setBookmark(message.id, !scope.isBookmarked)
        case .profile:
            // `build` already refused a line with no IRC subject, and this re-derives from the
            // same function rather than restating its rule — the drift `run`'s own gate exists
            // to prevent.
            guard let subject = profileSubject(of: message) else { return }
            context.showProfile(subject)
        case .openLink, .copyLink, .shareLink:
            // A link's keys, dispatched by the `URL` overload. Ignored rather than trapped: one
            // screen renders both menus, and a mismatch is a caller bug, not a reason to crash.
            break
        }
    }
}

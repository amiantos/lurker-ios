// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// Which actions a message offers, and what running one does (#60).
///
/// The eligibility rules are the point: they decide whether a long press on a given row does
/// anything at all, and getting one wrong is quiet — an action bar offering Reply on a join line,
/// or a message that silently refuses to open a menu, both look like plausible behaviour.
final class MessageActionsTests: XCTestCase {

    private func msg(
        id: Int = 1,
        type: EventType = .message,
        nick: String? = "alice",
        text: String? = "hello",
        isSelf: Bool = false
    ) -> Message {
        Message(id: id, type: type, nick: nick, text: text, isSelf: isSelf)
    }

    // MARK: - Eligibility

    func testSpeechOffersReplyCopyBookmark() {
        let actions = build(msg())
        XCTAssertEqual(actions.map(\.key), [.reply, .copy, .bookmark, .profile])
        XCTAssertEqual(actions.first?.title, "Reply to alice")
    }

    /// Notices and `/me` actions are speech too, so they carry the same menu — a notice bubbles
    /// and an action renders as a full-width line, but that's a layout difference, not a
    /// difference in what you can do with them.
    func testNoticeAndActionAreEligible() {
        XCTAssertEqual(build(msg(type: .notice)).map(\.key), [.reply, .copy, .bookmark, .profile])
        XCTAssertEqual(build(msg(type: .action)).map(\.key), [.reply, .copy, .bookmark, .profile])
    }

    /// The server's own output — MOTD, system, error — is not speech, so no Reply. But it is the
    /// text people most often want off the screen, and on iOS this menu is the only way to get it
    /// (the row menu took the long press from the selection loupe), so Copy has to be there.
    ///
    /// Copy is the ONLY thing that divergence buys. Bookmark keeps the web's speech gate: the
    /// feed is for things people said, not for a saved MOTD or connection error.
    ///
    /// ⚠ Profile is out too, and this is the case that decides its gate. These lines carry a
    /// nick-shaped field that is not a person — a MOTD's is the server — so gating Profile on
    /// "has a nick" would offer a whois for a hostname. Note the fixture gives every type the
    /// nick `alice`, which is exactly why the gate can't be about whether one is there.
    func testServerTextOffersCopyOnly() {
        for type: EventType in [.system, .motd, .error, .ctcp, .e2e, .other] {
            XCTAssertEqual(
                build(msg(type: type, text: "something")).map(\.key), [.copy],
                "\(type) should offer Copy and nothing else"
            )
        }
    }

    /// A NOTICE is speech, so it stays bookmarkable even though it's most often seen in a
    /// server buffer — matching the web, whose gate is the message type and not the buffer.
    func testNoticeStaysBookmarkable() {
        XCTAssertEqual(build(msg(type: .notice)).map(\.key), [.reply, .copy, .bookmark, .profile])
    }

    /// Activity narration offers Profile and nothing else.
    ///
    /// The three it still refuses each have their own reason, and none of them generalises to
    /// "narration is inert": you can't address a sentence (Reply), its `text` is a fragment of
    /// what's on screen so Copy would paste something other than the pressed line, and churn
    /// isn't content so one saved "alice joined" says nothing on its own.
    ///
    /// Profile has no such reason (#12). The nick in a join or a kick is a real person on this
    /// network, and "who is that" is exactly what you want to ask about a nick you just watched
    /// arrive — which used to be a line you could not interact with at all.
    func testActivityNarrationOffersOnlyProfile() {
        for type: EventType in [.join, .part, .quit, .nick, .kick, .mode, .topic, .invite, .chghost] {
            XCTAssertEqual(
                build(msg(type: type, text: "brb")).map(\.key), [.profile],
                "\(type) should offer Profile and nothing else"
            )
        }
    }

    /// Id 0 is this client's "no id" — an ephemeral, locally synthesized line. The server having
    /// never heard of it doesn't make its text less copyable, so Reply and Copy stay. Bookmark is
    /// the one that genuinely needs the id, and it's the one that drops.
    func testEphemeralLineStillOffersCopy() {
        XCTAssertEqual(build(msg(id: 0)).map(\.key), [.reply, .copy, .profile])
        XCTAssertEqual(build(msg(id: 0, type: .system, nick: nil)).map(\.key), [.copy])
    }

    // MARK: - Profile (#12)

    func testProfileNamesWhoItWillLookUp() {
        // The title carries the subject because on a relayed line it is not the nick on
        // screen — see below. Naming it always keeps the two cases reading the same way.
        XCTAssertEqual(
            build(msg()).first(where: { $0.key == .profile })?.title,
            "Profile of alice"
        )
    }

    func testProfileNeedsANetworkToAskOn() {
        // A system-buffer line is app-scoped and has no connection; a whois there has nowhere
        // to go. Same gate Bookmark needs, for a different reason.
        let actions = MessageActions.build(
            for: msg(), scope: MessageActionScope(networkId: nil, isBookmarked: false)
        )
        XCTAssertFalse(actions.contains { $0.key == .profile })
    }

    func testProfileNeedsANick() {
        XCTAssertFalse(build(msg(nick: nil)).contains { $0.key == .profile })
        XCTAssertFalse(build(msg(nick: "")).contains { $0.key == .profile })
    }

    func testYourOwnLineStillOffersAProfile() {
        // Unlike Reply. Your own whois is how you check your host and your modes.
        XCTAssertTrue(build(msg(isSelf: true)).contains { $0.key == .profile })
    }

    func testARelayedLineProfilesTheBridgeNotTheSpeaker() {
        // ⚠⚠ On a re-attributed line the nick on screen is somebody on the far side of a
        // bridge, with no IRC presence at all — a whois for them answers `not_found` every
        // time. The bot is the only thing here the network has heard of, which is the same
        // rule the action sheet's own header follows ("alice via relaybot").
        let relayed = msg(nick: "relaybot", text: "<alice> hi")
            .relayed(to: "alice", text: "hi", via: "relaybot", source: "Discord")
        XCTAssertEqual(MessageActions.profileSubject(of: relayed), "relaybot")
        // And the title says so, so the offer is legible beside a row that reads "alice".
        XCTAssertEqual(
            build(relayed).first(where: { $0.key == .profile })?.title,
            "Profile of relaybot"
        )
    }

    func testRunningProfileHandsBackTheBridgeToo() {
        let relayed = msg(nick: "relaybot", text: "<alice> hi")
            .relayed(to: "alice", text: "hi", via: "relaybot", source: nil)
        var asked: String?
        run(.profile, on: relayed, context: context(
            showProfile: { asked = $0 }
        ))
        XCTAssertEqual(asked, "relaybot")
    }

    func testANickChangeProfilesTheNewNameNotTheOldOne() {
        // ⚠⚠ A nick line's `nick` is what the sentence is ABOUT, not who is there now. Asking
        // the network about it answers `not_found` every time, so the profile would report
        // "bob isn't on this network" about somebody standing right there as bob_afk.
        let renamed = Message(id: 1, type: .nick, nick: "bob", text: nil, newNick: "bob_afk")
        XCTAssertEqual(MessageActions.profileSubject(of: renamed), "bob_afk")
        XCTAssertEqual(
            MessageActions.build(for: renamed, scope: scope())
                .first(where: { $0.key == .profile })?.title,
            "Profile of bob_afk"
        )
    }

    func testANickChangeWithNoNewNameFallsBackToTheOldOne() {
        // A malformed frame shouldn't cost the row entirely — the old nick is still the best
        // guess about who the line is about.
        let renamed = Message(id: 1, type: .nick, nick: "bob", text: nil)
        XCTAssertEqual(MessageActions.profileSubject(of: renamed), "bob")
    }

    func testProfileIsANoOpOnALineThatDoesNotOfferIt() {
        // `run`'s standing guarantee: an action the line doesn't have does nothing. A MOTD
        // carries a nick-shaped field, so without the gate this would whois a server.
        run(.profile, on: msg(type: .motd), context: context())
    }

    // MARK: - Per-action gating

    func testOwnMessageOffersNoReply() {
        XCTAssertEqual(build(msg(isSelf: true)).map(\.key), [.copy, .bookmark, .profile])
    }

    func testNicklessMessageOffersNoReply() {
        XCTAssertEqual(build(msg(nick: nil)).map(\.key), [.copy, .bookmark])
        XCTAssertEqual(build(msg(nick: "")).map(\.key), [.copy, .bookmark])
    }

    /// An upload with no caption, say: nothing to put on the pasteboard, but still someone to
    /// reply to and still a line worth keeping.
    func testTextlessMessageOffersNoCopy() {
        XCTAssertEqual(build(msg(text: nil)).map(\.key), [.reply, .bookmark, .profile])
        XCTAssertEqual(build(msg(text: "")).map(\.key), [.reply, .bookmark, .profile])
    }

    // MARK: - Running

    func testReplyHandsBackTheNick() {
        var replied: [String] = []
        run(.reply, on: msg(), context: context(reply: { replied.append($0) }))
        XCTAssertEqual(replied, ["alice"])
    }

    /// The raw text, not a rendering of it: what gets pasted should be what was typed, mIRC
    /// color codes included.
    func testCopyHandsBackTheRawText() {
        var copied: [String] = []
        let raw = "\u{03}04red\u{03} and https://example.com"
        run(.copy, on: msg(text: raw), context: context(copy: { copied.append($0) }))
        XCTAssertEqual(copied, [raw])
    }

    /// A menu built from a row that has since changed underneath it can't fire an action on
    /// nothing.
    func testRunningAnUnavailableActionDoesNothing() {
        var fired = 0
        let ctx = context(reply: { _ in fired += 1 }, copy: { _ in fired += 1 })
        run(.reply, on: msg(nick: nil), context: ctx)
        run(.copy, on: msg(text: ""), context: ctx)
        XCTAssertEqual(fired, 0)
    }

    /// `run` gates on exactly what `build` offers, not on a looser restatement of it. Each of these
    /// has the field the action needs — a nick, some text — but isn't offered the action, so
    /// running it anyway would reply to yourself, reply to a server line, or paste the fragment out
    /// of an activity line ("brb" from `alice left (brb)`).
    func testRunEnforcesTheSameGateAsBuild() {
        var fired = 0
        let ctx = context(reply: { _ in fired += 1 }, copy: { _ in fired += 1 })

        run(.reply, on: msg(isSelf: true), context: ctx)
        run(.reply, on: msg(type: .motd), context: ctx)
        run(.reply, on: msg(type: .part, text: "brb"), context: ctx)
        run(.copy, on: msg(type: .part, text: "brb"), context: ctx)
        XCTAssertEqual(fired, 0)

        // …and still runs the ones that ARE offered, so the gate isn't just refusing everything.
        run(.reply, on: msg(), context: ctx)
        run(.copy, on: msg(), context: ctx)
        XCTAssertEqual(fired, 2)
    }

    // MARK: - Links

    /// A URL is a URL — nothing to gate on, so the list is fixed.
    func testLinkOffersOpenCopyShare() {
        let actions = MessageActions.build(for: URL(string: "https://example.com")!)
        XCTAssertEqual(actions.map(\.key), [.openLink, .copyLink, .shareLink])
        XCTAssertEqual(actions.map(\.title), ["Open Link", "Copy Link", "Share Link"])
    }

    func testLinkActionsDispatchToTheirHandlers() {
        let url = URL(string: "https://example.com/thing")!
        var opened: [URL] = [], copied: [URL] = [], shared: [URL] = []
        let ctx = LinkActionContext(
            open: { opened.append($0) }, copy: { copied.append($0) }, share: { shared.append($0) }
        )
        MessageActions.run(.openLink, on: url, context: ctx)
        MessageActions.run(.copyLink, on: url, context: ctx)
        MessageActions.run(.shareLink, on: url, context: ctx)
        XCTAssertEqual(opened, [url])
        XCTAssertEqual(copied, [url])
        XCTAssertEqual(shared, [url])
    }

    /// One screen renders both menus, so each dispatcher has to ignore the other's keys rather
    /// than trap on them.
    func testKeysFromTheOtherMenuAreIgnored() {
        let url = URL(string: "https://example.com")!
        let linkContext = LinkActionContext(
            open: { _ in XCTFail("unexpected open") },
            copy: { _ in XCTFail("unexpected copy") },
            share: { _ in XCTFail("unexpected share") }
        )
        MessageActions.run(.reply, on: url, context: linkContext)
        MessageActions.run(.copy, on: url, context: linkContext)

        for key: MessageActionKey in [.openLink, .copyLink, .shareLink] {
            run(key, on: msg(), context: context())
        }
    }

    // MARK: - Bookmark

    /// The network gate. A system-buffer line is app-scoped, and the server refuses to bookmark
    /// one — the ownership check joins through networks, which it has none of, so the insert
    /// writes nothing and no echo comes back. Offering Save there would be a permanent silent
    /// no-op, so it isn't offered.
    func testSystemBufferLineOffersNoBookmark() {
        let scope = MessageActionScope(networkId: nil, isBookmarked: false)
        XCTAssertEqual(MessageActions.build(for: msg(), scope: scope).map(\.key), [.reply, .copy])
        XCTAssertEqual(
            MessageActions.build(for: msg(type: .system, nick: nil), scope: scope).map(\.key), [.copy]
        )
    }

    /// The label and glyph are the only thing that changes with saved state — the action is in
    /// the same place either way, so the row doesn't move under a thumb that's already reaching.
    func testBookmarkLabelReflectsSavedState() {
        let saved = build(msg(), isBookmarked: true).first { $0.key == .bookmark }
        XCTAssertEqual(saved?.title, "Remove Bookmark")
        XCTAssertEqual(saved?.symbol, "bookmark.fill")

        let unsaved = build(msg()).first { $0.key == .bookmark }
        XCTAssertEqual(unsaved?.title, "Save Message")
        XCTAssertEqual(unsaved?.symbol, "bookmark")
    }

    /// The direction comes from the scope that titled the row, NOT from a re-read — so a sheet
    /// built before an echo landed still does what it said it would, rather than inverting
    /// under the user.
    func testBookmarkSendsTheDirectionItsLabelPromised() {
        var calls: [(Int, Bool)] = []
        let ctx = context(setBookmark: { calls.append(($0, $1)) })

        // Row read "Save Message" → a save goes out.
        MessageActions.run(
            .bookmark, on: msg(id: 77),
            scope: MessageActionScope(networkId: 1, isBookmarked: false), context: ctx
        )
        // Row read "Remove Bookmark" → an unsave does.
        MessageActions.run(
            .bookmark, on: msg(id: 77),
            scope: MessageActionScope(networkId: 1, isBookmarked: true), context: ctx
        )

        XCTAssertEqual(calls.map(\.0), [77, 77])
        XCTAssertEqual(calls.map(\.1), [true, false])
    }

    /// `run` gates on what `build` offers, so the two unbookmarkable cases can't fire it even if
    /// a stale sheet asks.
    func testRunningBookmarkOnAnIneligibleLineDoesNothing() {
        var fired = 0
        let ctx = context(setBookmark: { _, _ in fired += 1 })
        // No network (system buffer), no id (ephemeral), narration, and server output —
        // the four ways a line fails the gate.
        MessageActions.run(
            .bookmark, on: msg(),
            scope: MessageActionScope(networkId: nil, isBookmarked: false), context: ctx
        )
        run(.bookmark, on: msg(id: 0), context: ctx)
        run(.bookmark, on: msg(type: .join, text: nil), context: ctx)
        run(.bookmark, on: msg(type: .motd), context: ctx)
        XCTAssertEqual(fired, 0)
    }

    // MARK: - Helpers

    /// The default scope: a real network, nothing saved. The bookmark-specific cases pass their
    /// own.
    private func scope(isBookmarked: Bool = false) -> MessageActionScope {
        MessageActionScope(networkId: 1, isBookmarked: isBookmarked)
    }

    private func build(_ message: Message, isBookmarked: Bool = false) -> [MessageAction] {
        MessageActions.build(for: message, scope: scope(isBookmarked: isBookmarked))
    }

    private func run(_ key: MessageActionKey, on message: Message, context ctx: MessageActionContext) {
        MessageActions.run(key, on: message, scope: scope(), context: ctx)
    }

    private func context(
        reply: @escaping (String) -> Void = { nick in XCTFail("unexpected reply: \(nick)") },
        copy: @escaping (String) -> Void = { text in XCTFail("unexpected copy: \(text)") },
        setBookmark: @escaping (Int, Bool) -> Void = { id, saved in
            XCTFail("unexpected bookmark: \(id) saved=\(saved)")
        },
        showProfile: @escaping (String) -> Void = { nick in
            XCTFail("unexpected profile: \(nick)")
        }
    ) -> MessageActionContext {
        MessageActionContext(
            reply: reply, copy: copy, setBookmark: setBookmark, showProfile: showProfile
        )
    }
}

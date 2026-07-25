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

    func testSpeechOffersReplyThenCopy() {
        let actions = MessageActions.build(for: msg())
        XCTAssertEqual(actions.map(\.key), [.reply, .copy])
        XCTAssertEqual(actions.first?.title, "Reply to alice")
    }

    /// Notices and `/me` actions are speech too, so they carry the same menu — a notice bubbles
    /// and an action renders as a full-width line, but that's a layout difference, not a
    /// difference in what you can do with them.
    func testNoticeAndActionAreEligible() {
        XCTAssertEqual(MessageActions.build(for: msg(type: .notice)).map(\.key), [.reply, .copy])
        XCTAssertEqual(MessageActions.build(for: msg(type: .action)).map(\.key), [.reply, .copy])
    }

    /// The server's own output — MOTD, system, error — is not speech, so no Reply. But it is the
    /// text people most often want off the screen, and on iOS this menu is the only way to get it
    /// (the row menu took the long press from the selection loupe), so Copy has to be there.
    func testServerTextOffersCopyOnly() {
        for type: EventType in [.system, .motd, .error, .ctcp, .e2e, .other] {
            XCTAssertEqual(
                MessageActions.build(for: msg(type: type, text: "something")).map(\.key), [.copy],
                "\(type) should offer Copy"
            )
        }
    }

    /// Activity narration offers nothing. Its `text` is a fragment of what's on screen — a part
    /// reason, a topic — because the line is synthesized from structured fields, so Copy would put
    /// something other than the pressed line on the pasteboard.
    func testActivityNarrationOffersNothing() {
        for type: EventType in [.join, .part, .quit, .nick, .kick, .mode, .topic, .invite, .chghost] {
            XCTAssertTrue(
                MessageActions.build(for: msg(type: type, text: "brb")).isEmpty,
                "\(type) should offer no actions"
            )
        }
    }

    /// Id 0 is this client's "no id" — an ephemeral, locally synthesized line. The server having
    /// never heard of it doesn't make its text less copyable; the web's id gate belongs to
    /// Bookmark, which this doesn't ship.
    func testEphemeralLineStillOffersCopy() {
        XCTAssertEqual(MessageActions.build(for: msg(id: 0)).map(\.key), [.reply, .copy])
        XCTAssertEqual(MessageActions.build(for: msg(id: 0, type: .system, nick: nil)).map(\.key), [.copy])
    }

    // MARK: - Per-action gating

    func testOwnMessageOffersCopyOnly() {
        XCTAssertEqual(MessageActions.build(for: msg(isSelf: true)).map(\.key), [.copy])
    }

    func testNicklessMessageOffersCopyOnly() {
        XCTAssertEqual(MessageActions.build(for: msg(nick: nil)).map(\.key), [.copy])
        XCTAssertEqual(MessageActions.build(for: msg(nick: "")).map(\.key), [.copy])
    }

    /// An upload with no caption, say: nothing to put on the pasteboard, but still someone to
    /// reply to.
    func testTextlessMessageOffersReplyOnly() {
        XCTAssertEqual(MessageActions.build(for: msg(text: nil)).map(\.key), [.reply])
        XCTAssertEqual(MessageActions.build(for: msg(text: "")).map(\.key), [.reply])
    }

    // MARK: - Running

    func testReplyHandsBackTheNick() {
        var replied: [String] = []
        MessageActions.run(.reply, on: msg(), context: context(reply: { replied.append($0) }))
        XCTAssertEqual(replied, ["alice"])
    }

    /// The raw text, not a rendering of it: what gets pasted should be what was typed, mIRC
    /// color codes included.
    func testCopyHandsBackTheRawText() {
        var copied: [String] = []
        let raw = "\u{03}04red\u{03} and https://example.com"
        MessageActions.run(.copy, on: msg(text: raw), context: context(copy: { copied.append($0) }))
        XCTAssertEqual(copied, [raw])
    }

    /// A menu built from a row that has since changed underneath it can't fire an action on
    /// nothing.
    func testRunningAnUnavailableActionDoesNothing() {
        var fired = 0
        let ctx = context(reply: { _ in fired += 1 }, copy: { _ in fired += 1 })
        MessageActions.run(.reply, on: msg(nick: nil), context: ctx)
        MessageActions.run(.copy, on: msg(text: ""), context: ctx)
        XCTAssertEqual(fired, 0)
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
            MessageActions.run(key, on: msg(), context: context())
        }
    }

    private func context(
        reply: @escaping (String) -> Void = { nick in XCTFail("unexpected reply: \(nick)") },
        copy: @escaping (String) -> Void = { text in XCTFail("unexpected copy: \(text)") }
    ) -> MessageActionContext {
        MessageActionContext(reply: reply, copy: copy)
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Writes made with no socket (the client sweep's offline-writes batch, L02/L14/L16/L29). Nothing
/// queues a verb behind a dropped socket, so each of these has to say it went nowhere — a command
/// comes back to the composer, a close leaves its row — rather than looking like it worked.
///
/// No test has a socket, so every send here goes nowhere. A socket that has ended answers the same
/// false (`LurkerClient.socketEnded`) until the reconnect replaces it, which is the window
/// "Reconnecting…" shows; one that has died without saying so can't be told from a live one, and
/// the screens gate on both connection signals for that.
@MainActor
final class OfflineWritesTests: XCTestCase {

    private let channel = BufferKey(networkId: 1, target: "#lurker")

    /// Its own Keychain service and its own defaults suite, so nothing here touches the app's.
    /// Seeded with one network and one channel, as the last snapshot left them.
    private func viewModel() -> ChatViewModel {
        let model = ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.offlinewrites"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.offlinewrites")!)
        )
        model.handle(.socketOpen)
        model.handle(.snapshot(
            [NetworkSnapshot(
                id: 1, state: .connected, nick: "me",
                channels: [ChannelSnapshot(name: "#lurker", topic: nil, members: [])]
            )],
            globalIgnores: [], uploadLimits: .unstated
        ))
        return model
    }

    /// L02: every command with a wire verb comes back to the composer, not only the ones that
    /// carry a message. Before, `/topic`, `/nick`, `/part` and the rest were cleared and lost.
    func testEveryWireCommandTypedOfflineComesBack() {
        for line in [
            "/topic a new topic", "/nick someoneelse", "/ns identify hunter2", "/kick bob",
            "/quote PING x", "/part", "/close", "/clear", "/away brb", "/back", "/ctcp bob VERSION",
        ] {
            let model = viewModel()
            model.send(channel, text: line)
            XCTAssertEqual(model.takeUnsent(channel)?.text, line, "\(line) went nowhere and must come back")
        }
    }

    /// A write that would go out is still refused when it couldn't reach the server: a reconnect's
    /// socket that hasn't opened (it takes writes before its upgrade, and loses them if the
    /// attempt fails), or a device with no path while the old socket still reads connected.
    /// `/msg` goes through the seam, which says "sent", so only the gate can hand it back.
    func testAWriteThatWouldGoOutWaitsForTheConnection() {
        let unopened = ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.offlinewrites"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.offlinewrites")!)
        )
        unopened.sendMessageSeam = { _, _ in true }
        unopened.send(channel, text: "/msg bob hi")
        XCTAssertEqual(unopened.takeUnsent(channel)?.text, "/msg bob hi", "the socket hasn't opened")

        let unreachable = viewModel()
        unreachable.sendMessageSeam = { _, _ in true }
        unreachable.setReachable(false)
        unreachable.send(channel, text: "/msg bob hi")
        XCTAssertEqual(unreachable.takeUnsent(channel)?.text, "/msg bob hi", "the device has no path")

        let online = viewModel()
        online.sendMessageSeam = { _, _ in true }
        online.send(channel, text: "/msg bob hi")
        XCTAssertNil(online.takeUnsent(channel), "connected and reachable: it went")
    }

    /// A forced reconnect — the foreground's stale-socket check — replaces the socket while the
    /// state still reads `.connected`. The new socket takes writes during its upgrade and loses them
    /// if the attempt fails, so the user's writes wait for its first frame.
    func testAForcedReconnectHoldsWritesUntilTheNewSocketOpens() {
        let model = viewModel()
        model.sendMessageSeam = { _, _ in true }
        XCTAssertEqual(model.state.connection, .connected)
        model.reconnectSocket()
        XCTAssertEqual(model.state.connection, .connected, "the state hasn't moved; only the socket has")
        model.send(channel, text: "/msg bob hi")
        XCTAssertEqual(model.takeUnsent(channel)?.text, "/msg bob hi", "the new socket hasn't opened")
        XCTAssertFalse(model.setNickNote(networkId: 1, nick: "bob", note: "lives in Berlin"))
        XCTAssertFalse(model.closeBuffer(channel))
        XCTAssertNotNil(model.state.buffers[channel.id])
        XCTAssertFalse(model.state.canWrite(networkId: 1), "joins, opens and reactions wait too")

        model.handle(.socketOpen)
        model.send(channel, text: "/msg bob hi")
        XCTAssertNil(model.takeUnsent(channel), "open: it went")
        XCTAssertTrue(model.state.canWrite(networkId: 1))
    }

    /// A command that puts nothing on the wire holds nothing: there is nothing to have lost.
    func testALocalCommandHoldsNothing() {
        let model = viewModel()
        model.send(channel, text: "/commands")
        XCTAssertNil(model.takeUnsent(channel))
    }

    /// The server log can't be closed, so `/close` there is a no-op rather than a lost write —
    /// it mustn't bounce back as if the connection were down.
    func testCloseInTheServerLogIsNotARefusal() {
        let model = viewModel()
        let log = BufferKey(networkId: 1, target: ":server:1")
        model.send(log, text: "/close")
        XCTAssertNil(model.takeUnsent(log))
    }

    /// L16: a close that couldn't go out leaves the row where it is, and says so to its caller.
    func testACloseThatWentNowhereKeepsTheRow() {
        let model = viewModel()
        XCTAssertNotNil(model.state.buffers[channel.id])
        XCTAssertFalse(model.closeBuffer(channel))
        XCTAssertNotNil(model.state.buffers[channel.id], "no PART went out, so the channel is still joined")
    }

    /// L14 and L29: the callers keep what was typed or dragged only if they're told.
    func testNoteAndReorderReportWentNowhere() {
        let model = viewModel()
        XCTAssertFalse(model.setNickNote(networkId: 1, nick: "bob", note: "lives in Berlin"))
        XCTAssertFalse(model.reorderFavorites(bufferIds: [3, 1, 2]))
    }

    /// L14: the cap is the server's, counted the way JavaScript counts — an emoji is two.
    func testANoteFitsByUTF16Units() {
        XCTAssertTrue(NickNote.fits(String(repeating: "a", count: NickNote.maxLength)))
        XCTAssertFalse(NickNote.fits(String(repeating: "a", count: NickNote.maxLength + 1)))
        XCTAssertFalse(NickNote.fits(String(repeating: "a", count: NickNote.maxLength - 1) + "🎉"))
    }
}

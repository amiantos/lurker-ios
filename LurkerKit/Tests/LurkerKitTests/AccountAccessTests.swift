// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import XCTest
@testable import LurkerKit

/// A paused account (ios#18): the wire, and the view model's answer from `/api/auth/me` and the
/// live `account-state` frame, end to end against a loopback server.
@MainActor
final class AccountAccessTests: XCTestCase {
    private let service = "chat.lurker.tests.accountaccess"
    /// Held for the whole test: a RoutedServer's deinit closes its listener.
    private var servers: [RoutedServer] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        SessionStore(service: service).clear()
    }

    override func tearDown() {
        cancellables.removeAll()
        SessionStore(service: service).clear()
        super.tearDown()
    }

    // MARK: - Wire

    func testTheFrameSaysWhichWay() {
        XCTAssertEqual(FrameParser.parseWs(#"{"kind":"account-state","paused":true}"#), .accountState(paused: true))
        XCTAssertEqual(FrameParser.parseWs(#"{"kind":"account-state","paused":false}"#), .accountState(paused: false))
    }

    func testAFrameThatDoesntSayIsDroppedNotReadAsActive() {
        XCTAssertEqual(FrameParser.parseWs(#"{"kind":"account-state"}"#), .ignored)
        XCTAssertEqual(FrameParser.parseWs(#"{"kind":"account-state","paused":1}"#), .ignored)
    }

    func testMeCarriesThePause() {
        let paused = Data(#"{"user":{"id":1,"username":"brad","role":"user","is_paused":true}}"#.utf8)
        XCTAssertEqual(LurkerClient.parseAccountPaused(paused, code: 200), true)
        let active = Data(#"{"user":{"id":1,"is_paused":false}}"#.utf8)
        XCTAssertEqual(LurkerClient.parseAccountPaused(active, code: 200), false)
    }

    func testAMeThatIsntAnAnswerIsNil() {
        XCTAssertNil(LurkerClient.parseAccountPaused(Data(#"{"user":{"id":1}}"#.utf8), code: 200))
        XCTAssertNil(LurkerClient.parseAccountPaused(Data(#"{"user":{"is_paused":true}}"#.utf8), code: 502))
        XCTAssertNil(LurkerClient.parseAccountPaused(Data("<html>".utf8), code: 200))
        XCTAssertNil(LurkerClient.parseAccountPaused(Data(#"{"user":{"is_paused":1}}"#.utf8), code: 200))
    }

    func testTheConfigSaysWhetherTheInstanceIsHosted() {
        XCTAssertEqual(LurkerClient.parseConfig(Data(#"{"edition":"node"}"#.utf8), code: 200)?.hosted, true)
        XCTAssertEqual(LurkerClient.parseConfig(Data(#"{"edition":"standalone"}"#.utf8), code: 200)?.hosted, false)
        XCTAssertEqual(LurkerClient.parseConfig(Data("{}".utf8), code: 200)?.hosted, false)
    }

    // MARK: - View model

    private func me(paused: Bool, delay: TimeInterval = 0) -> RoutedServer.Route {
        .init(status: 200, body: #"{"user":{"id":1,"is_paused":\#(paused)}}"#, delay: delay)
    }

    private func config(edition: String) -> RoutedServer.Route {
        .init(status: 200, body: #"{"edition":"\#(edition)","features":{}}"#)
    }

    private func signedIn(_ routes: [String: RoutedServer.Route]) async throws -> (ChatViewModel, RoutedServer) {
        let server = try await RoutedServer(routes: routes.merging([
            "POST /api/auth/logout": .init(status: 200, body: #"{"ok":true}"#),
        ]) { current, _ in current })
        servers.append(server)
        let sessions = SessionStore(service: service)
        sessions.save(PersistedSession(server: server.url, token: "tok"))
        let model = ChatViewModel(
            sessions: sessions,
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: service)!)
        )
        XCTAssertEqual(model.session, .loggedIn)
        return (model, server)
    }

    func testAPausedAccountOnAHostedCellNamesNoAdmin() async throws {
        let (model, _) = try await signedIn([
            "GET /api/auth/me": me(paused: true),
            "GET /api/config": config(edition: "node"),
        ])
        try await waitUntil { model.access == .paused(selfHosted: false) }
    }

    func testAPausedAccountOnASelfHostedServerSaysSo() async throws {
        let (model, _) = try await signedIn([
            "GET /api/auth/me": me(paused: true),
            "GET /api/config": config(edition: "standalone"),
        ])
        try await waitUntil { model.access == .paused(selfHosted: true) }
    }

    /// Without the config's word, a lurker.chat user would be told to ask an admin who isn't there.
    func testAConfigThatDidntAnswerNamesNoAdmin() async throws {
        let (model, server) = try await signedIn([
            "GET /api/auth/me": me(paused: true),
            "GET /api/config": .init(status: 502, body: ""),
        ])
        try await waitUntil { server.requests.contains { $0.hasPrefix("GET /api/config") } }
        try await waitUntil { model.access == .paused(selfHosted: false) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.access, .paused(selfHosted: false))
    }

    /// A pause fanned out before this socket was listening reached no one, so every open asks again.
    func testEverySocketOpenAsksAgain() async throws {
        let (model, server) = try await signedIn(["GET /api/auth/me": me(paused: false)])
        try await waitUntil { model.access == .active && server.requests.contains { $0.hasPrefix("GET /api/auth/me") } }
        server.route("GET /api/auth/me", me(paused: true))
        model.handle(.socketOpen)
        try await waitUntil { model.access == .paused(selfHosted: false) }
    }

    func testAnActiveAccountStaysActive() async throws {
        let (model, server) = try await signedIn(["GET /api/auth/me": me(paused: false)])
        try await waitUntil { server.requests.contains { $0.hasPrefix("GET /api/auth/me") } }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.access, .active)
    }

    func testTheLiveFrameFlipsItBothWays() async throws {
        let (model, server) = try await signedIn(["GET /api/auth/me": me(paused: false)])
        try await waitUntil { server.requests.contains { $0.hasPrefix("GET /api/auth/me") } }
        model.handle(.accountState(paused: true))
        XCTAssertEqual(model.access, .paused(selfHosted: false))
        model.handle(.accountState(paused: false))
        XCTAssertEqual(model.access, .active)
    }

    /// A read sent before the pause, answering after the frame that announced it, must not lift it.
    func testAMeReadAlreadyOutCantUndoTheFrame() async throws {
        let (model, server) = try await signedIn(["GET /api/auth/me": me(paused: false, delay: 0.5)])
        try await waitUntil { server.requests.contains { $0.hasPrefix("GET /api/auth/me") } }
        model.handle(.accountState(paused: true))
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(model.access, .paused(selfHosted: false))
    }

    /// Sign-out lands on sign-in and leaves the next account active — and the session goes first,
    /// so nothing watching both sees a signed-in, active account in between and builds the app.
    func testSigningOutResetsItAfterTheSession() async throws {
        let (model, _) = try await signedIn(["GET /api/auth/me": me(paused: true)])
        try await waitUntil { model.access == .paused(selfHosted: false) }
        var seen: [(ChatViewModel.SessionState, AccountAccess)] = []
        model.sessionPublisher.combineLatest(model.accessPublisher)
            .sink { seen.append($0) }
            .store(in: &cancellables)
        model.logout()
        XCTAssertEqual(model.access, .active)
        XCTAssertEqual(model.session, .loggedOut)
        XCTAssertFalse(
            seen.contains { $0.0 == .loggedIn && $0.1 == .active },
            "signed in and active, briefly: \(seen)"
        )
    }
}

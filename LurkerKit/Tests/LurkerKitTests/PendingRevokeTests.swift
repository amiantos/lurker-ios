// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Network
import XCTest
@testable import LurkerKit

/// #218: a sign-out made offline must still reach the server. Until it does the token stays live
/// there (OAuth tokens never expire), and so do the push registrations made through it — the
/// departing account's DMs keep arriving on this phone.
@MainActor
final class PendingRevokeTests: XCTestCase {

    /// Its own Keychain service, emptied around each test.
    private let service = "chat.lurker.tests.pendingrevoke"

    override func setUp() {
        super.setUp()
        clearKeychain()
    }

    override func tearDown() {
        clearKeychain()
        super.tearDown()
    }

    private func clearKeychain() {
        let store = SessionStore(service: service)
        store.clear()
        for pending in store.pendingRevokes() { store.removePendingRevoke(token: pending.token) }
    }

    // MARK: - The verdict

    func testOnlyLurkersOwnAnswerEndsTheRetries() {
        let ok = Data(#"{"ok":true}"#.utf8)
        // The cell's answer, for a token revoked now or long ago alike.
        XCTAssertEqual(LurkerClient.revokeOutcome(status: 200, body: ok), .done)
        // A 401 isn't Lurker's either: an auth gateway in front of a self-hosted server sends one
        // without the request ever reaching it.
        XCTAssertEqual(LurkerClient.revokeOutcome(status: 401, body: nil), .retry)
        // A 200 that isn't Lurker's (a captive portal), and every status from something in
        // front of the server: none of them says anything about the token.
        XCTAssertEqual(LurkerClient.revokeOutcome(status: 200, body: Data("<html>".utf8)), .retry)
        XCTAssertEqual(LurkerClient.revokeOutcome(status: 200, body: Data(#"{"ok":false}"#.utf8)), .retry)
        XCTAssertEqual(LurkerClient.revokeOutcome(status: 403, body: nil), .retry)
        XCTAssertEqual(LurkerClient.revokeOutcome(status: 404, body: nil), .retry)
        XCTAssertEqual(LurkerClient.revokeOutcome(status: 429, body: nil), .retry)
        XCTAssertEqual(LurkerClient.revokeOutcome(status: 503, body: nil), .retry)
        // No answer at all: offline.
        XCTAssertEqual(LurkerClient.revokeOutcome(status: nil, body: nil), .retry)
    }

    // MARK: - The queue

    func testTheQueueOutlivesTheStoreThatWroteIt() {
        // It's in the Keychain, so a relaunch (a new SessionStore) still owes the revoke.
        let a = PersistedSession(server: "https://a.example", token: "ta")
        let b = PersistedSession(server: "https://b.example", token: "tb")
        SessionStore(service: service).addPendingRevoke(a)
        SessionStore(service: service).addPendingRevoke(b)
        SessionStore(service: service).addPendingRevoke(a)
        XCTAssertEqual(SessionStore(service: service).pendingRevokes().map(\.token), ["ta", "tb"])

        SessionStore(service: service).removePendingRevoke(token: "ta")
        XCTAssertEqual(SessionStore(service: service).pendingRevokes().map(\.server), ["https://b.example"])
    }

    func testTheQueueIsSeparateFromTheLiveSession() {
        let store = SessionStore(service: service)
        let live = PersistedSession(server: "https://a.example", token: "live")
        store.save(live)
        store.addPendingRevoke(PersistedSession(server: "https://a.example", token: "old"))
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertEqual(store.pendingRevokes().map(\.token), ["old"])
    }

    func testAnUnreadableQueueIsEmptyNotACrash() {
        XCTAssertEqual(SessionCodec.decodeList(Data("garbage".utf8)), [])
        let mixed = #"[{"server":"https://a","token":"t","since":0},{"server":"","token":"x","since":0}]"#
        XCTAssertEqual(SessionCodec.decodeList(Data(mixed.utf8)).map(\.token), ["t"])
    }

    // MARK: - The retry, against a server that answers

    /// A launch retries what's owed, and Lurker's answer ends it.
    func testALaunchRetriesAndAFinalAnswerEndsIt() async throws {
        let server = try await OneStatusServer(status: 200, body: #"{"ok":true}"#)
        let sessions = SessionStore(service: service)
        sessions.addPendingRevoke(PersistedSession(server: server.url, token: "old"))
        let model = ChatViewModel(
            sessions: sessions,
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: service)!)
        )
        try await waitUntil { sessions.pendingRevokes().isEmpty }
        XCTAssertEqual(server.requests.first?.hasPrefix("POST /api/auth/logout "), true)
        XCTAssertEqual(server.requests.first?.contains("Authorization: Bearer old"), true)
        _ = model
    }

    /// A temporary answer keeps it owed, and the network coming back asks again.
    func testATemporaryAnswerKeepsItOwedAndReachabilityAsksAgain() async throws {
        let server = try await OneStatusServer(status: 503)
        let sessions = SessionStore(service: service)
        sessions.addPendingRevoke(PersistedSession(server: server.url, token: "old"))
        let model = ChatViewModel(
            sessions: sessions,
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: service)!)
        )
        try await waitUntil { server.requests.count == 1 && model.revoking.isEmpty }
        XCTAssertEqual(sessions.pendingRevokes().map(\.token), ["old"])

        model.setReachable(false)
        model.setReachable(true)
        try await waitUntil { server.requests.count == 2 && model.revoking.isEmpty }
        XCTAssertEqual(sessions.pendingRevokes().map(\.token), ["old"])

        // And a foreground asks again, for a server that was down while the phone stayed online.
        _ = model.enterForeground()
        try await waitUntil { server.requests.count == 3 }
    }

    /// The network comes back while a revoke is already out: if that one fails, it's asked again
    /// at once rather than waiting for the next trigger.
    func testATriggerDuringARequestIsNotLost() async throws {
        let server = try await OneStatusServer(status: 503, gated: true)
        defer { server.open() }
        let sessions = SessionStore(service: service)
        sessions.addPendingRevoke(PersistedSession(server: server.url, token: "old"))
        let model = ChatViewModel(
            sessions: sessions,
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: service)!)
        )
        try await waitUntil { server.requests.count == 1 }
        XCTAssertEqual(model.revoking, ["old"])
        // Held open by the gate: the network comes back while it's still out.
        model.setReachable(false)
        model.setReachable(true)
        XCTAssertEqual(server.requests.count, 1)
        server.open()
        // It fails, and the trigger it swallowed is replayed — once.
        try await waitUntil { server.requests.count == 2 && model.revoking.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.requests.count, 2)
    }

    /// Two owed revokes, both out when a foreground arrives: each is replayed once when it fails,
    /// and then the retries stop. Replaying by re-running the whole retry marked the OTHER token,
    /// still out, as wanted too — and the two re-marked each other in a loop for good.
    func testTwoOwedRevokesDoNotFeedEachOther() async throws {
        let server = try await OneStatusServer(status: 503, gated: true)
        defer { server.open() }
        let sessions = SessionStore(service: service)
        sessions.addPendingRevoke(PersistedSession(server: server.url, token: "a"))
        sessions.addPendingRevoke(PersistedSession(server: server.url, token: "b"))
        let model = ChatViewModel(
            sessions: sessions,
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: service)!)
        )
        try await waitUntil { server.requests.count == 2 }
        _ = model.enterForeground()
        server.open()
        try await waitUntil { server.requests.count == 4 && model.revoking.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(server.requests.count, 4)
    }

    /// A month unanswered and the server is taken to be gone: dropped without asking it.
    func testAnOwedRevokeExpires() async throws {
        let server = try await OneStatusServer(status: 503)
        let sessions = SessionStore(service: service)
        let longAgo = Date().addingTimeInterval(-ChatViewModel.revokeRetryWindow - 60)
        sessions.addPendingRevoke(PersistedSession(server: server.url, token: "ancient"), at: longAgo)
        sessions.addPendingRevoke(PersistedSession(server: server.url, token: "recent"))
        let model = ChatViewModel(
            sessions: sessions,
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: service)!)
        )
        try await waitUntil { server.requests.count == 1 && model.revoking.isEmpty }
        XCTAssertEqual(sessions.pendingRevokes().map(\.token), ["recent"])
        XCTAssertEqual(server.requests.first?.contains("Bearer recent"), true)
    }

    // MARK: - Sign-out

    func testASignOutTheServerNeverHeardStaysOwed() async throws {
        // Nothing listens on port 1, so the revoke gets no answer at all — the offline case.
        let sessions = SessionStore(service: service)
        sessions.save(PersistedSession(server: "http://127.0.0.1:1", token: "departing"))
        let model = ChatViewModel(
            sessions: sessions,
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: service)!)
        )
        model.logout()
        // Owed the moment the session ends, before the request has gone anywhere.
        XCTAssertNil(sessions.load())
        XCTAssertEqual(sessions.pendingRevokes().map(\.token), ["departing"])

        // And still owed once the request has failed.
        try await waitUntil { model.revoking.isEmpty }
        XCTAssertEqual(sessions.pendingRevokes().map(\.token), ["departing"])
    }
}

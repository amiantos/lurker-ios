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
        // lurker.chat's proxy, for a token it can't route to any cell: nothing can use it.
        XCTAssertEqual(LurkerClient.revokeOutcome(status: 401, body: nil), .done)
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

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "timed out")
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

/// A loopback HTTP server that answers every request with one status and records each request's
/// head. Just enough HTTP for URLSession.
private final class OneStatusServer: @unchecked Sendable {
    private(set) var url = ""
    private let listener: NWListener
    private let lock = NSLock()
    private var heads: [String] = []

    var requests: [String] { lock.withLock { heads } }

    init(status: Int, body: String = "") async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { continuation.yield(port); continuation.finish() }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data, let head = String(data: data, encoding: .utf8) {
                    self?.lock.withLock { self?.heads.append(head) }
                }
                let response = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(Data(body.utf8).count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for await p in ready { port = p }
        url = "http://127.0.0.1:\(port)"
    }

    deinit { listener.cancel() }
}

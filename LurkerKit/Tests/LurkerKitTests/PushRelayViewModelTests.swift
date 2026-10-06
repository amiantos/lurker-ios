// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The relay branch of push registration, end to end through the view model against a
/// loopback server (RELAY_PLAN.md §6.2): the keys, the endpoint, what each answer leaves
/// behind, and both teardowns.
@MainActor
final class PushRelayViewModelTests: XCTestCase {
    private let service = "chat.lurker.tests.pushrelay"
    private let serverKey =
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
    private let token = "ABCDEF0123456789"
    /// Held for the whole test: a RoutedServer's deinit closes its listener, so one dropped by a
    /// `let (model, _, _)` would refuse every request after setup.
    private var servers: [RoutedServer] = []

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

    private func config(relay: Bool = true, apns: Bool = false) -> RoutedServer.Route {
        let transports = apns ? #"["webpush","apns"]"# : #"["webpush"]"#
        let relayField = relay ? #","relay":"https://push.lurker.chat""# : ""
        return .init(status: 200, body: #"{"publicKey":"\#(serverKey)","transports":\#(transports)\#(relayField)}"#)
    }

    private func signedIn(subscriptionStatus: Int = 201, relay: Bool = true, apns: Bool = false)
        async throws -> (ChatViewModel, RoutedServer, MemoryKeyStore)
    {
        let server = try await RoutedServer(routes: [
            "GET /api/push/config": config(relay: relay, apns: apns),
            "POST /api/push/subscriptions": .init(status: subscriptionStatus, body: "{}"),
            "DELETE /api/push/subscriptions": .init(status: 200, body: #"{"ok":true}"#),
            "POST /api/push/devices": .init(status: 201, body: "{}"),
            "POST /api/auth/logout": .init(status: 200, body: #"{"ok":true}"#),
        ])
        servers.append(server)
        let sessions = SessionStore(service: service)
        sessions.save(PersistedSession(server: server.url, token: "tok"))
        let model = ChatViewModel(
            sessions: sessions,
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: service)!)
        )
        let keys = MemoryKeyStore()
        model.pushKeyStore = keys
        XCTAssertEqual(model.session, .loggedIn)
        return (model, server, keys)
    }

    private var endpoint: String {
        "https://push.lurker.chat/relay-to/apns/production/abcdef0123456789/\(serverKey)"
    }

    private func requests(_ server: RoutedServer, _ key: String) -> [String] {
        server.requests.filter { $0.hasPrefix(key + "\n") }
    }

    func testARelayRegistrationCreatesTheKeysAndFilesTheEndpoint() async throws {
        let (model, server, keys) = try await signedIn()
        let result = await model.registerPushDevice(token: token)
        XCTAssertEqual(result, .registered)
        let stored = try XCTUnwrap(keys.stored)
        let posted = try XCTUnwrap(requests(server, "POST /api/push/subscriptions").first)
        XCTAssertTrue(posted.contains(endpoint.replacingOccurrences(of: "/", with: "\\/")) || posted.contains(endpoint), posted)
        XCTAssertTrue(posted.contains(stored.p256dh), posted)
        XCTAssertTrue(posted.contains(stored.auth), posted)
        XCTAssertEqual(model.relayEndpoint, endpoint)
        XCTAssertEqual(model.pushRoute, .relay(origin: "https://push.lurker.chat", serverKey: serverKey))
        // Never the native route for a relay server.
        XCTAssertTrue(requests(server, "POST /api/push/devices").isEmpty)
    }

    func testTheAdminTurningTheRelayOffMeansNoPushAndAFreshAsk() async throws {
        let (model, server, _) = try await signedIn(subscriptionStatus: 403)
        let result = await model.registerPushDevice(token: token)
        XCTAssertEqual(result, .relayOff)
        XCTAssertEqual(model.pushRoute, .unavailable)
        XCTAssertNil(model.pushConfig)
        _ = await model.resolvePushRoute()
        XCTAssertEqual(requests(server, "GET /api/push/config").count, 2)
    }

    func testKeysThatCantBeStoredAreNeverRegistered() async throws {
        let (model, server, keys) = try await signedIn()
        keys.refuseSaves = true
        let result = await model.registerPushDevice(token: token)
        guard case .failed = result else { return XCTFail("\(result)") }
        XCTAssertTrue(requests(server, "POST /api/push/subscriptions").isEmpty)
    }

    func testSignOutDropsTheRelaySubscription() async throws {
        let (model, server, _) = try await signedIn()
        _ = await model.registerPushDevice(token: token)
        model.logout()
        try await waitUntil { !self.requests(server, "DELETE /api/push/subscriptions").isEmpty }
        let deleted = try XCTUnwrap(requests(server, "DELETE /api/push/subscriptions").first)
        XCTAssertTrue(deleted.contains("relay-to"), deleted)
        // Before the revoke: it needs the session the revoke ends.
        let order = server.requests.map { $0.split(separator: "\n").first.map(String.init) ?? "" }
        let deleteAt = try XCTUnwrap(order.firstIndex(of: "DELETE /api/push/subscriptions"))
        try await waitUntil { order.count < server.requests.count || order.contains("POST /api/auth/logout") }
        let later = server.requests.map { $0.split(separator: "\n").first.map(String.init) ?? "" }
        if let revokeAt = later.firstIndex(of: "POST /api/auth/logout") { XCTAssertLessThan(deleteAt, revokeAt) }
    }

    /// A registration whose answer was lost may still have landed: sign-out drops it anyway.
    func testAnEndpointIsRememberedEvenWhenTheAnswerIsLost() async throws {
        let (model, server, _) = try await signedIn(subscriptionStatus: 500)
        let result = await model.registerPushDevice(token: token)
        guard case .failed = result else { return XCTFail("\(result)") }
        XCTAssertEqual(model.relayEndpoint, endpoint)
        model.logout()
        try await waitUntil { !self.requests(server, "DELETE /api/push/subscriptions").isEmpty }
    }

    /// The two teardowns lead to the same screen and must leave the same state behind.
    func testALostSessionForgetsPushLikeASignOut() async throws {
        let (model, server, _) = try await signedIn()
        _ = await model.registerPushDevice(token: token)
        XCTAssertNotNil(model.relayEndpoint)
        model.handle(.unauthorized)
        XCTAssertEqual(model.session, .loggedOut)
        XCTAssertNil(model.pushRoute)
        XCTAssertNil(model.pushConfig)
        XCTAssertNil(model.relayEndpoint)
    }

    /// The admin can turn the relay on while the app is open; the next activation sees it.
    func testOnlyAnAPNsAnswerIsKeptForTheSession() async throws {
        let (model, server, _) = try await signedIn(relay: false)
        let first = await model.resolvePushRoute()
        XCTAssertEqual(first, .unavailable)
        server.route("GET /api/push/config", config(relay: true))
        let second = await model.resolvePushRoute()
        XCTAssertEqual(second, .relay(origin: "https://push.lurker.chat", serverKey: serverKey))

        // A hosted server's answer can't change, so it's asked once.
        server.route("GET /api/push/config", config(apns: true))
        _ = await model.resolvePushRoute()
        _ = await model.resolvePushRoute()
        XCTAssertEqual(requests(server, "GET /api/push/config").count, 3)
        XCTAssertEqual(model.pushRoute, .apns)
    }

    func testTheRouteIsPublishedForSettings() async throws {
        let (model, server, _) = try await signedIn(relay: false)
        var seen: [PushRoute?] = []
        let watching = model.pushRoutePublisher.sink { seen.append($0) }
        _ = await model.resolvePushRoute()
        XCTAssertEqual(seen.last, .unavailable)
        watching.cancel()
    }

    // MARK: - Account isolation

    /// A push for the signed-out account, still queued at APNs, can't be read by the next one.
    func testSignOutRotatesTheKeysSoTheOldAccountsPushesCantBeRead() async throws {
        let (model, server, keys) = try await signedIn()
        _ = await model.registerPushDevice(token: token)
        let old = try XCTUnwrap(keys.stored)
        let queued = try WebPushTestEncryptor.encrypt(
            Data(#"{"title":"old account","tag":"x","networkId":1,"target":"bob"}"#.utf8),
            to: old.privateKey.publicKey, authSecret: old.authSecret
        )
        XCTAssertNoThrow(try WebPushCrypto.decrypt(queued, keys: old))
        model.logout()
        XCTAssertNil(keys.stored)
        let next = try XCTUnwrap(keys.loadOrCreate())
        XCTAssertNotEqual(next.p256dh, old.p256dh)
        XCTAssertThrowsError(try WebPushCrypto.decrypt(queued, keys: next))
    }

    func testALostSessionRotatesTheKeysToo() async throws {
        let (model, server, keys) = try await signedIn()
        _ = await model.registerPushDevice(token: token)
        XCTAssertNotNil(keys.stored)
        model.handle(.unauthorized)
        XCTAssertNil(keys.stored)
    }

    /// A reply from a session that has since ended changes nothing.
    func testALate403FromTheLastSessionLeavesTheNextAlone() async throws {
        let (model, server, _) = try await signedIn()
        server.route("POST /api/push/subscriptions", .init(status: 403, body: "{}", delay: 0.5))
        let registering = Task { await model.registerPushDevice(token: token) }
        try await waitUntil { !self.requests(server, "POST /api/push/subscriptions").isEmpty }
        model.logout()
        let result = await registering.value
        XCTAssertEqual(result, .unavailable)
        XCTAssertNil(model.pushRoute, "the late 403 rewrote the route after sign-out")
        XCTAssertNil(model.pushConfig)
    }

    // MARK: - Route switches

    func testMovingFromTheRelayToDirectAPNsDropsTheRelaySubscription() async throws {
        let (model, server, _) = try await signedIn()
        _ = await model.registerPushDevice(token: token)
        server.route("GET /api/push/config", config(apns: true))
        _ = await model.resolvePushRoute()
        let result = await model.registerPushDevice(token: token)
        XCTAssertEqual(result, .registered)
        let deleted = try XCTUnwrap(requests(server, "DELETE /api/push/subscriptions").first)
        XCTAssertTrue(deleted.contains("relay-to"), deleted)
        XCTAssertEqual(requests(server, "POST /api/push/devices").count, 1)
        XCTAssertNil(model.relayEndpoint)
    }

    func testMovingFromDirectAPNsToTheRelayDropsTheDirectRegistration() async throws {
        let (model, server, _) = try await signedIn(apns: true)
        _ = await model.registerPushDevice(token: token)
        XCTAssertEqual(requests(server, "POST /api/push/devices").count, 1)
        server.route("GET /api/push/devices", .init(status: 200, body: "{}"))
        server.route("DELETE /api/push/devices", .init(status: 200, body: #"{"ok":true}"#))
        // A hosted answer is kept for the session; a new session on a relay server is the
        // realistic switch, but the server changing its answer exercises the same path.
        model.forgetPushConfigForTests()
        server.route("GET /api/push/config", config(relay: true))
        _ = await model.resolvePushRoute()
        let result = await model.registerPushDevice(token: token)
        XCTAssertEqual(result, .registered)
        let deleted = try XCTUnwrap(requests(server, "DELETE /api/push/devices").first)
        XCTAssertTrue(deleted.contains(token), deleted)
        XCTAssertEqual(requests(server, "POST /api/push/subscriptions").count, 1)
        XCTAssertNil(model.directToken)
    }

    /// The admin turned the relay off and on while the app was away: the server deleted the
    /// subscription. iOS hands over the token on every activation, and each re-files it.
    func testEveryActivationRefilesTheSubscription() async throws {
        let (model, server, _) = try await signedIn()
        _ = await model.registerPushDevice(token: token)
        _ = await model.resolvePushRoute()
        _ = await model.registerPushDevice(token: token)
        XCTAssertEqual(requests(server, "POST /api/push/subscriptions").count, 2)
    }
}

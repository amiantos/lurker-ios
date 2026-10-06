// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// When the app uses push.lurker.chat, and what it registers (RELAY_PLAN.md §6.2).
final class PushRelayTests: XCTestCase {
    private let key = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"

    private func config(transports: [String] = ["webpush"], relay: String? = "https://push.lurker.chat", key: String? = nil) -> PushConfig {
        PushConfig(publicKey: key ?? self.key, transports: transports, relay: relay)
    }

    func testTheConfigReadsAllThreeKeys() {
        let parsed = PushConfig.parse([
            "publicKey": key, "transports": ["webpush"], "relay": "https://push.lurker.chat",
        ])
        XCTAssertEqual(parsed, config())
    }

    func testAnOlderServerReadsAsNoRelayAndNoNativePush() {
        // Before 2.4.0 there is no `relay`; before #490 no `transports`.
        XCTAssertEqual(PushConfig.parse(["publicKey": key]), PushConfig(publicKey: key, transports: [], relay: nil))
        XCTAssertEqual(PushRoute.decide(PushConfig.parse(["publicKey": key]), allowAnyHTTPSRelay: true), .unavailable)
    }

    func testAServerWithOurAPNsKeyPushesDirectly() {
        XCTAssertEqual(PushRoute.decide(config(transports: ["webpush", "apns", "fcm"]), allowAnyHTTPSRelay: false), .apns)
    }

    func testTheRelayOnlyWhenTheAdminTurnedItOn() {
        XCTAssertEqual(
            PushRoute.decide(config(), allowAnyHTTPSRelay: false),
            .relay(origin: "https://push.lurker.chat", serverKey: key)
        )
        // No `relay` field: the admin hasn't, and the app contacts nothing.
        XCTAssertEqual(PushRoute.decide(config(relay: nil), allowAnyHTTPSRelay: false), .unavailable)
    }

    func testAReleaseBuildTrustsOnlyTheOfficialRelay() {
        for relay in ["https://evil.example", "https://push.lurker.chat.evil.example", "http://push.lurker.chat"] {
            XCTAssertEqual(PushRoute.decide(config(relay: relay), allowAnyHTTPSRelay: false), .unavailable, relay)
        }
    }

    func testADebugBuildTakesAnyHTTPSRelayButNeverPlainHTTP() {
        XCTAssertEqual(
            PushRoute.decide(config(relay: "https://relay.test:8443"), allowAnyHTTPSRelay: true),
            .relay(origin: "https://relay.test:8443", serverKey: key)
        )
        XCTAssertEqual(PushRoute.decide(config(relay: "http://relay.test"), allowAnyHTTPSRelay: true), .unavailable)
    }

    func testOnlyTheOriginIsKept() {
        XCTAssertEqual(
            PushRoute.decide(config(relay: "https://PUSH.lurker.chat/some/path?x=1#y"), allowAnyHTTPSRelay: false),
            .relay(origin: "https://push.lurker.chat", serverKey: key)
        )
        XCTAssertEqual(PushRoute.decide(config(relay: "https://me:pw@push.lurker.chat"), allowAnyHTTPSRelay: false), .unavailable)
    }

    func testNoServerKeyNoRelay() {
        let noKey = PushConfig(publicKey: nil, transports: ["webpush"], relay: "https://push.lurker.chat")
        XCTAssertEqual(PushRoute.decide(noKey, allowAnyHTTPSRelay: false), .unavailable)
    }

    func testTheEndpointIsTheContractsShape() {
        XCTAssertEqual(
            RelayEndpoint.apns(origin: "https://push.lurker.chat", environment: .production, token: "ABCDEF0123", serverKey: key),
            "https://push.lurker.chat/relay-to/apns/production/abcdef0123/\(key)"
        )
        XCTAssertEqual(
            RelayEndpoint.apns(origin: "https://relay.test", environment: .development, token: "ab", serverKey: "k"),
            "https://relay.test/relay-to/apns/development/ab/k"
        )
    }
}

/// The decrypted body, made into the notification a direct APNs push would have shown.
final class RelayNotificationTests: XCTestCase {
    func testAServerBuiltPushBecomesTheSameNotification() throws {
        let v = try XCTUnwrap(WebPushCryptoTests.vectors().first { $0.name == "dm" })
        let n = try XCTUnwrap(RelayNotification.parse(Data(v.plaintext.utf8)))
        XCTAssertEqual(n.title, "bob (Libera)")
        XCTAssertEqual(n.body, "hey, are you around? café ☕ 🎉")
        XCTAssertEqual(n.tag, "3::bob")
        XCTAssertEqual(n.badge, 3)
        XCTAssertEqual(n.networkId, 3)
        XCTAssertEqual(n.target, "bob")
        XCTAssertEqual(n.messageId, 9001)
        XCTAssertEqual(n.bufferId, 42)
        XCTAssertEqual(n.kind, "dm")
    }

    func testItTapsThroughTheExistingPath() throws {
        let v = try XCTUnwrap(WebPushCryptoTests.vectors().first { $0.name == "highlight" })
        let n = try XCTUnwrap(RelayNotification.parse(Data(v.plaintext.utf8)))
        XCTAssertEqual(
            NotificationTap.parse(n.userInfo),
            NotificationTap(networkId: 1, target: "#lurker", messageId: 9002)
        )
        XCTAssertEqual(n.userInfo["tag"] as? String, n.tag)
    }

    func testEveryServerVectorParses() throws {
        for v in try WebPushCryptoTests.vectors() where v.name != "rfc8291-appendix-a" {
            XCTAssertNotNil(RelayNotification.parse(Data(v.plaintext.utf8)), v.name)
        }
    }

    func testAnythingElseIsLeftAsThePlaceholder() {
        for json in [
            "not json", "[]", #"{"title":"t","tag":"x","target":"bob"}"#,
            #"{"title":"","tag":"x","networkId":1,"target":"bob"}"#,
            #"{"title":"t","tag":"x","networkId":true,"target":"bob"}"#,
        ] {
            XCTAssertNil(RelayNotification.parse(Data(json.utf8)), json)
        }
    }

    func testAMissingBadgeOrBodyIsFine() throws {
        let n = try XCTUnwrap(RelayNotification.parse(Data(
            #"{"kind":"friend_online","networkId":1,"target":"bob","title":"bob came online","tag":"x"}"#.utf8
        )))
        XCTAssertNil(n.badge)
        XCTAssertEqual(n.body, "")
        XCTAssertNil(n.userInfo["messageId"])
    }
}

/// The two requests the relay adds to the client (RELAY_PLAN.md §6.2).
final class WebPushRegistrationTests: XCTestCase {
    private func register(status: Int) async throws -> (LurkerClient.WebPushRegistration, String) {
        let server = try await OneStatusServer(status: status)
        let result = await LurkerClient.registerWebPush(
            session: URLSession(configuration: .ephemeral), baseURL: server.url, sessionToken: "tok",
            endpoint: "https://push.lurker.chat/relay-to/apns/production/ab/k", keys: .generate()
        )
        return (result, server.requests.joined())
    }

    func testARegistrationIsAWebPushSubscription() async throws {
        let (result, request) = try await register(status: 201)
        XCTAssertEqual(result, .registered)
        XCTAssertTrue(request.hasPrefix("POST /api/push/subscriptions "), request)
        XCTAssertTrue(request.contains("Bearer tok"))
    }

    func testTheSubscriptionCarriesTheEndpointAndTheKeys() throws {
        let keys = WebPushKeys.generate()
        let request = try XCTUnwrap(LurkerClient.webPushRequest(
            "POST", baseURL: "https://lurker.test", sessionToken: "tok", body: [
                "endpoint": "https://push.lurker.chat/relay-to/apns/production/ab/k",
                "keys": ["p256dh": keys.p256dh, "auth": keys.auth],
                "userAgent": "Lurker iOS",
            ]
        ))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["endpoint"] as? String, "https://push.lurker.chat/relay-to/apns/production/ab/k")
        XCTAssertEqual(body["keys"] as? [String: String], ["p256dh": keys.p256dh, "auth": keys.auth])
        XCTAssertEqual(request.url?.absoluteString, "https://lurker.test/api/push/subscriptions")
    }

    func testA403MeansTheAdminTurnedTheRelayOff() async throws {
        let (result, _) = try await register(status: 403)
        XCTAssertEqual(result, .relayOff)
    }

    func testAnythingElseIsAFailure() async throws {
        let (result, _) = try await register(status: 500)
        XCTAssertEqual(result, .failed)
    }

    func testSignOutDropsTheSubscription() async throws {
        let server = try await OneStatusServer(status: 200)
        await LurkerClient.deregisterWebPush(
            session: URLSession(configuration: .ephemeral), baseURL: server.url, sessionToken: "tok",
            endpoint: "https://push.lurker.chat/relay-to/apns/production/ab/k"
        )
        let request = server.requests.joined()
        XCTAssertTrue(request.hasPrefix("DELETE /api/push/subscriptions "), request)
        XCTAssertTrue(request.contains("Bearer tok"))
    }

    func testTheConfigIsReadOnce() async throws {
        let server = try await OneStatusServer(
            status: 200, body: #"{"publicKey":"k","transports":["webpush"],"relay":"https://push.lurker.chat"}"#
        )
        let config = await LurkerClient.pushConfig(
            session: URLSession(configuration: .ephemeral), baseURL: server.url, sessionToken: "tok"
        )
        XCTAssertEqual(config, PushConfig(publicKey: "k", transports: ["webpush"], relay: "https://push.lurker.chat"))
    }
}

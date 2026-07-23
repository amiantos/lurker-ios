// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Tap routing (#15). The payloads here are the ones the server actually builds — see
/// buildApnsRequest in the lurker repo — rather than shapes invented to match the parser,
/// which would only prove the parser agrees with itself.
final class NotificationTapTests: XCTestCase {

    /// A DM push, exactly as `buildApnsRequest` composes it: `aps` for what iOS renders,
    /// routing keys beside it for where a tap goes.
    private func dmPayload() -> [AnyHashable: Any] {
        [
            "aps": [
                "alert": ["title": "bob (Libera)", "body": "hey there"],
                "badge": 3,
                "sound": "default",
                "thread-id": "7::bob",
            ],
            "networkId": 7,
            "target": "bob",
            "messageId": 42,
            "kind": "dm",
        ]
    }

    func testParsesADMPush() {
        let tap = NotificationTap.parse(dmPayload())
        XCTAssertEqual(tap, NotificationTap(networkId: 7, target: "bob", messageId: 42))
    }

    func testParsesAChannelHighlight() {
        var payload = dmPayload()
        payload["target"] = "#lurker"
        payload["kind"] = "highlight"
        XCTAssertEqual(NotificationTap.parse(payload), NotificationTap(networkId: 7, target: "#lurker", messageId: 42))
    }

    func testParsesTheMessageIdForTheJumpTarget() {
        // The server stamps `messageId: decorated.id`; the tap carries it so it can land on
        // the exact line (#42), and it survives arriving as an NSNumber off real JSON.
        XCTAssertEqual(NotificationTap.parse(dmPayload())?.messageId, 42)
        var nsNumberPayload = dmPayload()
        nsNumberPayload["messageId"] = NSNumber(value: 99)
        XCTAssertEqual(NotificationTap.parse(nsNumberPayload)?.messageId, 99)
        // FCM's all-strings shape.
        var stringPayload = dmPayload()
        stringPayload["messageId"] = "1234"
        XCTAssertEqual(NotificationTap.parse(stringPayload)?.messageId, 1234)
    }

    func testAMissingMessageIdIsNilNotAFailure() {
        // A friend-online push names a buffer but no message; the tap still routes, without a
        // jump target.
        var payload = dmPayload()
        payload.removeValue(forKey: "messageId")
        let tap = NotificationTap.parse(payload)
        XCTAssertNotNil(tap)
        XCTAssertNil(tap?.messageId)
    }

    func testParsesAFriendOnlinePush() {
        // Carries no messageId — the tap still has to route, to the friend's DM.
        let payload: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Amiantos came online (Libera)", "body": ""]],
            "networkId": 3,
            "target": "nostimo",
            "kind": "friend_online",
        ]
        XCTAssertEqual(NotificationTap.parse(payload), NotificationTap(networkId: 3, target: "nostimo"))
    }

    /// A real APNs payload arrives via JSON, so networkId is an NSNumber rather than a
    /// Swift Int. `as? Int` bridges it — this pins the CONTRACT (an NSNumber payload
    /// routes) rather than any particular arm of the switch, so it stays honest if the
    /// bridging ever stops being free.
    func testParsesNetworkIdArrivingAsNSNumber() {
        var payload = dmPayload()
        payload["networkId"] = NSNumber(value: 7)
        XCTAssertEqual(NotificationTap.parse(payload)?.networkId, 7)
    }

    /// The shape a payload genuinely takes coming off the wire, rather than one hand-built
    /// in Swift — JSONSerialization is what UserNotifications' userInfo is made of.
    func testParsesAPayloadDecodedFromRealJSON() throws {
        let json = """
        {"aps":{"alert":{"title":"bob (Libera)","body":"hey"},"badge":3,"thread-id":"7::bob"},
         "networkId":7,"target":"#lurker","messageId":42,"kind":"highlight"}
        """
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any]
        )
        XCTAssertEqual(NotificationTap.parse(decoded), NotificationTap(networkId: 7, target: "#lurker", messageId: 42))
    }

    func testParsesNetworkIdArrivingAsString() {
        // FCM's data dictionary is all-strings. Not our payload today, but the two shapes
        // are one mistake apart and routing is the wrong place to be strict.
        var payload = dmPayload()
        payload["networkId"] = "7"
        XCTAssertEqual(NotificationTap.parse(payload)?.networkId, 7)
    }

    func testPreservesTargetCasing() {
        // The tap carries whatever case the server sent. Folding happens at lookup time
        // (BufferKey.id), not here — the original casing is what gets echoed back.
        var payload = dmPayload()
        payload["target"] = "#Lurker"
        XCTAssertEqual(NotificationTap.parse(payload)?.target, "#Lurker")
    }

    // MARK: - Payloads that name no buffer

    func testRejectsAPayloadWithNoRoutingKeys() {
        // A notification with nothing but `aps` should open the app, not crash it and not
        // guess at a destination.
        XCTAssertNil(NotificationTap.parse(["aps": ["alert": "hi"]]))
    }

    func testRejectsAMissingTarget() {
        var payload = dmPayload()
        payload.removeValue(forKey: "target")
        XCTAssertNil(NotificationTap.parse(payload))
    }

    func testRejectsAnEmptyTarget() {
        // An empty string is a buffer key that matches nothing; routing to it would land
        // on a blank screen, which is worse than staying put.
        var payload = dmPayload()
        payload["target"] = ""
        XCTAssertNil(NotificationTap.parse(payload))
    }

    func testRejectsAMissingNetworkId() {
        var payload = dmPayload()
        payload.removeValue(forKey: "networkId")
        XCTAssertNil(NotificationTap.parse(payload))
    }

    func testRejectsANonNumericNetworkId() {
        var payload = dmPayload()
        payload["networkId"] = "not-a-number"
        XCTAssertNil(NotificationTap.parse(payload))
    }

    func testRejectsAnEmptyPayload() {
        XCTAssertNil(NotificationTap.parse([:]))
    }
}

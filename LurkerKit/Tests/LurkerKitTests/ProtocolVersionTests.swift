// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The protocol version handshake (#17): what this build announces on the socket, and what it
/// makes of a server's answer, from `/api/config` or from a refused upgrade.
final class ProtocolVersionTests: XCTestCase {

    // MARK: - Comparing versions

    func testAServerThatNoLongerServesThisBuildNeedsAnAppUpdate() {
        XCTAssertEqual(
            ProtocolVersion.incompatibility(serverVersion: 2, serverMinimum: 2, spoken: 1), .appTooOld
        )
    }

    func testAServerOlderThanThisBuildSupportsNeedsAServerUpdate() {
        XCTAssertEqual(
            ProtocolVersion.incompatibility(serverVersion: 1, serverMinimum: 1, spoken: 2, oldestServer: 2),
            .serverTooOld
        )
    }

    func testANewerServerThatStillServesThisBuildIsFine() {
        // Additive-only: a server ahead of the app keeps serving it until it raises its minimum.
        XCTAssertNil(ProtocolVersion.incompatibility(serverVersion: 3, serverMinimum: 1, spoken: 1))
    }

    func testTheShippedBuildTalksToTodaysServer() {
        // lurker's server/protocol.ts advertises 1 and 1.
        XCTAssertNil(ProtocolVersion.incompatibility(serverVersion: 1, serverMinimum: 1))
    }

    func testAMissingFieldIsNotAVersion() {
        // Read as 0, an absent `protocolVersion` would call every server too old the day this
        // build's minimum is raised.
        XCTAssertNil(ProtocolVersion.incompatibility(serverVersion: nil, serverMinimum: nil, oldestServer: 2))
        XCTAssertEqual(
            ProtocolVersion.incompatibility(serverVersion: nil, serverMinimum: 2, spoken: 1), .appTooOld,
            "each field says its own thing"
        )
    }

    // MARK: - /api/config

    func testTheConfigCarriesTheServersVersions() {
        let body = Data(#"{"edition":"node","protocolVersion":1,"minProtocolVersion":1,"features":{}}"#.utf8)
        let config = LurkerClient.parseConfig(body, code: 200)
        XCTAssertEqual(config?.protocolVersion, 1)
        XCTAssertEqual(config?.minProtocolVersion, 1)
        XCTAssertNil(config?.incompatibility)
    }

    func testAConfigThatRaisedItsMinimumRefusesThisBuild() {
        let body = Data(#"{"protocolVersion":2,"minProtocolVersion":2}"#.utf8)
        XCTAssertEqual(LurkerClient.parseConfig(body, code: 200)?.incompatibility, .appTooOld)
    }

    func testAConfigWithoutVersionsStatesNone() {
        let config = LurkerClient.parseConfig(Data("{}".utf8), code: 200)
        XCTAssertNotNil(config, "still an answer")
        XCTAssertNil(config?.protocolVersion)
        XCTAssertNil(config?.minProtocolVersion)
        XCTAssertNil(config?.incompatibility)
    }

    // MARK: - The socket

    func testEverySocketAnnouncesTheVersion() {
        // The server treats a missing `?v` as current, so a build that left it off could never
        // be told it's too old.
        XCTAssertEqual(
            LurkerClient.socketURL(baseURL: "https://app.lurker.chat", since: 0)?.absoluteString,
            "wss://app.lurker.chat/ws?v=1"
        )
        XCTAssertEqual(
            LurkerClient.socketURL(baseURL: "http://192.168.1.5:3000", since: 42)?.absoluteString,
            "ws://192.168.1.5:3000/ws?v=1&since=42"
        )
    }

    func testARefusedUpgradeWith426MeansThisBuildIsTooOld() {
        // Measured against wsHub's bytes (a bare status line, then a destroyed socket):
        // URLSessionWebSocketTask reports 426 in `task.response`, the same way it reports a 401.
        XCTAssertEqual(
            LurkerClient.closeFrame(status: 426, closeCode: 0, reason: "refused"), .incompatible(.appTooOld)
        )
    }

    func testOtherEndingsKeepTheirMeaning() {
        XCTAssertEqual(LurkerClient.closeFrame(status: 401, closeCode: 0, reason: "refused"), .unauthorized)
        XCTAssertEqual(LurkerClient.closeFrame(status: 101, closeCode: 4001, reason: "revoked"), .unauthorized)
        XCTAssertEqual(
            LurkerClient.closeFrame(status: 101, closeCode: 1001, reason: "dropped"),
            .socketClosed(reason: "dropped", code: 101)
        )
    }
}

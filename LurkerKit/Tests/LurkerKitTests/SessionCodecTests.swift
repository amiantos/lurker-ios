// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The Keychain-persisted session's JSON codec, tested without touching the Keychain.
/// A malformed / legacy blob must decode to nil (→ treated as no session) rather than
/// crashing. Mirrors the Android client's SessionCodecTest.
final class SessionCodecTests: XCTestCase {

    func testRoundTripsSelfHosted() {
        let session = PersistedSession(backend: .selfHosted, server: "http://localhost:8010", token: "abc123")
        let data = SessionCodec.encode(session)!
        XCTAssertEqual(SessionCodec.decode(data), session)
    }

    func testRoundTripsHosted() {
        let session = PersistedSession(backend: .hosted, server: "https://app.lurker.chat", token: "tok")
        let data = SessionCodec.encode(session)!
        XCTAssertEqual(SessionCodec.decode(data), session)
    }

    func testGarbageDecodesToNil() {
        XCTAssertNil(SessionCodec.decode(Data("not json at all".utf8)))
        XCTAssertNil(SessionCodec.decode(Data()))
    }

    func testAnUnknownBackendDecodesToNil() {
        // A dropped/renamed backend (e.g. the old direct-IRC mode) must not crash.
        let json = #"{"backend":"directIrc","server":"http://x","token":"t"}"#
        XCTAssertNil(SessionCodec.decode(Data(json.utf8)))
    }

    func testEmptyServerOrTokenDecodesToNil() {
        let noServer = #"{"backend":"selfHosted","server":"","token":"t"}"#
        let noToken = #"{"backend":"selfHosted","server":"http://x","token":""}"#
        XCTAssertNil(SessionCodec.decode(Data(noServer.utf8)))
        XCTAssertNil(SessionCodec.decode(Data(noToken.utf8)))
    }
}

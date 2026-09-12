// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The Keychain-persisted session's JSON codec, tested without touching the Keychain.
/// A malformed / legacy blob must decode to nil (→ treated as no session) rather than
/// crashing. Mirrors the Android client's SessionCodecTest.
final class SessionCodecTests: XCTestCase {

    func testRoundTrips() {
        let session = PersistedSession(server: "https://app.lurker.chat", token: "roswell~tok")
        let data = SessionCodec.encode(session)!
        XCTAssertEqual(SessionCodec.decode(data), session)
    }

    func testGarbageDecodesToNil() {
        XCTAssertNil(SessionCodec.decode(Data("not json at all".utf8)))
        XCTAssertNil(SessionCodec.decode(Data()))
    }

    /// The password sign-in's session, which carried a `backend`. It has to decode so the
    /// upgrade can end it on its server (`SessionStore.takeLegacySession`).
    func testAPasswordEraSessionDecodes() {
        let json = #"{"backend":"hosted","server":"https://app.lurker.chat","token":"old"}"#
        XCTAssertEqual(
            SessionCodec.decode(Data(json.utf8)),
            PersistedSession(server: "https://app.lurker.chat", token: "old")
        )
    }

    func testEmptyServerOrTokenDecodesToNil() {
        let noServer = #"{"server":"","token":"t"}"#
        let noToken = #"{"server":"http://x","token":""}"#
        XCTAssertNil(SessionCodec.decode(Data(noServer.utf8)))
        XCTAssertNil(SessionCodec.decode(Data(noToken.utf8)))
    }
}

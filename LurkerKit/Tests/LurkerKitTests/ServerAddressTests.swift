// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Locks the transport policy (#29) to ATS's own definition of "local": with
/// `NSAllowsLocalNetworking` as the app's only exception, everything this policy
/// passes must be loadable and everything it rejects must fail with our copy —
/// the two lists drifting apart is the bug these tests exist to catch.
final class ServerAddressTests: XCTestCase {

    // MARK: - Normalize

    func testNormalizeTrimsWhitespaceAndTrailingSlashes() {
        XCTAssertEqual(ServerAddress.normalize("  https://app.lurker.chat//  "), "https://app.lurker.chat")
    }

    func testASchemelessAddressDefaultsToHTTPSNotAParseError() {
        XCTAssertEqual(ServerAddress.normalize("chat.example.org"), "https://chat.example.org")
    }

    /// The host:port trap: `localhost:8010` parses as scheme "localhost", so scheme
    /// detection sniffs `://` instead. A bare host:port gets the secure default.
    func testHostColonPortIsSchemelessNotAScheme() {
        XCTAssertEqual(ServerAddress.normalize("localhost:8010"), "https://localhost:8010")
    }

    func testAnExplicitSchemeIsKept() {
        XCTAssertEqual(ServerAddress.normalize("http://localhost:8010"), "http://localhost:8010")
    }

    // MARK: - Policy: what passes

    func testHTTPSPassesAnywhere() {
        XCTAssertNil(ServerAddress.rejection(of: "https://app.lurker.chat"))
        XCTAssertNil(ServerAddress.rejection(of: "https://chat.example.org:8443"))
    }

    func testPlainHTTPPassesForApplesThreeLocalHostClasses() {
        // Unqualified single-label names.
        XCTAssertNil(ServerAddress.rejection(of: "http://localhost:8010"))
        XCTAssertNil(ServerAddress.rejection(of: "http://xerxes:8010"))
        // .local names (case-insensitively — DNS names have no case).
        XCTAssertNil(ServerAddress.rejection(of: "http://xerxes.local:8010"))
        XCTAssertNil(ServerAddress.rejection(of: "http://Xerxes.LOCAL:8010"))
        // IP literals, v4 and v6 (URLComponents strips the v6 brackets).
        XCTAssertNil(ServerAddress.rejection(of: "http://192.168.1.5:8010"))
        XCTAssertNil(ServerAddress.rejection(of: "http://[fe80::1]:8010"))
    }

    /// The defaults the sign-in screen prefills must both pass — a rejected default
    /// would dead-end the first-run experience.
    func testBothBackendDefaultURLsPassThePolicy() {
        for backend in Backend.allCases {
            XCTAssertNil(
                ServerAddress.rejection(of: ServerAddress.normalize(backend.defaultURL)),
                "\(backend) default must be signable"
            )
        }
    }

    // MARK: - Policy: what's rejected, and with what copy

    func testPlainHTTPToAQualifiedDomainIsRejectedWithTheHTTPSMessage() {
        let reason = ServerAddress.rejection(of: "http://chat.example.org")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("HTTPS"), "the copy must say what to do, not just refuse")
    }

    /// A near-miss like 999.1.2.3 isn't an IP to ATS either — it's a (dead) hostname.
    /// Passing it would promise a load the OS then blocks.
    func testAnOutOfRangeOctetIsAHostnameNotAnIPLiteral() {
        XCTAssertNotNil(ServerAddress.rejection(of: "http://999.1.2.3:8010"))
        XCTAssertNotNil(ServerAddress.rejection(of: "http://1.2.3.4.5:8010"))
    }

    func testEmptyAndUnparsableAddressesAreRejectedLegibly() {
        XCTAssertEqual(ServerAddress.rejection(of: ""), "Enter a server URL.")
        XCTAssertNotNil(ServerAddress.rejection(of: "https://"))
    }

    func testANonHTTPSchemeIsRejected() {
        XCTAssertNotNil(ServerAddress.rejection(of: "ftp://example.org"))
        XCTAssertNotNil(ServerAddress.rejection(of: "ws://localhost:8010"))
    }
}

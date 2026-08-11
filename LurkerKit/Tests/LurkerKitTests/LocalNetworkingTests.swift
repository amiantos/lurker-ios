// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest

@testable import LurkerKit

/// Which hosts `NSAllowsLocalNetworking` actually exempts — the rule `LinkPreview.isViewable`
/// admits cleartext by.
final class LocalNetworkingTests: XCTestCase {

    private func permits(_ host: String) -> Bool {
        LocalNetworking.permitsCleartext(host: host)
    }

    // MARK: - Permitted, because ATS permits them

    func testBonjourNames() {
        XCTAssertTrue(permits("box.local"))
        XCTAssertTrue(permits("BOX.LOCAL"))
    }

    /// ⚠ Exempt for having no dot in it, not for being called anything in particular — the
    /// exemption is about single-label names, so `notlocal` qualifies exactly as `box` does.
    func testSingleLabelNames() {
        XCTAssertTrue(permits("box"))
        XCTAssertTrue(permits("localhost"))
        XCTAssertTrue(permits("notlocal"))
    }

    func testPrivateAndMachineLocalAddresses() {
        for host in ["10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.9.9", "192.168.1.9",
                     "169.254.3.4", "127.0.0.1", "::1", "fd00::1", "fe80::1%en0"] {
            XCTAssertTrue(permits(host), "\(host) is on the local network")
        }
    }

    // MARK: - Refused, because ATS refuses them

    func testPublicNames() {
        XCTAssertFalse(permits("cdn.example.com"))
        XCTAssertFalse(permits("example.com"))
        // ⚠ The trap in `.local`: a name that merely CONTAINS it is a public name.
        XCTAssertFalse(permits("box.local.example.com"))
        XCTAssertFalse(permits("local.example.com"))
    }

    func testPublicAddresses() {
        for host in ["8.8.8.8", "172.32.0.1", "172.15.255.254", "192.169.1.1", "1.1.1.1",
                     "2606:4700::1111"] {
            XCTAssertFalse(permits(host), "\(host) is a public address")
        }
    }

    /// ⚠ A dotted string that isn't an address must not fall through to the single-label rule
    /// and be admitted as a "name".
    func testMalformedAddressesAreNotNames() {
        XCTAssertFalse(permits("1.2.3.four"))
        XCTAssertFalse(permits("10.0.0"))
        XCTAssertFalse(permits("10.0.0.999"))
        XCTAssertFalse(permits(""))
    }
}

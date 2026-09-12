// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// CertFP (#459) below the form: how a network row describes its certificate, the certificate a
/// create carries, and pulling a pair out of picked files.
@MainActor
final class ClientCertificateTests: XCTestCase {

    private static func row(certificate json: String) -> NetworkConfig? {
        FrameParser.parseNetworkReply(
            ##"{"network":{"id":1,"name":"n","host":"h","tls":true,"nick":"me","client_cert":\##(json)}}"##
        )
    }

    private static let cert = "-----BEGIN CERTIFICATE-----\nMIIC\n-----END CERTIFICATE-----"
    private static let key = "-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----"
    private static let rsaKey = "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----"

    private func draft() -> NetworkDraft {
        NetworkDraft(name: "Libera", host: "irc.libera.chat", port: 6697, tls: true, nick: "me")
    }

    // MARK: - Reading a row

    func testACertificateReadsItsExpiry() {
        let config = Self.row(certificate: ##"""
            {"sha256":"b2","sha1":"a1","sha512":"c5","subject":"CN=me",
             "validFrom":"2026-09-11T00:00:00.000Z","validTo":"2027-09-11T00:00:00.000Z"}
            """##)
        let expires = ISOTime.parse("2027-09-11T00:00:00.000Z")
        XCTAssertNotNil(expires)
        XCTAssertEqual(config?.clientCertificate, .usable(expires: expires))
    }

    func testAnUnreadableCertificateIsNotNoCertificate() {
        // ⚠⚠ The server says `{unusable: true}` for a pair that won't parse, which archive import
        // can produce without anyone pasting anything. It refuses to dial while that's attached,
        // so reading it as "no certificate" would offer Generate on a network whose problem is the
        // certificate it already has.
        XCTAssertEqual(Self.row(certificate: ##"{"unusable":true}"##)?.clientCertificate, .unusable)
    }

    func testNullAndAbsentBothMeanNoCertificate() {
        XCTAssertNil(Self.row(certificate: "null")?.clientCertificate)
        let absent = FrameParser.parseNetworkReply(##"{"network":{"id":1,"name":"n","host":"h"}}"##)
        XCTAssertNotNil(absent)
        XCTAssertNil(absent?.clientCertificate)
    }

    // MARK: - The create body

    func testAGeneratedCertificateRidesTheCreate() {
        // Attached before the first dial, which is the connect the user registers it from.
        var d = draft()
        d.certificate = .generate
        let body = d.jsonBody(creating: true)
        XCTAssertEqual(body["generate_client_cert"] as? Bool, true)
        XCTAssertNil(body["client_cert"])
        XCTAssertNil(body["client_key"])
    }

    func testAnImportedPairRidesTheCreate() {
        var d = draft()
        d.certificate = .imported(cert: Self.cert, key: Self.key)
        let body = d.jsonBody(creating: true)
        XCTAssertEqual(body["client_cert"] as? String, Self.cert)
        XCTAssertEqual(body["client_key"] as? String, Self.key)
        // The server refuses a body carrying both.
        XCTAssertNil(body["generate_client_cert"])
    }

    func testAnEditNeverCarriesACertificate() {
        // Once the network exists the certificate has routes of its own, and PATCH ignores these.
        var d = draft()
        d.certificate = .imported(cert: Self.cert, key: Self.key)
        let body = d.jsonBody(creating: false)
        for key in ["generate_client_cert", "client_cert", "client_key"] { XCTAssertNil(body[key], key) }
    }

    func testNoCertificateSendsNoCertificateKeys() {
        let body = draft().jsonBody(creating: true)
        for key in ["generate_client_cert", "client_cert", "client_key"] { XCTAssertNil(body[key], key) }
    }

    func testACertificateNeedsTLS() {
        var d = draft()
        d.certificate = .generate
        d.tls = false
        XCTAssertNotNil(d.validationError)
        d.tls = true
        XCTAssertNil(d.validationError)
        // TLS off with no certificate is still an ordinary network.
        d.certificate = nil
        d.tls = false
        XCTAssertNil(d.validationError)
    }

    // MARK: - Picked files (ported from shared/clientCertPem.test.ts)

    func testAClientPemReadsInEitherOrder() {
        for pem in ["\(Self.key)\n\(Self.cert)\n", "\(Self.cert)\n\(Self.key)\n"] {
            XCTAssertEqual(ClientCertificatePEM.reading(pem), .ready(.imported(cert: Self.cert, key: Self.key)))
        }
    }

    func testTheKeyLabelsOtherToolsWriteAreRead() {
        XCTAssertEqual(ClientCertificatePEM.parts(from: "\(Self.cert)\n\(Self.rsaKey)").key, Self.rsaKey)
    }

    func testTheLeafIsTakenOutOfAChain() {
        // A bundle with a chain presents the leaf, whose fingerprint services hold, so the first
        // certificate is the one.
        let issuer = "-----BEGIN CERTIFICATE-----\nISSUER\n-----END CERTIFICATE-----"
        XCTAssertEqual(ClientCertificatePEM.parts(from: "\(Self.cert)\n\(issuer)\n\(Self.key)").cert, Self.cert)
    }

    func testAKeyDoesNotMatchAcrossDifferentLabels() {
        // A truncated file must not pair a BEGIN with some later, unrelated END.
        XCTAssertEqual(ClientCertificatePEM.parts(from: "\(Self.cert)\n-----BEGIN RSA PRIVATE KEY-----\nMIIE\n").key, "")
        XCTAssertEqual(
            ClientCertificatePEM.parts(from: "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----").key, ""
        )
    }

    func testTwoPickedFilesMakeOnePair() {
        // cert.pem and key.pem picked together, joined the way the form joins them.
        XCTAssertEqual(
            ClientCertificatePEM.reading([Self.cert, Self.key].joined(separator: "\n")),
            .ready(.imported(cert: Self.cert, key: Self.key))
        )
    }

    func testAMissingHalfIsNamed() {
        guard case .refused(let noKey) = ClientCertificatePEM.reading(Self.cert),
              case .refused(let noCert) = ClientCertificatePEM.reading(Self.key),
              case .refused(let neither) = ClientCertificatePEM.reading("not a certificate")
        else { return XCTFail("expected every incomplete file to be refused") }
        XCTAssertTrue(noKey.contains("no private key"), noKey)
        XCTAssertTrue(noCert.contains("no certificate"), noCert)
        XCTAssertTrue(neither.contains("doesn't hold"), neither)
    }
}

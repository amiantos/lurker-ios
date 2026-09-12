// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// Proxies (#303) below the form: reading a saved proxy, what a draft sends and when, and the port
/// that follows the type.
@MainActor
final class NetworkProxyTests: XCTestCase {

    private static func row(proxy json: String) -> NetworkConfig? {
        FrameParser.parseNetworkReply(
            ##"{"network":{"id":1,"name":"n","host":"h","tls":true,"nick":"me","proxy":\##(json)}}"##
        )
    }

    private static let saved =
        ##"{"enabled":true,"type":"http","host":"127.0.0.1","port":3128,"username":"me","has_password":true}"##

    /// A fresh network, or one being edited whose `proxy` is `json`.
    private func draft(editing json: String? = nil) -> NetworkDraft {
        guard let json, let config = Self.row(proxy: json) else {
            return NetworkDraft(name: "Libera", host: "irc.libera.chat", port: 6697, tls: true, nick: "me")
        }
        return NetworkDraft(editing: config)
    }

    private func proxyKeys(_ body: [String: Any]) -> Set<String> {
        Set(body.keys.filter { $0.hasPrefix("proxy_") })
    }

    // MARK: - Reading a row

    func testASavedProxyReadsEveryPart() {
        XCTAssertEqual(
            Self.row(proxy: Self.saved)?.proxy,
            NetworkProxy(enabled: true, type: .http, host: "127.0.0.1", port: 3128, username: "me", hasPassword: true)
        )
    }

    func testNullAndAbsentBothMeanNoProxy() {
        XCTAssertNil(Self.row(proxy: "null")?.proxy)
        let absent = FrameParser.parseNetworkReply(##"{"network":{"id":1,"name":"n","host":"h"}}"##)
        XCTAssertNotNil(absent)
        XCTAssertNil(absent?.proxy)
    }

    func testASwitchedOffProxyIsStillASavedOne() {
        // `enabled` is the only part the dial reads; the details stay saved while it's off.
        let proxy = Self.row(
            proxy: ##"{"enabled":false,"type":"socks5","host":"127.0.0.1","port":9050,"username":null,"has_password":false}"##
        )?.proxy
        XCTAssertNotNil(proxy)
        XCTAssertEqual(proxy?.enabled, false)
        XCTAssertEqual(proxy?.port, 9050)
    }

    func testAnImpossiblePortReadsAsTheTypesDefault() {
        XCTAssertEqual(Self.row(proxy: ##"{"enabled":false,"type":"http","host":"h","port":null}"##)?.proxy?.port, 3128)
    }

    // MARK: - What a draft sends

    func testEditingStartsFromTheSavedProxyButNotItsPassword() {
        let d = draft(editing: Self.saved)
        XCTAssertNotNil(d.savedProxy)
        XCTAssertEqual(d.savedProxy, Self.row(proxy: Self.saved)?.proxy)
        XCTAssertEqual(d.proxy, ProxyDraft(enabled: true, type: .http, host: "127.0.0.1", port: 3128, username: "me"))
        XCTAssertEqual(d.proxy.password, .unchanged)
    }

    func testAnOrdinaryNetworkSendsNoProxyKeys() {
        // ⚠ Not even `proxy_enabled: false`. A save with nothing to say about a proxy says nothing,
        // so a rename carries nothing for a locked-down instance's proxy rule to weigh.
        XCTAssertEqual(proxyKeys(draft().jsonBody(creating: true)), [])
        XCTAssertEqual(proxyKeys(draft(editing: "null").jsonBody(creating: false)), [])
    }

    func testSwitchingASavedProxyOffSendsOnlyTheSwitch() {
        // Turning a proxy off must always be possible, so it's sent on its own — nothing else in
        // the body for the server to refuse.
        var d = draft(editing: Self.saved)
        d.proxy.enabled = false
        let body = d.jsonBody(creating: false)
        XCTAssertEqual(proxyKeys(body), ["proxy_enabled"])
        XCTAssertEqual(body["proxy_enabled"] as? Bool, false)
    }

    func testAnEnabledProxySendsTheWholeSet() {
        var d = draft()
        d.proxy = ProxyDraft(enabled: true, host: " 127.0.0.1 ", port: 9050)
        let body = d.jsonBody(creating: true)
        XCTAssertEqual(body["proxy_enabled"] as? Bool, true)
        XCTAssertEqual(body["proxy_type"] as? String, "socks5")
        XCTAssertEqual(body["proxy_host"] as? String, "127.0.0.1")
        XCTAssertEqual(body["proxy_port"] as? Int, 9050)
        // Null rather than "", matching the other optional text columns.
        XCTAssertTrue(body["proxy_username"] is NSNull)
        XCTAssertNil(body["proxy_password"])
    }

    func testAnUntouchedProxyIsNotSent() {
        // ⚠⚠ Not even resent as read. The form shows the columns normalized — trimmed, and an
        // unknown type or impossible port read as a default — so resending what's shown would
        // rewrite whatever archive import left there, on a rename, which a locked-down instance
        // then refuses as a proxy change.
        XCTAssertEqual(proxyKeys(draft(editing: Self.saved).jsonBody(creating: false)), [])
        let odd = ##"{"enabled":true,"type":"socks4","host":" 127.0.0.1 ","port":99999,"username":" me "}"##
        XCTAssertEqual(proxyKeys(draft(editing: odd).jsonBody(creating: false)), [])
    }

    func testAnUntouchedProxyIsNotValidated() {
        // Nothing of it is sent, so whatever the columns hold mustn't block saving the rest.
        XCTAssertNil(draft(editing: ##"{"enabled":true,"type":"socks5","host":"","port":1080}"##).validationError)
    }

    func testEditingASavedProxySendsTheWholeSetAsShown() {
        var d = draft(editing: ##"{"enabled":true,"type":"socks5","host":" 127.0.0.1 ","port":9050,"username":" me "}"##)
        d.proxy.port = 9150
        let body = d.jsonBody(creating: false)
        XCTAssertEqual(body["proxy_enabled"] as? Bool, true)
        XCTAssertEqual(body["proxy_type"] as? String, "socks5")
        XCTAssertEqual(body["proxy_host"] as? String, "127.0.0.1")
        XCTAssertEqual(body["proxy_port"] as? Int, 9150)
        XCTAssertEqual(body["proxy_username"] as? String, "me")
    }

    func testTurningAProxyOffAndOnAgainIsNoChange() {
        var d = draft(editing: Self.saved)
        d.proxy.enabled = false
        d.proxy.enabled = true
        XCTAssertEqual(proxyKeys(d.jsonBody(creating: false)), [])
    }

    func testTheProxyPasswordFollowsSecretEdit() {
        var d = draft(editing: Self.saved)
        d.proxy.password = .set("hunter2")
        XCTAssertEqual(d.jsonBody(creating: false)["proxy_password"] as? String, "hunter2")
        d.proxy.password = .cleared
        XCTAssertTrue(d.jsonBody(creating: false)["proxy_password"] is NSNull)
    }

    func testAnEnabledProxyNeedsAnAddressAndAPort() {
        var d = draft()
        d.proxy = ProxyDraft(enabled: true, host: "  ")
        XCTAssertNotNil(d.validationError)
        d.proxy.host = "127.0.0.1"
        XCTAssertNil(d.validationError)
        d.proxy.port = 0
        XCTAssertNotNil(d.validationError)
        d.proxy.port = 70000
        XCTAssertNotNil(d.validationError)
    }

    func testASwitchedOffProxyIsNotValidated() {
        // None of it is sent, so a half-finished one mustn't block saving everything else.
        var d = draft()
        d.proxy = ProxyDraft(enabled: false, host: "", port: 0)
        XCTAssertNil(d.validationError)
    }

    func testTheBodyIsEncodable() {
        var d = draft()
        d.proxy = ProxyDraft(enabled: true, host: "127.0.0.1", password: .cleared)
        d.certificate = .imported(cert: "c", key: "k")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(d.jsonBody(creating: true)))
    }

    // MARK: - Type and port

    func testANewProxyStartsOnTheSocksPort() {
        XCTAssertEqual(ProxyDraft().port, 1080)
    }

    func testAnUntouchedDefaultPortFollowsTheType() {
        // Otherwise picking HTTP would quietly keep SOCKS's 1080.
        var proxy = ProxyDraft()
        proxy.setType(.http)
        XCTAssertEqual(proxy.port, 3128)
        proxy.setType(.socks5)
        XCTAssertEqual(proxy.port, 1080)
    }

    func testAChosenPortSurvivesATypeChange() {
        var proxy = ProxyDraft(port: 9050)
        proxy.setType(.http)
        XCTAssertEqual(proxy.type, .http)
        XCTAssertEqual(proxy.port, 9050)
    }
}

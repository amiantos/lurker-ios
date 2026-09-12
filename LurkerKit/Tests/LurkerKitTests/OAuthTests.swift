// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The OAuth sign-in's requests and replies, against the shapes lurker's server sends and
/// accepts (`server/services/oauth.ts`, `server/routes/oauth.ts`).
final class OAuthTests: XCTestCase {

    // MARK: - PKCE

    func testTheChallengeMatchesRFC7636sExample() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    /// The server's rules: a verifier is 43–128 of `[A-Za-z0-9._~-]`, a challenge 43 of base64url.
    func testAFreshPairIsOneTheServerAccepts() {
        let pkce = PKCE()
        XCTAssertNotNil(pkce.verifier.range(of: #"^[A-Za-z0-9._~-]{43,128}$"#, options: .regularExpression))
        XCTAssertNotNil(pkce.challenge.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression))
        XCTAssertNotEqual(PKCE().verifier, pkce.verifier)
    }

    // MARK: - Register

    func testRegistrationNamesTheAppAndItsRedirect() throws {
        let request = try XCTUnwrap(
            OAuth.registrationRequest(server: "https://app.lurker.chat", clientName: "Lurker for iPhone")
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://app.lurker.chat/api/oauth/register")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["client_name"] as? String, "Lurker for iPhone")
        XCTAssertEqual(body["client_uri"] as? String, "https://lurker.chat")
        XCTAssertEqual(body["redirect_uris"] as? [String], ["chat.lurker:/oauth"])
    }

    func testARegistrationYieldsItsClientId() {
        let data = Data(#"{"client_id":"abc_123","client_name":"Lurker for iPhone"}"#.utf8)
        XCTAssertEqual(OAuth.registration(status: 201, data: data), .registered(clientId: "abc_123"))
    }

    func testARefusedRegistrationSaysWhy() {
        guard case .failure(let old) = OAuth.registration(status: 404, data: Data()) else { return XCTFail() }
        XCTAssertTrue(old.contains("2.3.0"), "a server without OAuth should say which version has it")
        guard case .failure(let busy) = OAuth.registration(status: 429, data: Data()) else { return XCTFail() }
        XCTAssertTrue(busy.contains("Try again"))
        // A 2xx that names no client isn't a registration.
        guard case .failure = OAuth.registration(status: 201, data: Data("{}".utf8)) else { return XCTFail() }
    }

    // MARK: - Authorize

    func testTheApprovalPageCarriesEveryParameter() throws {
        let url = try XCTUnwrap(OAuth.authorizeURL(
            server: "https://app.lurker.chat",
            clientId: "roswell~a+b",
            challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            state: "st_1-x"
        ))
        XCTAssertEqual(url.host, "app.lurker.chat")
        XCTAssertEqual(url.path, "/oauth/authorize")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "response_type": "code",
            "client_id": "roswell~a+b",
            "redirect_uri": "chat.lurker:/oauth",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "state": "st_1-x",
        ])
        // The server's query parser reads a bare `+` as a space.
        XCTAssertTrue(url.absoluteString.contains("client_id=roswell~a%2Bb"))
    }

    /// The redirect exactly as the server's `withQuery` builds it, which escapes `~`.
    func testTheServersRedirectYieldsItsCode() throws {
        let url = try XCTUnwrap(URL(string: "chat.lurker:/oauth?code=roswell%7Ea_b-c&state=st_1-x"))
        XCTAssertEqual(OAuth.callback(url, state: "st_1-x"), .code("roswell~a_b-c"))
    }

    func testDenyIsItsOwnAnswer() throws {
        let url = try XCTUnwrap(URL(string: "chat.lurker:/oauth?error=access_denied&state=st_1-x"))
        XCTAssertEqual(OAuth.callback(url, state: "st_1-x"), .denied)
    }

    func testAnAnswerToAnotherAttemptIsRefused() throws {
        let otherState = try XCTUnwrap(URL(string: "chat.lurker:/oauth?code=abc&state=other"))
        XCTAssertEqual(OAuth.callback(otherState, state: "st_1-x"), .invalid)
        let noState = try XCTUnwrap(URL(string: "chat.lurker:/oauth?code=abc"))
        XCTAssertEqual(OAuth.callback(noState, state: "st_1-x"), .invalid)
        let noCode = try XCTUnwrap(URL(string: "chat.lurker:/oauth?state=st_1-x"))
        XCTAssertEqual(OAuth.callback(noCode, state: "st_1-x"), .invalid)
    }

    // MARK: - Exchange

    func testTheExchangeSendsWhatTheServerChecks() throws {
        let request = try XCTUnwrap(OAuth.tokenRequest(
            server: "https://app.lurker.chat", clientId: "cid", code: "roswell~code", verifier: "ver"
        ))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://app.lurker.chat/api/oauth/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(body, [
            "grant_type": "authorization_code",
            "client_id": "cid",
            "code": "roswell~code",
            "redirect_uri": "chat.lurker:/oauth",
            "code_verifier": "ver",
        ])
    }

    func testATokenReplyYieldsTheToken() {
        let data = Data(#"{"access_token":"roswell~tok","token_type":"Bearer","created_at":1757462400}"#.utf8)
        XCTAssertEqual(OAuth.tokenGrant(status: 200, data: data), .token("roswell~tok"))
    }

    /// `invalid_client` means register again, which a plain retry would never do.
    func testAnUnknownClientIsItsOwnAnswer() {
        let data = Data(#"{"error":"invalid_client","error_description":"unknown client_id"}"#.utf8)
        XCTAssertEqual(OAuth.tokenGrant(status: 401, data: data), .unknownClient)
    }

    func testASpentCodeIsAFailure() {
        let data = Data(#"{"error":"invalid_grant","error_description":"the code is invalid"}"#.utf8)
        XCTAssertEqual(OAuth.tokenGrant(status: 400, data: data), .failure("Sign-in didn't finish. Try again."))
        guard case .failure = OAuth.tokenGrant(status: 200, data: Data("{}".utf8)) else { return XCTFail() }
    }

    // MARK: - Check a saved registration

    func testTheCheckAsksRevokeWithATokenThatCantExist() throws {
        let request = try XCTUnwrap(OAuth.clientCheckRequest(server: "https://app.lurker.chat", clientId: "cid"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://app.lurker.chat/api/oauth/revoke")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(body["client_id"], "cid")
        let token = try XCTUnwrap(body["token"])
        XCTAssertEqual(token.count, 43)
        // lurker.chat forwards a revoke to a cell only for a `<cell>~` token; this one must go nowhere.
        XCTAssertFalse(token.contains("~"))
    }

    func testTheCheckTellsKnownFromUnknownFromNoAnswer() {
        XCTAssertEqual(OAuth.clientKnown(status: 200, data: Data("{}".utf8)), true)
        let unknown = Data(#"{"error":"invalid_client","error_description":"unknown client_id"}"#.utf8)
        XCTAssertEqual(OAuth.clientKnown(status: 401, data: unknown), false)
        // No OAuth routes at all, so registering again gets to say the server is too old.
        XCTAssertEqual(OAuth.clientKnown(status: 404, data: Data()), false)
        // A throttled, failing or unreachable server says nothing about the registration.
        XCTAssertNil(OAuth.clientKnown(status: 429, data: Data()))
        XCTAssertNil(OAuth.clientKnown(status: 503, data: Data()))
        XCTAssertNil(OAuth.clientKnown(status: 0, data: Data()))
    }

    // MARK: - Saved registrations

    func testRegistrationsAreKeptPerServer() throws {
        let suite = "chat.lurker.tests.oauth-clients"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clients = OAuthClients(defaults: defaults)

        XCTAssertNil(clients.clientId(for: "https://app.lurker.chat"))
        clients.save("hosted", for: "https://app.lurker.chat")
        clients.save("home", for: "http://xerxes.local:8010")
        clients.forget("https://app.lurker.chat")
        XCTAssertNil(clients.clientId(for: "https://app.lurker.chat"))
        XCTAssertEqual(clients.clientId(for: "http://xerxes.local:8010"), "home")
    }
}

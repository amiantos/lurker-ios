// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation

/// Sign-in through the server's OAuth approval page, the one way this app gets a token
/// (lurker docs/OAUTH.md). The app registers itself with a server once, opens
/// `/oauth/authorize` in a browser sheet where the member signs in and approves, and trades
/// the code the page sends back for a token that lasts until it's revoked. lurker.chat
/// answers at the same paths as a self-hosted server, so nothing here branches on which.
///
/// Requests and replies only, so they're tested without a server. `LurkerClient` sends them,
/// and `ChatViewModel.signIn` runs the steps in order.
public enum OAuth {
    /// The redirect's scheme: lurker.chat reversed (RFC 8252 §7.1). The approval page shows
    /// it ("Opens chat.lurker:"), so it names the product rather than a bundle ID.
    public static let callbackScheme = "chat.lurker"
    static let redirectURI = callbackScheme + ":/oauth"
    /// The approval page shows this address's host as where the app says it's from.
    static let clientURI = "https://lurker.chat"

    // MARK: - Register

    enum Registration: Equatable {
        case registered(clientId: String)
        case failure(String)
    }

    /// `POST /api/oauth/register` (RFC 7591).
    static func registrationRequest(server: String, clientName: String) -> URLRequest? {
        guard let url = URL(string: server + "/api/oauth/register") else { return nil }
        return jsonPost(url, [
            "client_name": clientName,
            "client_uri": clientURI,
            "redirect_uris": [redirectURI],
        ])
    }

    static func registration(status: Int, data: Data) -> Registration {
        if (200..<300).contains(status), let id = json(data)?["client_id"] as? String, !id.isEmpty {
            return .registered(clientId: id)
        }
        switch status {
        case 404:
            return .failure("This server doesn't support app sign-in. It needs Lurker 2.3.0 or newer.")
        case 429:
            // Both of the server's 429s: this address registered too often, or too many
            // registrations are waiting for approval.
            return .failure("Too many sign-in attempts right now. Try again in a few minutes.")
        default:
            return .failure("Sign-in failed (HTTP \(status)).")
        }
    }

    // MARK: - Authorize

    /// The approval page for one attempt. Values are escaped down to RFC 3986's unreserved
    /// characters: `URLComponents` leaves `+` alone, and the server reads it as a space.
    static func authorizeURL(server: String, clientId: String, challenge: String, state: String) -> URL? {
        let query = [
            ("response_type", "code"),
            ("client_id", clientId),
            ("redirect_uri", redirectURI),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        .map { name, value in "\(name)=\(escape(value))" }
        .joined(separator: "&")
        return URL(string: server + "/oauth/authorize?" + query)
    }

    enum Callback: Equatable {
        case code(String)
        /// The member chose Deny.
        case denied
        /// Not an answer to this attempt: another attempt's `state`, or no code.
        case invalid
    }

    /// Where the approval page sent the browser. `access_denied` is the only error it ever
    /// sends; anything else that goes wrong is shown on the page itself.
    static func callback(_ url: URL, state: String) -> Callback {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { return .invalid }
        if value("error") == "access_denied" { return .denied }
        guard let code = value("code"), !code.isEmpty else { return .invalid }
        return .code(code)
    }

    // MARK: - Exchange

    enum TokenGrant: Equatable {
        case token(String)
        /// The server doesn't know the `client_id`, so the app has to register again.
        case unknownClient
        case failure(String)
    }

    /// `POST /api/oauth/token`, as JSON, which the server takes as well as a form.
    static func tokenRequest(server: String, clientId: String, code: String, verifier: String) -> URLRequest? {
        guard let url = URL(string: server + "/api/oauth/token") else { return nil }
        return jsonPost(url, [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
    }

    static func tokenGrant(status: Int, data: Data) -> TokenGrant {
        let body = json(data)
        if (200..<300).contains(status), let token = body?["access_token"] as? String, !token.isEmpty {
            return .token(token)
        }
        // A 401 from this endpoint refuses the client, never the member.
        if status == 401, body?["error"] as? String == "invalid_client" { return .unknownClient }
        // `invalid_grant` spends the code, so the only way on is a new attempt.
        if status == 400 { return .failure("Sign-in didn't finish. Try again.") }
        return .failure("Sign-in failed (HTTP \(status)).")
    }

    // MARK: - Check a saved registration

    /// `POST /api/oauth/revoke` with a token that can't exist. RFC 7009 has the server answer
    /// 200 for any client it knows, token or not, and `invalid_client` for one it doesn't, so
    /// this is the one unauthenticated way to ask whether a `client_id` still exists. It revokes
    /// nothing: the token is fresh random bytes, with no `<cell>~` prefix to route on.
    static func clientCheckRequest(server: String, clientId: String) -> URLRequest? {
        guard let url = URL(string: server + "/api/oauth/revoke") else { return nil }
        return jsonPost(url, ["client_id": clientId, "token": randomString()])
    }

    /// Whether the server still knows the client. A 404 counts as no: the server has no OAuth
    /// routes (older than 2.3.0, or downgraded), and registering again is what says so. Nil when
    /// the answer says neither (a network failure, a 429, a 5xx), which is no reason to throw a
    /// registration away.
    static func clientKnown(status: Int, data: Data) -> Bool? {
        if (200..<300).contains(status) { return true }
        if status == 404 { return false }
        if status == 401, json(data)?["error"] as? String == "invalid_client" { return false }
        return nil
    }

    // MARK: - Helpers

    /// 32 random bytes as base64url: 43 characters, fit for a PKCE verifier or a `state`.
    /// `UInt8.random` draws from the system generator, which is a CSPRNG on Apple platforms.
    static func randomString() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func jsonPost(_ url: URL, _ body: [String: Any]) -> URLRequest? {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        return request
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// One attempt's PKCE pair (RFC 7636, S256). The verifier stays on the device until the
/// exchange, so a code intercepted on its way back to the app is useless on its own.
struct PKCE {
    let verifier: String
    let challenge: String

    init(verifier: String = OAuth.randomString()) {
        self.verifier = verifier
        challenge = OAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

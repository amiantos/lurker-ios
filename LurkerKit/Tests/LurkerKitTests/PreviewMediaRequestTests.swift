// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

// How a `LinkPreview`'s `src`/`thumb` becomes a request.
//
// ⚠⚠ The value is OPAQUE — the server mints it and a client never constructs or parses one.
// It arrives as either a proxy path on this instance or, when the instance has a bucket-backed
// preview byte cache turned on, an absolute URL on that bucket's public CDN. Both come through
// the same field with nothing to distinguish them, so the one place that interprets it has to
// handle both, and neither case is visible from `fetchProxiedMedia` — it only ever answers
// `Data?`, so a wrong URL and an offline server look identical.

import XCTest
@testable import LurkerKit

final class PreviewMediaRequestTests: XCTestCase {
    private let base = "https://chat.example.com"
    private let token = "session-token-abc"

    private func request(_ path: String, token: String? = "session-token-abc") -> URLRequest? {
        LurkerClient.mediaRequest(for: path, baseURL: base, token: token)
    }

    func testProxyPathIsResolvedAgainstTheInstanceAndCarriesTheBearerToken() {
        let request = request("/api/link-preview/media/abc123")
        XCTAssertEqual(
            request?.url?.absoluteString,
            "https://chat.example.com/api/link-preview/media/abc123"
        )
        // The proxy is authenticated and native auth is a Bearer header, not a cookie.
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Authorization"),
            "Bearer session-token-abc"
        )
    }

    func testAbsoluteUrlIsUsedAsIsRatherThanConcatenated() {
        // ⚠⚠ The regression this file exists for. Concatenating unconditionally produced
        // "https://chat.example.comhttps://cdn.example.com/..." — which `URL(string:)` rejects,
        // so the fetch returned nil and `PreviewImageLoader` latched the path into `failed`.
        // Every cached preview went permanently blank for the rest of the session, with no
        // error surfaced anywhere and nothing in the UI to retry.
        let cdn = "https://cdn.example.com/previews/9f86d081884c7d659a2feaa0c55ad015"
        let request = request(cdn)
        XCTAssertEqual(request?.url?.absoluteString, cdn)
    }

    func testAbsoluteUrlNeverCarriesTheSessionToken() {
        // ⚠⚠ A cached object lives on a host we do not control, and `URLSession` sends whatever
        // headers it is handed. A Bearer header here would put the user's session token into a
        // CDN operator's access log on every single image fetch — for a request that does not
        // need it, since the object is public by construction.
        let request = request("https://cdn.example.com/previews/9f86d081884c7d659a2feaa0c55ad015")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
    }

    func testNonHttpSchemesAreRefused() {
        // The value is server-minted, so this is not a threat so much as a floor: if a scheme
        // ever appears that is not http(s), fetching it is not the safe reading. `file:` in
        // particular would have `URLSession` read the device's own filesystem.
        for path in ["file:///etc/passwd", "data:image/png;base64,AAAA", "ftp://example.com/x"] {
            XCTAssertNil(request(path), "should refuse \(path)")
        }
    }

    func testProxyPathStillNeedsATokenButAnAbsoluteUrlDoesNot() {
        // A signed-out client cannot fetch from the proxy — there is no header to send — but a
        // public CDN object needs nothing, so it must not be gated on the session.
        XCTAssertNil(request("/api/link-preview/media/abc123", token: nil))
        XCTAssertEqual(
            request("https://cdn.example.com/previews/abc", token: nil)?.url?.absoluteString,
            "https://cdn.example.com/previews/abc"
        )
    }
}

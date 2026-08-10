// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// One unrecognised element must not discard the batch it arrived in.
@Suite("Preview response decoding")
struct PreviewDecodeTests {

    /// ⚠⚠ The SHIPPED function, not a rebuilt envelope. The first version of this suite decoded
    /// its own `[FailableDecodable<LinkPreview>]`, which passed happily against a client that had
    /// gone back to an all-or-nothing array decode — it was asserting a fact about
    /// `FailableDecodable`, not about what the client does with it. The drill caught it.
    private func decode(_ json: String) -> [LinkPreview] {
        LurkerClient.decodePreviews(Data(json.utf8))
    }

    @Test("a descriptor with an unknown kind costs its own row and nothing else")
    func unknownKindDoesNotDiscardTheBatch() {
        // ⚠⚠ `kind` and `status` are non-optional raw-value enums with no unknown case, so a
        // plain `[LinkPreview]` decode is all-or-nothing: one descriptor from a newer instance
        // throws and takes all twenty with it. One layer up that is indistinguishable from a
        // transport failure, so the store arms the whole batch for retry — and because a decode
        // failure is deterministic, every retry fails identically. Nineteen good previews never
        // render and all twenty poll to the ceiling forever.
        //
        // It cannot fire against today's server, whose union matches the enum exactly. It is
        // pinned because this is a self-hosted product: operators upgrade on their own schedule
        // and App Store builds lag, and the repo treats that skew as normal everywhere else.
        let got = decode(
            """
            {"previews":[
              {"url":"https://e.test/a","status":"ok","kind":"image"},
              {"url":"https://e.test/b","status":"ok","kind":"hologram"},
              {"url":"https://e.test/c","status":"ok","kind":"page"}
            ]}
            """)
        #expect(got.map(\.url) == ["https://e.test/a", "https://e.test/c"])
    }

    @Test("an unknown status is contained the same way")
    func unknownStatusDoesNotDiscardTheBatch() {
        let got = decode(
            """
            {"previews":[
              {"url":"https://e.test/a","status":"quarantined","kind":"page"},
              {"url":"https://e.test/b","status":"ok","kind":"page"}
            ]}
            """)
        #expect(got.map(\.url) == ["https://e.test/b"])
    }

    @Test("a well-formed batch is unaffected")
    func happyPathIsUnchanged() {
        let got = decode(
            """
            {"previews":[
              {"url":"https://e.test/a","status":"ok","kind":"image","thumbWidth":1200},
              {"url":"https://e.test/b","status":"unavailable","kind":"page"}
            ]}
            """)
        #expect(got.count == 2)
        #expect(got[0].thumbWidth == 1200)
    }

    // MARK: - Feature flags

    @Test("a failed or malformed answer is UNKNOWN, not 'the server says no'")
    func failureIsNotAVerdict() {
        // ⚠⚠ These collapsed into an all-off value, so one 502 or DNS hiccup on the single
        // /api/config call at cold launch silently disabled link previews for the whole app
        // session on an instance that has them on — with no retry and nothing to notice. A
        // default is not a statement.
        #expect(LurkerClient.parseFeatures(Data("{}".utf8), code: 502) == nil)
        #expect(LurkerClient.parseFeatures(Data("not json".utf8), code: 200) == nil)
        #expect(LurkerClient.parseFeatures(Data("[]".utf8), code: 200) == nil)
    }

    @Test("an absent features object IS an answer — an older instance without the feature")
    func absentFeaturesIsAVerdict() {
        #expect(LurkerClient.parseFeatures(Data("{}".utf8), code: 200)?.linkPreviews == false)
        #expect(
            LurkerClient.parseFeatures(Data("{\"features\":{}}".utf8), code: 200)?.linkPreviews
                == false)
    }

    @Test("the config request carries the session token, or hosted can't route it")
    func configRequestIsAuthenticated() {
        // ⚠⚠ The server documents this endpoint as public and unauthenticated, and that is true
        // of a self-hosted instance and false of a hosted one: on lurker.chat the control plane
        // proxies /api/* to a CELL and works out which one from the caller's session. Anonymous,
        // it answers 401 "not routable" — read (correctly) as "no answer", which left link
        // previews off forever on the deployment most people use, with the settings rows hidden
        // so nothing on screen suggested anything was wrong. The browser never noticed: its
        // fetch carries the session cookie.
        let request = LurkerClient.configRequest(baseURL: "https://app.lurker.chat", token: "t0k")
        #expect(request?.url?.absoluteString == "https://app.lurker.chat/api/config")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    }

    @Test("and asks anonymously before there is a session, which self-hosted allows")
    func configRequestWithoutATokenIsStillValid() {
        let request = LurkerClient.configRequest(baseURL: "https://irc.example", token: nil)
        #expect(request != nil)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("reads the flag when the server sets it")
    func flagIsRead() {
        let on = Data("{\"features\":{\"linkPreviews\":true}}".utf8)
        #expect(LurkerClient.parseFeatures(on, code: 200)?.linkPreviews == true)
        let off = Data("{\"features\":{\"linkPreviews\":false}}".utf8)
        #expect(LurkerClient.parseFeatures(off, code: 200)?.linkPreviews == false)
    }
}

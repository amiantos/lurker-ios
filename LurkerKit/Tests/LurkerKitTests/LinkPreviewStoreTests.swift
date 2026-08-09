// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Testing

@testable import LurkerKit

/// Behaviour of the client-side preview store, with the resolver stubbed.
///
/// The failure cases are the point. Two of these are regression guards for findings that made
/// links permanently blank for a whole app session — the kind of bug that reads as "the feature
/// doesn't work" rather than as an error.
@Suite("LinkPreviewStore")
@MainActor
struct LinkPreviewStoreTests {

    /// Records what was asked for, and answers with whatever the test dictates.
    final class Stub {
        var batches: [[String]] = []
        var answer: ([String]) -> [LinkPreview] = { urls in
            urls.map { LinkPreview(url: $0, status: .ok, kind: .image, src: "/proxy/\($0)") }
        }
    }

    private func makeStore(_ stub: Stub) -> LinkPreviewStore {
        LinkPreviewStore { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }
    }

    /// The store coalesces on a short timer, so tests have to let it fire.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    @Test("resolves what it's asked for and serves it back")
    func resolves() async {
        let stub = Stub()
        let store = makeStore(stub)
        store.request(["https://e.test/a.png"])
        await settle()
        #expect(store.preview(for: "https://e.test/a.png")?.src == "/proxy/https://e.test/a.png")
    }

    @Test("coalesces a batch into one call rather than one per URL")
    func coalesces() async {
        let stub = Stub()
        let store = makeStore(stub)
        store.request(["https://e.test/1", "https://e.test/2", "https://e.test/3"])
        await settle()
        #expect(stub.batches.count == 1)
        #expect(stub.batches.first?.count == 3)
    }

    @Test("asks about a repeated URL only once")
    func dedupes() async {
        let stub = Stub()
        let store = makeStore(stub)
        store.request(["https://e.test/x", "https://e.test/x"])
        await settle()
        store.request(["https://e.test/x"])
        await settle()
        #expect(stub.batches.flatMap { $0 } == ["https://e.test/x"])
    }

    @Test("a failed batch is retried later, not remembered as a verdict")
    func failureIsRetryable() async {
        // ⚠⚠ Regression guard. `asked` used to retain a URL whatever came back, and the client
        // maps any non-2xx (including a 429, which the connect-time backlog burst can provoke on
        // its own) to an empty array. So one throttled batch meant those links were blank for the
        // rest of the app session. A transport failure says nothing about the URL.
        let stub = Stub()
        stub.answer = { _ in [] }
        let store = makeStore(stub)

        store.request(["https://e.test/a", "https://e.test/b"])
        await settle()
        #expect(stub.batches.count == 1)
        #expect(store.preview(for: "https://e.test/a") == nil)

        // Server recovers; the next priming pass must be allowed to ask again.
        stub.answer = { urls in
            urls.map { LinkPreview(url: $0, status: .ok, kind: .page, title: "T") }
        }
        store.request(["https://e.test/a", "https://e.test/b"])
        await settle()
        #expect(stub.batches.count == 2)
        #expect(store.preview(for: "https://e.test/a")?.title == "T")
    }

    @Test("an `unavailable` answer IS remembered, unlike a failure")
    func unavailableIsRemembered() async {
        // The distinction that matters: the server negative-caches a genuine per-URL failure
        // itself, so re-asking would be a pointless loop. Only TRANSPORT failures are retried.
        let stub = Stub()
        stub.answer = { urls in urls.map { LinkPreview(url: $0, status: .unavailable, kind: .page) } }
        let store = makeStore(stub)

        store.request(["https://e.test/gone"])
        await settle()
        store.request(["https://e.test/gone"])
        await settle()
        #expect(stub.batches.count == 1)
    }

    @Test("splits a batch past the server's per-request cap")
    func splitsLargeBatch() async {
        let stub = Stub()
        let store = makeStore(stub)
        store.request((0..<25).map { "https://e.test/\($0)" })
        // Batches after the first are paced, so this needs longer than the coalesce window.
        try? await Task.sleep(for: .milliseconds(900))
        #expect(stub.batches.count == 2)
        #expect(stub.batches[0].count == 20)
        #expect(stub.batches[1].count == 5)
    }

    @Test("reset drops everything, so a new account starts clean")
    func resetClears() async {
        let stub = Stub()
        let store = makeStore(stub)
        store.request(["https://e.test/a"])
        await settle()
        #expect(store.preview(for: "https://e.test/a") != nil)

        store.reset()
        #expect(store.preview(for: "https://e.test/a") == nil)

        // And `asked` cleared too, so the next account's server is actually consulted.
        store.request(["https://e.test/a"])
        await settle()
        #expect(stub.batches.count == 2)
    }
}

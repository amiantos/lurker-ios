// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The requests themselves, against a loopback server: what a 503 from each feed read comes back
/// as (lurker#1308), and which route each way of removing an upload asks for (lurker#1295). The
/// rules these calls apply are tested where they live; this is that the calls apply them.
@MainActor
final class FeedRequestTests: XCTestCase {
    private let service = "chat.lurker.tests.feedrequests"
    /// Held for the whole test: a RoutedServer's deinit closes its listener.
    private var servers: [RoutedServer] = []

    override func setUp() {
        super.setUp()
        SessionStore(service: service).clear()
    }

    override func tearDown() {
        SessionStore(service: service).clear()
        super.tearDown()
    }

    private func signedIn(_ routes: [String: RoutedServer.Route]) async throws -> (ChatViewModel, RoutedServer) {
        let server = try await RoutedServer(routes: routes)
        servers.append(server)
        let sessions = SessionStore(service: service)
        sessions.save(PersistedSession(server: server.url, token: "tok"))
        let model = ChatViewModel(
            sessions: sessions,
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: service)!)
        )
        XCTAssertEqual(model.session, .loggedIn)
        return (model, server)
    }

    private func asked(_ server: RoutedServer, _ key: String) -> Int {
        server.requests.filter { $0.hasPrefix(key + "\n") }.count
    }

    // MARK: - 503 (lurker#1308)

    func testA503FromSearchCarriesTheServersReason() async throws {
        let (model, _) = try await signedIn([
            "GET /api/search": .init(status: 503, body: #"{"error":"search took too long"}"#)
        ])
        let answer = await model.searchMessages("needle")
        XCTAssertEqual(answer, .unavailable(reason: "search took too long"))
        XCTAssertEqual(model.session, .loggedIn, "a busy search is not a lost session")
    }

    func testA503FromHighlightsCarriesTheServersReason() async throws {
        let (model, _) = try await signedIn([
            "GET /api/highlights": .init(status: 503, body: #"{"error":"too many searches are waiting"}"#)
        ])
        let answer = await model.fetchHighlights()
        XCTAssertEqual(answer, .unavailable(reason: "too many searches are waiting"))
    }

    func testA503FromActivityCarriesTheServersReason() async throws {
        let (model, server) = try await signedIn([
            "GET /api/activity": .init(status: 503, body: #"{"error":"search superseded"}"#)
        ])
        let answer = await model.fetchActivity()
        XCTAssertEqual(answer, .unavailable(reason: "search superseded"))
        XCTAssertEqual(asked(server, "GET /api/highlights"), 0, "only a 404 falls back to the older feed")
    }

    func testA503FromTheOlderFeedBehindActivityIsCarriedToo() async throws {
        // A server without `/api/activity` answers 404 and the read falls back to highlights,
        // which can be the one that is busy.
        let (model, _) = try await signedIn([
            "GET /api/highlights": .init(status: 503, body: #"{"error":"search took too long"}"#)
        ])
        let answer = await model.fetchActivity()
        XCTAssertEqual(answer, .unavailable(reason: "search took too long"))
    }

    func testAnyOtherFailureIsPlainFailure() async throws {
        let (model, _) = try await signedIn([
            "GET /api/search": .init(status: 500, body: #"{"error":"boom"}"#)
        ])
        let answer = await model.searchMessages("needle")
        XCTAssertEqual(answer, .failed)
    }

    func testAPageStillReadsAsAPage() async throws {
        let (model, _) = try await signedIn([
            "GET /api/search": .init(status: 200, body: #"{"items":[],"nextBefore":null}"#)
        ])
        let answer = await model.searchMessages("needle")
        XCTAssertEqual(answer, .page(HighlightsPage(items: [], nextBefore: nil)))
    }

    // MARK: - Removing an upload (lurker#1295)

    func testForgettingAsksTheRecordRouteAndNeverTheDeleteRoute() async throws {
        let (model, server) = try await signedIn([
            "DELETE /api/uploads/7/record": .init(status: 200, body: #"{"ok":true}"#),
            "DELETE /api/uploads/7": .init(status: 200, body: #"{"ok":true}"#),
        ])
        let refusal = await model.forgetUpload(id: 7)
        XCTAssertNil(refusal)
        XCTAssertEqual(asked(server, "DELETE /api/uploads/7/record"), 1)
        XCTAssertEqual(asked(server, "DELETE /api/uploads/7"), 0, "that one destroys the file")
    }

    func testDeletingAsksTheDeleteRoute() async throws {
        let (model, server) = try await signedIn([
            "DELETE /api/uploads/7/record": .init(status: 200, body: #"{"ok":true}"#),
            "DELETE /api/uploads/7": .init(status: 200, body: #"{"ok":true}"#),
        ])
        let refusal = await model.deleteUpload(id: 7)
        XCTAssertNil(refusal)
        XCTAssertEqual(asked(server, "DELETE /api/uploads/7"), 1)
        XCTAssertEqual(asked(server, "DELETE /api/uploads/7/record"), 0)
    }

    func testARefusedRemovalComesBackInTheServersWords() async throws {
        let (model, _) = try await signedIn([
            "DELETE /api/uploads/7/record": .init(status: 503, body: #"{"error":"try again shortly"}"#)
        ])
        let refusal = await model.forgetUpload(id: 7)
        XCTAssertEqual(refusal, "try again shortly")
    }

    func testDeletingARowThatIsAlreadyGoneIsDone() async throws {
        // Removed on another device while this list was up.
        let (model, _) = try await signedIn([
            "DELETE /api/uploads/7": .init(status: 404, body: #"{"error":"not found"}"#)
        ])
        let refusal = await model.deleteUpload(id: 7)
        XCTAssertNil(refusal)
    }

    func testForgettingOnAServerWithoutTheRouteIsNotReadAsDone() async throws {
        // Before lurker 2.7.0 the route itself is a 404; the row is still there.
        let (model, _) = try await signedIn([:])
        let refusal = await model.forgetUpload(id: 7)
        XCTAssertNotNil(refusal)
    }
}

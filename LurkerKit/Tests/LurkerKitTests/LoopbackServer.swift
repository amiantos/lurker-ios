// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Network
import XCTest

// Test support shared by the suites that talk to a loopback server (PendingRevokeTests,
// SettingsWriteTests).

/// Poll `condition` for up to five seconds, failing the test if it never holds.
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    // Evaluated here: XCTAssert's autoclosure can't capture a non-escaping closure.
    let held = condition()
    XCTAssertTrue(held, "timed out")
}

/// A loopback HTTP server that answers every request with one status and records each request's
/// head. Just enough HTTP for URLSession.
final class OneStatusServer: @unchecked Sendable {
    private(set) var url = ""
    private let listener: NWListener
    private let lock = NSLock()
    private var heads: [String] = []

    var requests: [String] { lock.withLock { heads } }

    /// Released once by `open()` (or at init when not gated); each waiter passes it on.
    private let gate = DispatchSemaphore(value: 0)

    func open() { gate.signal() }

    /// With `gated`, each connection waits for `open()` before it's answered: the test decides how
    /// long a request is in flight, not the clock.
    init(status: Int, body: String = "", gated: Bool = false) async throws {
        if !gated { gate.signal() }
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { continuation.yield(port); continuation.finish() }
            }
        }
        let gate = self.gate
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data, let head = String(data: data, encoding: .utf8) {
                    self?.lock.withLock { self?.heads.append(head) }
                }
                let response = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(Data(body.utf8).count)\r\nConnection: close\r\n\r\n\(body)"
                gate.wait()
                gate.signal()
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for await p in ready { port = p }
        url = "http://127.0.0.1:\(port)"
    }

    deinit { listener.cancel() }
}

/// A loopback HTTP server that answers by method and path, and records each request whole —
/// head and body — for the suites that need more than one route (the push relay's view-model
/// tests). Anything unrouted gets a 404. Just enough HTTP for URLSession: one request per
/// connection, bodies by Content-Length.
final class RoutedServer: @unchecked Sendable {
    struct Route {
        let status: Int
        let body: String
        /// Hold the answer back this long, for a reply that lands after something else.
        var delay: TimeInterval = 0
    }

    private(set) var url = ""
    private let listener: NWListener
    private let lock = NSLock()
    private var recorded: [String] = []
    private var routes: [String: Route]

    /// Every request so far, each as "METHOD /path\n<body>".
    var requests: [String] { lock.withLock { recorded } }

    /// Change an answer mid-test (e.g. the admin turning the relay on).
    func route(_ key: String, _ route: Route) { lock.withLock { routes[key] = route } }

    /// `routes` keyed "METHOD /path" (no query string).
    init(routes: [String: Route]) async throws {
        self.routes = routes
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { continuation.yield(port); continuation.finish() }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.read(connection, Data())
        }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for await p in ready { port = p }
        url = "http://127.0.0.1:\(port)"
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            guard let split = text.range(of: "\r\n\r\n") else {
                if complete || error != nil { connection.cancel() } else { self.read(connection, buffer) }
                return
            }
            let head = String(text[..<split.lowerBound])
            let length = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = String(text[split.upperBound...])
            if body.utf8.count < length, !complete, error == nil {
                self.read(connection, buffer)
                return
            }
            let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = requestLine.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1].split(separator: "?")[0]) : ""
            let key = "\(method) \(path)"
            let route = self.lock.withLock { () -> Route? in
                self.recorded.append("\(key)\n\(body)")
                return self.routes[key]
            } ?? Route(status: 404, body: "")
            let response = "HTTP/1.1 \(route.status) X\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(Data(route.body.utf8).count)\r\nConnection: close\r\n\r\n\(route.body)"
            DispatchQueue.global().asyncAfter(deadline: .now() + route.delay) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    deinit { listener.cancel() }
}

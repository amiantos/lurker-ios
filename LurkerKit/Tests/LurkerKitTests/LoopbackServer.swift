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

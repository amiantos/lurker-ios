// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The order toasts take a surface in: one at a time, a burst from one source updating in place,
/// a notice first.
final class StatusToastQueueTests: XCTestCase {
    private func toast(_ nick: String, in target: String = "#a", kind: StatusNotification.Kind = .highlight) -> StatusToast {
        .notification(StatusNotification(
            kind: kind, key: BufferKey(networkId: 1, target: target), nick: nick, text: "hi",
            messageId: 1, date: Date()
        ))
    }

    func testOneAtATimeInArrivalOrder() {
        var queue = StatusToastQueue()
        let alice = toast("alice")
        XCTAssertEqual(queue.offer(alice), .queued)
        XCTAssertEqual(queue.offer(toast("bob")), .queued)
        let first = queue.presentNext()
        XCTAssertEqual(first?.toast, alice)
        // Someone waits behind it, so it holds for less.
        XCTAssertEqual(first?.hold, StatusToastQueue.holdBusy)
        XCTAssertNil(queue.presentNext(), "nothing new while one is showing")
        queue.endActive()
        let second = queue.presentNext()
        XCTAssertEqual(second?.hold, StatusToastQueue.hold)
    }

    func testTheSameSourceUpdatesInPlace() {
        var queue = StatusToastQueue()
        _ = queue.offer(toast("alice"))
        _ = queue.presentNext()
        // Same person, buffer and kind, whatever the case of the nick or target.
        let newer = toast("Alice", in: "#A")
        XCTAssertEqual(queue.offer(newer), .updatedActive)
        XCTAssertEqual(queue.active, newer)
        XCTAssertTrue(queue.waiting.isEmpty)

        _ = queue.offer(toast("bob"))
        let bobAgain = toast("bob")
        XCTAssertEqual(queue.offer(bobAgain), .updatedWaiting)
        XCTAssertEqual(queue.waiting, [bobAgain])
        // Another kind from the same person is its own toast.
        XCTAssertEqual(queue.offer(toast("bob", kind: .alwaysNotify)), .queued)
    }

    func testOnlyTheNewestFewWait() {
        var queue = StatusToastQueue()
        let toasts = ["a", "b", "c", "d", "e"].map { toast($0) }
        for t in toasts { _ = queue.offer(t) }
        XCTAssertEqual(queue.waiting, Array(toasts.suffix(3)))
    }

    func testANoticeGoesFirstAndTakesOverFromANotification() {
        var queue = StatusToastQueue()
        _ = queue.offer(toast("alice"))
        _ = queue.offer(toast("bob"))
        _ = queue.presentNext()
        XCTAssertEqual(queue.offer(.notice("Not connected")), .preemptedActive)
        XCTAssertNil(queue.active)
        XCTAssertEqual(queue.presentNext()?.toast, .notice("Not connected"))
        // A notice showing isn't pushed aside by the next one; it waits at the front.
        XCTAssertEqual(queue.offer(.notice("Other")), .queued)
        XCTAssertEqual(queue.waiting.first, .notice("Other"))
    }

    func testRequeueAndDrop() {
        var queue = StatusToastQueue()
        let alice = toast("alice"), bob = toast("bob")
        _ = queue.offer(alice)
        _ = queue.offer(bob)
        _ = queue.presentNext()
        queue.requeueActive()
        XCTAssertNil(queue.active)
        XCTAssertEqual(queue.waiting, [alice, bob])
        queue.dropWaiting()
        XCTAssertNil(queue.presentNext())
    }
}

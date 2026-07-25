// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The outgoing half of `+typing`: which signals our own draft emits, and when.
///
/// Three deadlines interact here (refresh, idle, and end), which is exactly the kind of logic
/// that's miserable to check by watching a phone and trivial to check at an exact instant. The
/// clock is a parameter, so every case below is a fixed sequence with no waiting.
final class OutgoingTypingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    // MARK: - Starting and throttling

    func testFirstKeystrokeAnnouncesActive() {
        var typing = OutgoingTyping()
        XCTAssertEqual(typing.draftChanged(to: "hello", at: t0), .active)
    }

    /// A tag per character would be a flood. Within the refresh window we stay quiet.
    func testKeystrokesWithinTheRefreshWindowStayQuiet() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "h", at: t0)
        XCTAssertNil(typing.draftChanged(to: "he", at: t0.addingTimeInterval(0.1)))
        XCTAssertNil(typing.draftChanged(to: "hel", at: t0.addingTimeInterval(2.9)))
    }

    func testActiveIsReassertedOnceTheRefreshWindowElapses() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "h", at: t0)
        XCTAssertEqual(typing.draftChanged(to: "hello", at: t0.addingTimeInterval(3.1)), .active)
    }

    // MARK: - Pausing

    func testIdleDowngradesToPaused() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        XCTAssertEqual(typing.idled(draft: "hello", at: t0.addingTimeInterval(3)), .paused)
    }

    func testIdlingTwiceOnlyPausesOnce() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        _ = typing.idled(draft: "hello", at: t0.addingTimeInterval(3))
        XCTAssertNil(typing.idled(draft: "hello", at: t0.addingTimeInterval(6)))
    }

    /// The field can be emptied by something that isn't a keystroke. Announcing `paused` for a
    /// draft that no longer exists would park a ghost on the peer for the full 30s lease.
    func testIdleWithAnEmptiedDraftSaysNothing() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        XCTAssertNil(typing.idled(draft: "", at: t0.addingTimeInterval(3)))
    }

    func testTypingAgainAfterPausedGoesBackToActive() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        _ = typing.idled(draft: "hello", at: t0.addingTimeInterval(3))
        // A state change re-asserts immediately — it doesn't wait out the refresh window.
        XCTAssertEqual(typing.draftChanged(to: "hello!", at: t0.addingTimeInterval(3.5)), .active)
    }

    // MARK: - Stopping

    func testEmptyingTheDraftSaysDone() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        XCTAssertEqual(typing.draftChanged(to: "", at: t0.addingTimeInterval(1)), .done)
    }

    func testWhitespaceOnlyDraftCountsAsEmpty() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        XCTAssertEqual(typing.draftChanged(to: "   \n ", at: t0.addingTimeInterval(1)), .done)
    }

    /// A command isn't a message to the channel. Announcing composing for `/whois` leaks that
    /// you're doing something and then never delivers a line to justify it.
    func testCommandDraftNeverAnnouncesTyping() {
        var typing = OutgoingTyping()
        XCTAssertNil(typing.draftChanged(to: "/whois al", at: t0))
        XCTAssertFalse(typing.isSignalling)
    }

    func testTurningAMessageIntoACommandSaysDone() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        XCTAssertEqual(typing.draftChanged(to: "/me waves", at: t0.addingTimeInterval(1)), .done)
    }

    func testEndedSaysDoneWhenWeWereTyping() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        XCTAssertEqual(typing.ended(), .done)
        XCTAssertFalse(typing.isSignalling)
    }

    /// Otherwise switching buffers with an untouched composer would spray `done` at every
    /// channel you pass through.
    func testEndedSaysNothingWhenWeWereNotTyping() {
        var typing = OutgoingTyping()
        XCTAssertNil(typing.ended())
    }

    func testEndedIsIdempotent() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        _ = typing.ended()
        XCTAssertNil(typing.ended())
    }

    /// Emptying the field already said `done`, so the send that follows must not say it twice.
    func testClearingThenEndingDoesNotDoubleSend() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        XCTAssertEqual(typing.draftChanged(to: "", at: t0.addingTimeInterval(1)), .done)
        XCTAssertNil(typing.ended())
    }

    /// After stopping, the next keystroke is a fresh start rather than being throttled against
    /// the previous run's timestamp.
    func testResumingAfterDoneAnnouncesImmediately() {
        var typing = OutgoingTyping()
        _ = typing.draftChanged(to: "hello", at: t0)
        _ = typing.ended()
        XCTAssertEqual(typing.draftChanged(to: "h", at: t0.addingTimeInterval(0.5)), .active)
    }

    // MARK: - A whole draft, start to finish

    func testATypicalDraftEmitsActivePausedActiveDone() {
        var typing = OutgoingTyping()
        var signals: [TypingSignal] = []
        func note(_ signal: TypingSignal?) { if let signal { signals.append(signal) } }

        note(typing.draftChanged(to: "h", at: t0))
        note(typing.draftChanged(to: "he", at: t0.addingTimeInterval(0.2)))
        note(typing.draftChanged(to: "hey", at: t0.addingTimeInterval(0.4)))
        note(typing.idled(draft: "hey", at: t0.addingTimeInterval(3.4)))
        note(typing.draftChanged(to: "hey there", at: t0.addingTimeInterval(9)))
        note(typing.ended())

        XCTAssertEqual(signals, [.active, .paused, .active, .done])
    }
}

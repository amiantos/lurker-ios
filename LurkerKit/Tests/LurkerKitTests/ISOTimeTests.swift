// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The wire's timestamp shapes. There are three, and which one a field arrives in is a
/// property of the **column it came from**, not of the wire — so a reader that handles only
/// the common one fails silently on whole features rather than loudly anywhere.
final class ISOTimeTests: XCTestCase {

    /// 2026-08-29T12:00:00Z, the instant all three spellings below denote.
    private let instant = Date(timeIntervalSince1970: 1_788_004_800)

    func testParsesTheEventTimeShapeWithFractionalSeconds() {
        // What almost every timestamp on the wire looks like: an event `time`.
        XCTAssertEqual(ISOTime.parse("2026-08-29T12:00:00.000Z"), instant)
    }

    func testParsesIsoWithoutFractionalSeconds() {
        XCTAssertEqual(ISOTime.parse("2026-08-29T12:00:00Z"), instant)
    }

    func testParsesSqliteDatetimeNow() {
        // ⚠⚠ A space instead of the `T`, and no zone at all. This is what a column declared
        // `DEFAULT (datetime('now'))` holds, and the server echoes such columns verbatim —
        // `user_nick_notes.updated_at` is one (#12). `ISO8601DateFormatter` refuses it under
        // every option combination, so before this shape was handled the value silently
        // became nil and the row it fed simply never drew.
        XCTAssertEqual(ISOTime.parse("2026-08-29 12:00:00"), instant)
    }

    func testSqliteDatetimeIsReadAsUtcNotAsDeviceLocalTime() {
        // `datetime('now')` is always UTC despite carrying no zone. Reading it as local time
        // is the JS-side bug the web works around in `parseServerTimestamp`, and it would put
        // a note's "Updated…" row hours out for most of the world.
        //
        // Asserted against the ISO spelling of the same instant rather than a fixed offset, so
        // this test says the same thing in every timezone it runs in.
        XCTAssertEqual(ISOTime.parse("2026-08-29 12:00:00"), ISOTime.parse("2026-08-29T12:00:00Z"))
    }

    func testAnUnreadableTimestampIsNilRatherThanAThrowOrTheEpoch() {
        for bad in ["", "not a date", "2026-08-29", "29/08/2026 12:00:00"] {
            XCTAssertNil(ISOTime.parse(bad), bad)
        }
        XCTAssertNil(ISOTime.parse(nil))
    }

    func testRoundTripsTheOneShapeThisClientSends() {
        // An ignore rule's `expiresAt` (#86) is the only timestamp iOS writes.
        XCTAssertEqual(ISOTime.parse(ISOTime.string(from: instant)), instant)
    }
}
